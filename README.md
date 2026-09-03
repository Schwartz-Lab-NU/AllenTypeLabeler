# AllenTypeLabeler

Browse every intracellular current-clamp recording (Long Square current steps)
in the [Allen Cell Types Database](https://celltypes.brain-map.org) and assign
your own cell-type labels — built for the WASSUP project (labels become the
`cell_type` field for embedding evaluation).

Two pieces:

1. **`fetch_allen_celltypes.py`** — downloads all 2,333 cells (1,920 mouse +
   413 human), keeps only the Long Square sweeps, and writes one compact HDF5
   per cell (~3 MB; ~8 GB total instead of ~500 GB of raw NWBs).
2. **`AllenTypeLabeler.m`** — MATLAB app to scroll cells, view sweeps + f-I,
   and record labels.

## Setup

This repo doubles as the data root. Clone it (e.g. to `~/WASSUP_allen`), then:

```bash
python3 fetch_allen_celltypes.py                    # everything (hours)
python3 fetch_allen_celltypes.py --species mouse    # mouse only
```

Needs `numpy`, `scipy`, `h5py`. Resumable — rerun to retry failures or fill
gaps; already-extracted cells are skipped. Use `caffeinate -ims python3 ...`
on macOS so the machine doesn't sleep. Data lands in `cells/` (gitignored),
plus `metadata.csv` (regenerated each run).

## Labeling

In MATLAB (R2023b+), from the repo directory:

```matlab
AllenTypeLabeler            % or AllenTypeLabeler(rootDir)
```

| Key | Action |
|-----|--------|
| → / ← | next / previous cell |
| 1–9 | assign preset label (and auto-advance) |
| 0 | clear label |

The "Next unlabeled" toolbar button jumps to the next cell without a label.

Type any new label in the Type box + Enter — it is saved, added to
`label_presets.txt`, and gains the next free hotkey. The Mouse/Human switch
picks the dataset; Rescan picks up cells while the download is still running.

**Autosave:** every label/notes change immediately rewrites `labels.csv`
(written to a temp file, then atomically renamed) — there is no save button
and nothing to lose. Commit `labels.csv` periodically for versioned backup.

## Output: `labels.csv`

| column | contents |
|--------|----------|
| `specimen_id` | Allen Cell Types specimen ID (joins everything) |
| `label` | your type label |
| `notes` | free text |
| `allen_e_type` / `allen_m_type` / `allen_me_type` | Gouwens 2019 cluster assignments |
| `timestamp` | last edit |

## Allen cluster types (blinded by default)

`allen_cluster_labels.csv` holds the per-cell e/m/me-type cluster assignments
from [Gouwens et al. 2019, *Nat Neurosci*](https://doi.org/10.1038/s41593-019-0417-0)
(Supplementary Data 5): e-types for 1,933 cells (1,868 of the 1,920 mouse
cells here), m/me-types for the ~460 morphologically reconstructed ones.
The app hides them unless "Show Allen types" is checked, so you can label
blind and peek per cell.

## Per-cell HDF5 layout (`cells/<specimen_id>.h5`)

- `response` — (T × nSweeps) float32, mV, 25 kHz (decimated from 200 kHz),
  NaN-padded, sweeps sorted by current. Each sweep cropped to
  [step −0.25 s, step end +0.75 s] (2 s for the standard 1 s step)
- `current_pa`, `sweep_number`, `stim_start_s`, `stim_end_s` (relative to
  trace start), `crop_offset_s` (trace start within the original sweep),
  `step_detected`
- attrs: `specimen_id`, `species`, `structure`, `layer`, `line_name`,
  `dendrite_type`, `fs_hz`, `fs_native_hz`, `units`

NWB1 quirks handled by the fetcher: the `conversion` attributes in Allen's
NWB1 files are unreliable (response is stored in volts, stimulus in amps),
and RMA API paging requires an explicit `[order$eq'specimen__id']` or pages
overlap and drop rows.
