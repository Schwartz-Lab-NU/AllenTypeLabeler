# Implementation Plan: AllenTypeLabeler

**Architecture:** UIFigure app (programmatic, single `.m`, no App Designer dependency)
**Layout:** Explorer — toolbar (spans top) + fixed sidebar (280 px) + main display

**Data contract** (produced by `dandi_wassup/scripts/fetch_allen_celltypes.py`):
- `~/WASSUP_allen/metadata.csv` — 2,333 rows (ApiCellTypesSpecimenDetail)
- `~/WASSUP_allen/cells/<specimen_id>.h5` — `response` (T×nSweeps float32 mV @25 kHz),
  `current_pa`, `sweep_number`, `stim_start_s`, `stim_end_s` + attrs
- `~/WASSUP_allen/labels.csv` — output: specimen_id, label, notes, timestamp (app-owned)
- `~/WASSUP_allen/label_presets.txt` — one label per line; first 9 map to hotkeys 1–9

**Structure:**
- Toolbar row (fit): Prev / Next buttons, progress label ("cell i/N — k labeled"),
  species filter (All/Mouse/Human), status filter (All/Unlabeled/Labeled),
  auto-advance checkbox, Rescan button (picks up cells still downloading)
- Sidebar (280 px): cell list (uilistbox, ✓-marked when labeled), metadata block
  (species, region+layer, Cre line, dendrite type, Allen ephys features:
  Vrest, Ri, tau, rheobase, f-I slope, upstroke/downstroke, adaptation)
- Main column: large sweep axes ('1x') — all long-square sweeps overlaid, colored
  blue→red by injected current, stim on/off marked; small f-I axes below (fit,
  ~140 px): spike count (0 mV upward crossings in stim window) vs current
- Label panel under main axes: editable dropdown (presets + free text),
  notes field, Clear button, hotkey legend

**Key behaviors:**
- ←/→ browse cells (within active filter); 1–9 assign preset label; 0 clears;
  u jumps to next unlabeled; label assign optionally auto-advances
- Every label/notes change immediately rewrites labels.csv (durable, mergeable
  into the WASSUP pickle as `cell_type` keyed by specimen_id)
- New free-text labels are appended to label_presets.txt and gain the next hotkey
- Cells whose .h5 hasn't downloaded yet are listed grayed and skipped; Rescan
  refreshes without restart
- All text set with Interpreter 'none' semantics (Cre lines/specimen names carry underscores)

**Internal references used:**

| Reference | Role |
|-----------|------|
| `references/archetypes/explorer.md` | toolbar+sidebar+main uigridlayout skeleton |
| `references/uifigure/guide.md` | grid rules, fit/1x sizing, callback conventions |

**File organization:** single file `~/WASSUP_allen/AllenTypeLabeler.m`

**Implementation sequence:**
1. Grid skeleton (toolbar / sidebar / main) per explorer.md
2. Data layer: metadata load, labels.csv load/save, h5 cell reader
3. Plot update (sweep overlay + f-I) and metadata rendering
4. Label commit path + presets/hotkeys + navigation/filtering
5. Headless smoke test via MATLAB MCP (Visible off, drive callbacks, verify CSV)
