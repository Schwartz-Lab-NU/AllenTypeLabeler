function app = AllenTypeLabeler(rootDir)
% AllenTypeLabeler  Browse Allen Cell Types long-square recordings, assign labels.
%
%   AllenTypeLabeler                  uses ~/WASSUP_allen
%   app = AllenTypeLabeler(rootDir)   custom data root
%
% Data (from dandi_wassup/scripts/fetch_allen_celltypes.py):
%   <root>/metadata.csv, <root>/cells/<specimen_id>.h5
% Output:
%   <root>/labels.csv          specimen_id,label,notes,timestamp (rewritten on
%                              every change — merge into WASSUP as cell_type)
%   <root>/label_presets.txt   one label per line; first 9 get hotkeys 1-9
%
% Keys:  right/left  next/prev cell        1-9  assign preset label
%        0           clear label           (Next unlabeled: toolbar button)
% Cells still downloading show as "..." and display a placeholder; press
% Rescan to pick up newly finished files without restarting.

arguments
    rootDir (1,1) string = fullfile(string(getenv("HOME")), "WASSUP_allen")
end

cellsDir    = fullfile(rootDir, "cells");
labelsFile  = fullfile(rootDir, "labels.csv");
presetsFile = fullfile(rootDir, "label_presets.txt");

% ---------------- state ----------------
meta    = loadMetadata();
nCells  = height(meta);
labels  = loadLabels();      % dictionary: id string -> struct(label,notes,timestamp)
presets = loadPresets();     % string column vector
allenT  = loadAllenTypes();  % dictionary: id string -> struct(e,m,me) [Gouwens 2019]
hasFile = scanCells();       % logical (nCells,1)
filtRows = (1:nCells)';      % meta rows passing filters, list order
curPos   = 1;                % position within filtRows
rowOfId  = dictionary(string(meta.("specimen__id")), (1:nCells)');
examplesOn = false;          % right-hand type-examples panel expanded?
exState  = struct('name',{},'idx',{},'ax',{},'head',{},'pos',{});
exCache  = dictionary(string.empty, cell.empty);  % id -> decimated example traces
exWidth  = 340;              % examples column width (px), user-resizable
exDragging = false;          % splitter drag in progress
gripHover  = false;

% ---------------- UI ----------------
fig = uifigure("Name", "Allen Cell Types Labeler — WASSUP", ...
    "Position", [60 60 1400 850]);
root = uigridlayout(fig, [2 4]);
root.RowHeight     = {38, '1x'};
root.ColumnWidth   = {300, '1x', 0, 0};   % col 3 = splitter grip, col 4 = examples
root.Padding       = [0 0 0 0];
root.RowSpacing    = 0;
root.ColumnSpacing = 0;

% --- toolbar (spans all columns) ---
tbPanel = uipanel(root);
tbPanel.Layout.Row = 1; tbPanel.Layout.Column = [1 4];
tb = uigridlayout(tbPanel, [1 12]);
tb.ColumnWidth = {60, 60, 130, '1x', 110, 110, 140, 120, 130, 90, 85, 70};
tb.Padding = [8 4 8 4]; tb.ColumnSpacing = 8;

prevBtn = uibutton(tb, "Text", "◀ Prev", "ButtonPushedFcn", @(~,~) step(-1));
nextBtn = uibutton(tb, "Text", "Next ▶", "ButtonPushedFcn", @(~,~) step(+1)); %#ok<NASGU>
nextUnBtn = uibutton(tb, "Text", "Next unlabeled", ...
    "ButtonPushedFcn", @(~,~) gotoNextUnlabeled()); %#ok<NASGU>
progLbl = uilabel(tb, "Text", "", "HorizontalAlignment", "center");
speciesSW = uiswitch(tb, "slider", "Items", ["Mouse", "Human"], ...
    "Value", "Mouse", "ValueChangedFcn", @(~,~) applyFilters(false));
statusDD = uidropdown(tb, "Items", ["All cells", "Unlabeled", "Labeled"], ...
    "ValueChangedFcn", @(~,~) applyFilters(true));
typeDD = uidropdown(tb, "Items", "All my types", ...
    "ValueChangedFcn", @(~,~) applyFilters(true));
autoAdvCB = uicheckbox(tb, "Text", "Auto-advance", "Value", true);
allenCB = uicheckbox(tb, "Text", "Show Allen types", "Value", false, ...
    "ValueChangedFcn", @(~,~) refreshCurrent());
layerCB = uicheckbox(tb, "Text", "Show layer", "Value", false, ...
    "ValueChangedFcn", @(~,~) onLayerToggle());
exBtn = uibutton(tb, "state", "Text", "Examples", "Value", false, ...
    "ValueChangedFcn", @(s,~) toggleExamples(s.Value)); %#ok<NASGU>
uibutton(tb, "Text", "Rescan", "ButtonPushedFcn", @(~,~) rescan());

% --- sidebar ---
sidePanel = uipanel(root);
sidePanel.Layout.Row = 2; sidePanel.Layout.Column = 1;
side = uigridlayout(sidePanel, [2 1]);
side.RowHeight = {'1x', 'fit'};
side.Padding = [8 8 8 8]; side.RowSpacing = 8;

cellList = uilistbox(side, "Items", "", ...
    "ValueChangedFcn", @(s,~) onListSelect(s));
cellList.FontName = "Menlo";

metaLbl = uilabel(side, "Text", "", "WordWrap", "on", ...
    "VerticalAlignment", "top", "FontName", "Menlo", "FontSize", 12);

% --- main column: axes + label panel ---
main = uigridlayout(root, [3 1]);
main.Layout.Row = 2; main.Layout.Column = 2;
main.RowHeight = {'1x', 150, 'fit'};
main.Padding = [8 8 8 8]; main.RowSpacing = 6;

axV = uiaxes(main);
axV.XLabel.String = "Time (s)"; axV.YLabel.String = "V_m (mV)";
axV.Title.Interpreter = "none";
axFI = uiaxes(main);
axFI.XLabel.String = "Current (pA)"; axFI.YLabel.String = "Spikes";

lblPanel = uipanel(main, "Title", "Label");
lp = uigridlayout(lblPanel, [2 7]);
lp.ColumnWidth = {60, 220, 240, 55, '1x', 70, 200};
lp.RowHeight = {'fit', 'fit'};
lp.Padding = [8 6 8 6]; lp.RowSpacing = 4;

% type entry is a TRUE edit field (reliably captures keystrokes) plus a
% separate NON-editable dropdown for picking existing types — the editable
% combobox leaked unconsumed keys to the figure while typing
uilabel(lp, "Text", "Type:", "HorizontalAlignment", "right");
labelEF = uieditfield(lp, "text", ...
    "ValueChangedFcn", @(s,~) commitTyped(strtrim(string(s.Value))), ...
    "ValueChangingFcn", @(~,evt) onTypeTyping(strtrim(string(evt.Value))));
labelDD = uidropdown(lp, "Items", {''}, ...
    "ValueChangedFcn", @(s,~) onPresetPick(s));
uilabel(lp, "Text", "Notes:", "HorizontalAlignment", "right");
notesEF = uieditfield(lp, "text", "ValueChangedFcn", @(s,~) commitNotes(string(s.Value)));
clearBtn = uibutton(lp, "Text", "Clear (0)", "ButtonPushedFcn", @(~,~) commitLabel("")); %#ok<NASGU>
hotkeyLbl = uilabel(lp, "Text", "", "WordWrap", "on", "FontSize", 11);
hotkeyLbl.Layout.Row = [1 2]; hotkeyLbl.Layout.Column = 7;
savedLbl = uilabel(lp, "Text", "labels.csv: " + string(nnz_labels()) + " cells", ...
    "FontSize", 11, "FontColor", [.4 .4 .4]);
savedLbl.Layout.Row = 2; savedLbl.Layout.Column = [1 6];

% KeyPressFcn (not WindowKeyPressFcn): fires only when the figure itself has
% keyboard focus, so hotkeys stay dead while typing in the Type/Notes boxes.
% --- collapsible type-examples panel (right column) + drag splitter ---
grip = uipanel(root, "Visible", "off", "BorderType", "none", ...
    "BackgroundColor", [0.5 0.5 0.5]);
grip.Layout.Row = 2; grip.Layout.Column = 3;
exPanel = uipanel(root, "Title", "Type examples", "Visible", "off");
exPanel.Layout.Row = 2; exPanel.Layout.Column = 4;
exGrid = uigridlayout(exPanel, [1 1]);
exGrid.Scrollable = "on";
exGrid.ColumnWidth = {'1x'};
exGrid.Padding = [4 4 4 4]; exGrid.RowSpacing = 6;

fig.KeyPressFcn = @(~,evt) onKey(evt);
fig.WindowButtonDownFcn   = @(~,~) onMouseDown();
fig.WindowButtonMotionFcn = @(~,~) onMouseMove();
fig.WindowButtonUpFcn     = @(~,~) exDragEnd();

refreshLabelControls();
refreshTypeFilter();
applyFilters(false);
% start at the first unlabeled downloaded cell
p = find(arrayfun(@(r) hasFile(r) && getLabel(r) == "", filtRows), 1);
if isempty(p), p = 1; end
selectByPos(p);

app.fig = fig;

% =====================================================================
%                              data layer
% =====================================================================
    function T = loadMetadata()
        f = fullfile(rootDir, "metadata.csv");
        if ~isfile(f)
            error("AllenTypeLabeler:noMetadata", ...
                "%s not found — run fetch_allen_celltypes.py first.", f);
        end
        opts = detectImportOptions(f, "VariableNamingRule", "preserve", ...
            "TextType", "string");
        txtCols = ["donor__species","structure__acronym","structure__layer", ...
            "structure_parent__acronym","line_name","tag__dendrite_type", ...
            "tag__apical","specimen__name","cell_reporter_status", ...
            "donor__sex","donor__age","donor__disease_state"];
        opts = setvartype(opts, intersect(txtCols, opts.VariableNames), "string");
        T = readtable(f, opts);
        [~, iu] = unique(T.("specimen__id"), "stable");
        T = T(iu, :);
        % deliberately NOT sorted by layer: layer-adjacent grouping in the
        % list would leak layer identity even when the layer text is hidden
        T = sortrows(T, ["donor__species","structure_parent__acronym", ...
            "specimen__id"]);
    end

    function d = loadLabels()
        d = dictionary(string.empty, cell.empty);
        if ~isfile(labelsFile), return; end
        L = readtable(labelsFile, "TextType", "string");
        for i = 1:height(L)
            d(string(L.specimen_id(i))) = {struct( ...
                "label", stringOrEmpty(L.label(i)), ...
                "notes", stringOrEmpty(L.notes(i)), ...
                "timestamp", stringOrEmpty(L.timestamp(i)))};
        end
    end

    function s = stringOrEmpty(v)
        if isnumeric(v) && all(isnan(v)), s = ""; return; end
        s = string(v);
        if ismissing(s) || s == "NaN", s = ""; end
    end

    function saveLabels()
        ids = labels.keys;
        n = numel(ids);
        specimen_id = zeros(n,1); label = strings(n,1);
        notes = strings(n,1); timestamp = strings(n,1);
        allen_e_type = strings(n,1); allen_m_type = strings(n,1);
        allen_me_type = strings(n,1);
        for i = 1:n
            e = labels{ids(i)};
            specimen_id(i) = double(str2double(ids(i)));
            label(i) = e.label; notes(i) = e.notes; timestamp(i) = e.timestamp;
            if allenT.isKey(ids(i))
                a = allenT{ids(i)};
                allen_e_type(i) = a.e; allen_m_type(i) = a.m;
                allen_me_type(i) = a.me;
            end
        end
        T = sortrows(table(specimen_id, label, notes, ...
            allen_e_type, allen_m_type, allen_me_type, timestamp), "specimen_id");
        tmp = labelsFile + ".tmp";
        writetable(T, tmp, "FileType", "text");
        movefile(tmp, labelsFile, "f");
        savedLbl.Text = "labels.csv: " + string(nnz_labels()) + " cells";
    end

    function n = nnz_labels()
        n = 0;
        ids = labels.keys;
        for i = 1:numel(ids)
            if labels{ids(i)}.label ~= "", n = n + 1; end
        end
    end

    function d = loadAllenTypes()
        d = dictionary(string.empty, cell.empty);
        f = fullfile(rootDir, "allen_cluster_labels.csv");
        if ~isfile(f), return; end
        A = readtable(f, "TextType", "string");
        for i = 1:height(A)
            d(string(A.specimen_id(i))) = {struct( ...
                "e",  stringOrEmpty(A.allen_e_type(i)), ...
                "m",  stringOrEmpty(A.allen_m_type(i)), ...
                "me", stringOrEmpty(A.allen_me_type(i)))};
        end
    end

    function s = allenTypeStr(row)
        k = string(meta.("specimen__id")(row));
        if ~allenT.isKey(k)
            s = "not in Gouwens 2019";
            return
        end
        a = allenT{k};
        v = [a.e, a.m, a.me];
        v(v == "") = "—";
        s = sprintf("e %s · m %s · me %s", v(1), v(2), v(3));
    end

    function p = loadPresets()
        if ~isfile(presetsFile)
            writelines("", presetsFile);
        end
        p = readlines(presetsFile);
        p = strtrim(p); p = p(p ~= ""); p = unique(p, "stable");
    end

    function savePresets()
        writelines(presets, presetsFile);
    end

    function h = scanCells()
        d = dir(fullfile(cellsDir, "*.h5"));
        onDisk = string(erase({d.name}, ".h5"));
        h = ismember(string(meta.("specimen__id")), onDisk);
    end

    function s = getLabel(row)
        k = string(meta.("specimen__id")(row));
        if labels.isKey(k), s = labels{k}.label; else, s = ""; end
    end

    function s = getNotes(row)
        k = string(meta.("specimen__id")(row));
        if labels.isKey(k), s = labels{k}.notes; else, s = ""; end
    end

% =====================================================================
%                       filtering / list / navigation
% =====================================================================
    function applyFilters(keepCell)
        prevRow = 0;
        if keepCell && ~isempty(filtRows), prevRow = filtRows(curPos); end
        st = statusDD.Value; ty = string(typeDD.Value);
        if speciesSW.Value == "Mouse", spName = "Mus musculus"; else, spName = "Homo Sapiens"; end
        keep = meta.("donor__species") == spName;
        if st ~= "All cells" || ty ~= "All my types"
            lab = arrayfun(@getLabel, (1:nCells)');
            if st == "Unlabeled", keep = keep & lab == ""; end
            if st == "Labeled",   keep = keep & lab ~= ""; end
            if ty ~= "All my types", keep = keep & lab == ty; end
        end
        filtRows = find(keep);
        if isempty(filtRows)
            cellList.Items = "  (no cells match filter)"; cellList.ItemsData = [];
            updateProgress(); return
        end
        rebuildListItems();
        p = find(filtRows == prevRow, 1);
        if isempty(p), p = min(max(curPos, 1), numel(filtRows)); end
        selectByPos(p);
    end

    function s = listItemStr(row)
        lab = getLabel(row);
        if ~hasFile(row),   mark = "…";
        elseif lab ~= "",   mark = "✓";
        else,               mark = " ";
        end
        s = sprintf("%s %s  %s", mark, ...
            string(meta.("specimen__id")(row)), cellTag(row));
        if lab ~= "", s = s + "  → " + lab; end
    end

    function rebuildListItems()
        items = arrayfun(@listItemStr, filtRows);
        cellList.Items = items;
        cellList.ItemsData = 1:numel(filtRows);
    end

    function refreshListItem(pos)
        items = cellList.Items;
        items{pos} = char(listItemStr(filtRows(pos)));
        cellList.Items = items;
    end

    function tag = cellTag(row)
        % structure acronym (+ layer). Mouse acronyms embed the layer
        % ("VISpm2/3", "VISpl6b"), so blinding strips trailing digits too.
        reg = fmtField(meta.("structure__acronym")(row));
        if layerCB.Value
            tag = reg;
            lay = meta.("structure__layer")(row);
            if ~ismissing(lay) && lay ~= "", tag = tag + " L" + lay; end
        else
            tag = regexprep(reg, "\d.*$", "");
        end
    end

    function onLayerToggle()
        rebuildListItems();
        selectByPos(curPos);
    end

    function onListSelect(src)
        if isempty(src.ItemsData), return; end
        selectByPos(src.Value);
        try, focus(fig); catch, end %#ok<TRYNC>
    end

    function step(d)
        if isempty(filtRows), return; end
        selectByPos(min(max(curPos + d, 1), numel(filtRows)));
    end

    function gotoNextUnlabeled()
        if isempty(filtRows), return; end
        order = [curPos+1:numel(filtRows), 1:curPos];
        p = order(find(arrayfun(@(q) hasFile(filtRows(q)) && ...
            getLabel(filtRows(q)) == "", order), 1));
        if ~isempty(p), selectByPos(p); end
    end

    function rescan()
        hasFile = scanCells();
        rebuildListItems();
        updateProgress();
        selectByPos(curPos);
    end

% =====================================================================
%                           cell display
% =====================================================================
    function selectByPos(p)
        if isempty(filtRows), return; end
        curPos = min(max(p, 1), numel(filtRows));
        p = curPos;
        cellList.Value = p;
        scroll(cellList, p);
        row = filtRows(p);
        showMetadata(row);
        setLabelControls(getLabel(row));
        notesEF.Value = char(getNotes(row));
        plotCell(row);
        updateProgress();
        try, focus(fig); catch, end % re-arm hotkeys after any navigation %#ok<TRYNC>
    end

    function updateProgress()
        nDown = nnz(hasFile);
        progLbl.Text = sprintf("cell %d/%d shown · %d/%d downloaded · %d labeled", ...
            curPos, numel(filtRows), nDown, nCells, nnz_labels());
    end

    function refreshCurrent()
        selectByPos(curPos);
    end

    function showMetadata(row)
        g = @(col) fmtField(meta.(col)(row));
        e = @(col) fmtNum(meta.(col)(row));
        if layerCB.Value
            depthStr = e("csl__normalized_depth");   % normalized cortical depth
        else
            depthStr = "(hidden)";                   % depth would leak the layer
        end
        txt = sprintf([ ...
            '%s\n%s · %s\nline: %s\ndendrite: %s (%s)\nreporter: %s\n', ...
            '─────────────────\n', ...
            'Vrest  %s mV      Ri  %s MΩ\ntau    %s ms      rheo  %s pA\n', ...
            'f-I slope  %s     adapt  %s\nup/down    %s     rate  %s Hz\n', ...
            'cort. depth  %s (norm)'], ...
            g("specimen__name"), g("donor__species"), cellTag(row), ...
            g("line_name"), g("tag__dendrite_type"), ...
            g("tag__apical"), g("cell_reporter_status"), ...
            e("ef__vrest"), e("ef__ri"), e("ef__tau"), ...
            e("ef__threshold_i_long_square"), e("ef__f_i_curve_slope"), ...
            e("ef__adaptation"), e("ef__upstroke_downstroke_ratio_long_square"), ...
            e("ef__avg_firing_rate"), depthStr);
        txt = string(txt) + newline + "─────────────────" + newline;
        if allenCB.Value
            txt = txt + "Allen: " + allenTypeStr(row);
        else
            txt = txt + "Allen types hidden";
        end
        metaLbl.Text = txt;
    end

    function s = fmtField(v)
        s = string(v);
        if ismissing(s) || s == "", s = "—"; end
    end


    function s = fmtNum(v)
        if ismissing(v) || ~isfinite(v), s = "—"; else, s = string(sprintf("%.3g", v)); end
    end

    function plotCell(row)
        id = meta.("specimen__id")(row);
        ttl = strtrim(sprintf("%d — %s %s  %s", id, ...
            fmtField(meta.("donor__species")(row)), cellTag(row), ...
            fmtField(meta.("line_name")(row))));
        if ~hasFile(row)
            cla(axV); cla(axFI);
            text(axV, 0.5, 0.5, "not downloaded yet — press Rescan later", ...
                "Units", "normalized", "HorizontalAlignment", "center");
            axV.Title.String = ttl;
            return
        end
        f = fullfile(cellsDir, id + ".h5");
        resp = h5read(f, "/response");            % h5 (T,n) -> MATLAB (n,T)
        if size(resp,1) < size(resp,2), resp = resp'; end % ensure (T,n)
        cur = h5read(f, "/current_pa");
        ss  = h5read(f, "/stim_start_s");
        se  = h5read(f, "/stim_end_s");
        fs  = h5readatt(f, "/", "fs_hz");
        [~, order] = sort(cur);
        resp = resp(:, order); cur = cur(order); ss = ss(order); se = se(order);
        t = (0:size(resp,1)-1)' / fs;

        cla(axV);
        cmap = turbo(max(numel(cur), 2));
        set(axV, "ColorOrder", cmap, "NextPlot", "replacechildren");
        plot(axV, t, resp, "LineWidth", 0.5);
        xline(axV, median(ss, "omitnan"), ":", "Color", [.5 .5 .5]);
        xline(axV, median(se, "omitnan"), ":", "Color", [.5 .5 .5]);
        axV.XLim = [t(1) t(end)];
        axV.Title.String = sprintf("%s   (%d sweeps, %g to %g pA)", ...
            ttl, numel(cur), round(min(cur)), round(max(cur)));
        axV.XLabel.String = "Time (s)"; axV.YLabel.String = "V_m (mV)";

        % f-I: upward 0 mV crossings inside the stim window
        nSpk = zeros(numel(cur), 1);
        for j = 1:numel(cur)
            i0 = max(1, round(ss(j)*fs)); i1 = min(size(resp,1), round(se(j)*fs));
            v = resp(i0:i1, j); v = v(~isnan(v));
            nSpk(j) = nnz(v(1:end-1) < 0 & v(2:end) >= 0);
        end
        cla(axFI);
        % no hardcoded color: default colororder stays visible in both themes
        hFI = plot(axFI, cur, nSpk, "o-", "MarkerSize", 4, "LineWidth", 1);
        hFI.MarkerFaceColor = hFI.Color;
        rheo = meta.("ef__threshold_i_long_square")(row);
        if isfinite(rheo), xline(axFI, rheo, "--", "Color", [.85 .3 .1]); end
        axFI.XLabel.String = "Current (pA)"; axFI.YLabel.String = "Spikes";
        grid(axFI, "on");
    end

% =====================================================================
%                            labeling
% =====================================================================
    function commitLabel(lbl)
        if isempty(filtRows), return; end
        row = filtRows(curPos);
        prev = getLabel(row);
        k = string(meta.("specimen__id")(row));
        e = struct("label", lbl, "notes", string(notesEF.Value), ...
            "timestamp", string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")));
        labels(k) = {e};
        if lbl ~= "" && ~any(presets == lbl)
            presets(end+1, 1) = lbl;
            savePresets();
        end
        saveLabels();
        refreshLabelControls();   % active set may have changed either way
        refreshTypeFilter();
        syncExamplePanel(prev, lbl);
        if statusDD.Value ~= "All cells" || string(typeDD.Value) ~= "All my types"
            applyFilters(true);   % membership in the filtered list may have changed
        else
            refreshListItem(curPos);
            setLabelControls(lbl);
        end
        updateProgress();
        try, focus(fig); catch, end %#ok<TRYNC>
        if autoAdvCB.Value && lbl ~= ""
            gotoNextUnlabeled();
        end
    end

    function u = labelsInUse()
        % unique labels currently assigned to >=1 cell
        u = strings(0, 1);
        ids = labels.keys;
        for i = 1:numel(ids)
            L = labels{ids(i)}.label;
            if L ~= "", u(end+1, 1) = L; end %#ok<AGROW>
        end
        u = unique(u, "stable");
    end

    function p = activePresets()
        % presets restricted to labels in use (presets file only remembers
        % hotkey order; a typo drops out once its last cell is relabeled)
        p = presets(ismember(presets, labelsInUse()));
    end

    function refreshTypeFilter()
        items = ["All my types"; sort(labelsInUse())];
        prev = string(typeDD.Value);
        typeDD.Items = items;
        if any(items == prev), typeDD.Value = prev;
        else, typeDD.Value = "All my types";
        end
    end

    function commitNotes(txt)
        if isempty(filtRows), return; end
        row = filtRows(curPos);
        k = string(meta.("specimen__id")(row));
        if labels.isKey(k), e = labels{k}; else
            e = struct("label", "", "notes", "", "timestamp", "");
        end
        e.notes = txt;
        e.timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
        labels(k) = {e};
        saveLabels();
        try, focus(fig); catch, end %#ok<TRYNC>
    end

    function onPresetPick(src)
        v = strtrim(string(src.Value));
        if v ~= "", commitLabel(v); end
    end

    function m = matchPreset(txt)
        % established type the text resolves to: exact (case-insensitive),
        % else unique prefix, else unique substring; "" when none/ambiguous
        m = "";
        if txt == "", return; end
        ap = activePresets();
        ex = ap(strcmpi(ap, txt));
        if ~isempty(ex), m = ex(1); return; end
        hit = ap(startsWith(ap, txt, "IgnoreCase", true));
        if isempty(hit)
            hit = ap(contains(ap, txt, "IgnoreCase", true));
        end
        if numel(hit) == 1, m = hit(1); end
    end

    function onTypeTyping(txt)
        % live feedback while typing: dropdown shows what Enter will commit
        m = matchPreset(txt);
        if m ~= "", labelDD.Value = char(m); else, labelDD.Value = ''; end
    end

    function commitTyped(txt)
        m = matchPreset(txt);
        if m ~= "", txt = m; end   % complete to the established type
        commitLabel(txt);
    end

    function setLabelControls(lbl)
        labelEF.Value = char(lbl);
        if any(string(labelDD.Items) == lbl)
            labelDD.Value = char(lbl);
        else
            labelDD.Value = '';
        end
    end

    function refreshLabelControls()
        ap = activePresets();
        labelDD.Items = cellstr(["" ; ap]);
        nHot = min(9, numel(ap));
        if nHot == 0
            hotkeyLbl.Text = "Type a label + Enter to create it; it gains the next hotkey (1-9).";
        else
            parts = arrayfun(@(i) sprintf("%d: %s", i, ap(i)), (1:nHot)');
            hotkeyLbl.Text = strjoin(parts, "   ");
        end
    end

% =====================================================================
%                       type-examples panel
% =====================================================================
    function toggleExamples(on)
        examplesOn = on;
        if on
            root.ColumnWidth{3} = 6;
            root.ColumnWidth{4} = exWidth;
            grip.Visible = "on";
            exPanel.Visible = "on";
            rebuildExamplePanel();
        else
            root.ColumnWidth{3} = 0;
            root.ColumnWidth{4} = 0;
            grip.Visible = "off";
            exPanel.Visible = "off";
        end
    end

    function tf = overGrip()
        cp = fig.CurrentPoint;
        gripLeft = fig.Position(3) - exWidth - 6;
        tf = examplesOn && cp(1) >= gripLeft - 3 && cp(1) <= gripLeft + 9 ...
            && cp(2) <= fig.Position(4) - 38;
    end

    function onMouseDown()
        if isequal(fig.CurrentObject, grip) || overGrip()
            exDragging = true;
        end
    end

    function onMouseMove()
        if exDragging
            w = fig.Position(3) - fig.CurrentPoint(1) - 3;
            exWidth = max(220, min(w, fig.Position(3) - 720));
            root.ColumnWidth{4} = exWidth;
        else
            hov = overGrip();
            if hov ~= gripHover
                gripHover = hov;
                if hov, fig.Pointer = "left"; else, fig.Pointer = "arrow"; end
            end
        end
    end

    function exDragEnd()
        exDragging = false;
    end

    function ids = typeExampleIds(name)
        % labeled cells of this type with data on disk, newest label first
        ids = strings(0, 1); ts = strings(0, 1);
        ks = labels.keys;
        for i = 1:numel(ks)
            e = labels{ks(i)};
            if e.label == name && rowOfId.isKey(ks(i)) && hasFile(rowOfId(ks(i)))
                ids(end+1, 1) = ks(i); ts(end+1, 1) = e.timestamp; %#ok<AGROW>
            end
        end
        [~, o] = sort(ts, "descend");
        ids = ids(o);
    end

    function rebuildExamplePanel()
        if ~examplesOn, return; end
        delete(exGrid.Children);
        ap = activePresets();
        exState = struct('name',{},'idx',{},'ax',{},'head',{},'pos',{});
        if isempty(ap)
            exGrid.RowHeight = {'fit'};
            uilabel(exGrid, "Text", "No labeled types yet.", ...
                "HorizontalAlignment", "center");
            return
        end
        exGrid.RowHeight = repmat({230}, 1, numel(ap));
        for k = 1:numel(ap)
            p = uipanel(exGrid);
            g = uigridlayout(p, [3 1]);
            g.RowHeight = {'fit', '1x', 'fit'};
            g.Padding = [4 2 4 4]; g.RowSpacing = 2;
            hg = uigridlayout(g, [1 4]);
            hg.ColumnWidth = {'1x', 24, 44, 24};
            hg.Padding = [0 0 0 0]; hg.ColumnSpacing = 2;
            head = uilabel(hg, "Text", "", "FontWeight", "bold");
            uibutton(hg, "Text", "◀", "ButtonPushedFcn", @(~,~) cycleExample(k, -1));
            posLbl = uilabel(hg, "Text", "", "HorizontalAlignment", "center", ...
                "FontSize", 11);
            uibutton(hg, "Text", "▶", "ButtonPushedFcn", @(~,~) cycleExample(k, +1));
            ax = uiaxes(g);
            ax.XTick = []; ax.YTick = [];
            disableDefaultInteractivity(ax);
            ax.Toolbar.Visible = "off";
            uibutton(g, "Text", "Assign to this type", ...
                "ButtonPushedFcn", @(~,~) commitLabel(ap(k)));
            exState(k) = struct('name', ap(k), 'idx', 1, 'ax', ax, ...
                'head', head, 'pos', posLbl);
            updateExample(k);
        end
    end

    function cycleExample(k, d)
        ids = typeExampleIds(exState(k).name);
        if isempty(ids), return; end
        exState(k).idx = mod(exState(k).idx - 1 + d, numel(ids)) + 1;
        updateExample(k);
    end

    function updateExample(k)
        st = exState(k);
        ids = typeExampleIds(st.name);
        hk = find(activePresets() == st.name, 1);
        hkStr = "";
        if ~isempty(hk) && hk <= 9, hkStr = sprintf(" [%d]", hk); end
        st.head.Text = sprintf("%s%s · %d cells", st.name, hkStr, numel(ids));
        if isempty(ids)
            cla(st.ax); st.pos.Text = "0/0";
            return
        end
        exState(k).idx = min(exState(k).idx, numel(ids));
        id = ids(exState(k).idx);
        st.pos.Text = sprintf("%d/%d", exState(k).idx, numel(ids));
        d = exampleData(id);
        cla(st.ax);
        set(st.ax, "NextPlot", "add");
        cols = [0.25 0.45 0.85; 0.55 0.60 0.30; 0.85 0.25 0.15];
        for j = 1:numel(d.y)
            plot(st.ax, d.t{j}, d.y{j}, "Color", cols(min(j, 3), :), ...
                "LineWidth", 0.5);
        end
        st.ax.XLim = [0, max(cellfun(@(t) t(end), d.t))];
        title(st.ax, string(id), "FontSize", 9, "FontWeight", "normal", ...
            "Interpreter", "none");
    end

    function d = exampleData(id)
        % hyperpolarizing / near-rheobase / max sweeps, min-max decimated
        % for fast plotting with spike peaks preserved; cached per cell
        if exCache.isKey(id), d = exCache{id}; return; end
        f = fullfile(cellsDir, id + ".h5");
        resp = h5read(f, "/response");
        if size(resp, 1) < size(resp, 2), resp = resp'; end
        cur = h5read(f, "/current_pa");
        fs = h5readatt(f, "/", "fs_hz");
        [~, o] = sort(cur); resp = resp(:, o); cur = cur(o);
        picks = unique([1, find(cur > 0, 1), numel(cur)]);
        d.t = {}; d.y = {};
        for j = picks(:)'
            y = resp(:, j); y = y(~isnan(y));
            [yb, tb] = minmaxDecim(y, 1500, fs);
            d.t{end+1} = tb; d.y{end+1} = yb; %#ok<AGROW>
        end
        exCache(id) = {d};
    end

    function [y2, t2] = minmaxDecim(y, nb, fs)
        n = numel(y);
        if n <= 2*nb
            y2 = y; t2 = (0:n-1)' / fs;
            return
        end
        edges = round(linspace(1, n+1, nb+1));
        y2 = zeros(2*nb, 1); t2 = zeros(2*nb, 1);
        for b = 1:nb
            seg = y(edges(b):edges(b+1)-1);
            y2(2*b-1) = min(seg); y2(2*b) = max(seg);
            tc = (edges(b) - 1) / fs;
            t2(2*b-1) = tc;
            t2(2*b) = tc + (edges(b+1) - edges(b)) / (2*fs);
        end
    end

    function syncExamplePanel(oldL, newL)
        if ~examplesOn, return; end
        ap = activePresets();
        if numel(ap) ~= numel(exState) || ...
                ~isequal(sort(ap(:)), sort(reshape([exState.name], [], 1)))
            rebuildExamplePanel();
            return
        end
        for k = 1:numel(exState)
            if exState(k).name == oldL || exState(k).name == newL
                updateExample(k);
            end
        end
    end

% =====================================================================
%                            hotkeys
% =====================================================================
    function onKey(evt)
        switch evt.Key
            case {'rightarrow', 'downarrow'}, step(+1);
            case {'leftarrow', 'uparrow'},    step(-1);
            case {'0', 'numpad0'},            commitLabel("");
            otherwise
                d = sscanf(evt.Key, '%d');
                if isempty(d)
                    d = sscanf(strrep(evt.Key, 'numpad', ''), '%d');
                end
                ap = activePresets();
                if ~isempty(d) && d >= 1 && d <= min(9, numel(ap))
                    commitLabel(ap(d));
                end
        end
    end
end
