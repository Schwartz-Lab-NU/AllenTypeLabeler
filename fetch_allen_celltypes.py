#!/usr/bin/env python
"""
fetch_allen_celltypes.py
========================

Download ALL Allen Cell Types Database intracellular ephys cells (mouse +
human), keep only the **Long Square** current-step sweeps, and write one
compact HDF5 per cell for the WASSUP labeling interface.

Pipeline per cell:
    1. download the full NWB1 file (api.brain-map.org well_known_file_download)
    2. extract sweeps with aibs_stimulus_name == 'Long Square'
    3. crop each sweep to [step_start - PRE_S, step_end + POST_S]
    4. decimate to ~TARGET_FS_HZ (anti-aliased, scipy.signal.decimate)
    5. write cells/<specimen_id>.h5, delete the NWB

Output layout (default root ~/WASSUP_allen):
    metadata.csv            one row per cell (ApiCellTypesSpecimenDetail)
    cells/<specimen_id>.h5  response (T, n_sweeps) float32 mV @ fs_hz,
                            current_pa, sweep_number, stim_start_s/stim_end_s
                            (relative to trace start), crop_offset_s
    logs/fetch.log          progress
    failures.csv            cells that errored (redownload by rerunning)

Resumable: cells whose .h5 already exists are skipped — just rerun.

NWB1 unit quirk: 'data' conversion attrs in these files are unreliable; the
response is stored in volts and the stimulus in amps. Heuristics below verify
this per sweep and log anything unexpected.

Usage:
    python scripts/fetch_allen_celltypes.py                 # everything
    python scripts/fetch_allen_celltypes.py --limit 3       # smoke test
    python scripts/fetch_allen_celltypes.py --workers 3
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import h5py
import numpy as np
from scipy.signal import decimate

API = "http://api.brain-map.org/api/v2"
TARGET_FS_HZ = 25_000.0
PRE_S = 0.25          # kept before step onset
POST_S = 0.75         # kept after step offset
MIN_STEP_S = 0.5      # a 'Long Square' step must be at least this long
MIN_FREE_GB = 10.0    # abort if the disk drops below this


# ---------------------------------------------------------------------------
# Cell list
# ---------------------------------------------------------------------------

def fetch_cell_list() -> list[dict]:
    """All ApiCellTypesSpecimenDetail rows with an ephys NWB (paged)."""
    rows, start = [], 0
    while True:
        url = (f"{API}/data/query.json?criteria=model::ApiCellTypesSpecimenDetail,"
               f"rma::options[num_rows$eq500][start_row$eq{start}]"
               f"[order$eq'specimen__id']")
        payload = None
        for attempt in range(4):
            try:
                with urllib.request.urlopen(url, timeout=60) as r:
                    payload = json.load(r)
                break
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(3 * (attempt + 1))
        if not payload["success"]:
            raise RuntimeError(f"cell list query failed: {payload.get('msg')}")
        rows.extend(payload["msg"])
        start += 500
        if start >= payload["total_rows"]:
            break
    rows = [r for r in rows if r.get("erwkf__id")]
    seen, uniq = set(), []
    for r in rows:
        if r["specimen__id"] not in seen:
            seen.add(r["specimen__id"])
            uniq.append(r)
    return uniq


def write_metadata_csv(cells: list[dict], path: Path):
    keys = sorted({k for c in cells for k in c})
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(cells)


# ---------------------------------------------------------------------------
# Unit heuristics (NWB1 conversion attrs are unreliable)
# ---------------------------------------------------------------------------

def response_to_mv(raw: np.ndarray, log) -> np.ndarray:
    """Return membrane potential in mV. Raw is normally volts (~ -0.09)."""
    base = float(np.nanmedian(np.abs(raw[: max(1, len(raw) // 20)])))
    if 0.005 < base < 0.5:        # volts
        return raw * 1e3
    if 5.0 < base < 500.0:        # already mV
        return raw
    log(f"    ! unexpected response scale (baseline~{base:g}), assuming volts")
    return raw * 1e3


def stim_to_pa(raw: np.ndarray) -> np.ndarray:
    """Return stimulus in pA. Raw is normally amps (~1e-10)."""
    peak = float(np.nanmax(np.abs(raw))) if len(raw) else 0.0
    if peak < 1e-6:               # amps
        return raw * 1e12
    return raw                    # already pA


# ---------------------------------------------------------------------------
# Step detection
# ---------------------------------------------------------------------------

def find_step_window(stim_pa: np.ndarray, amp_pa: float, fs: float):
    """
    (start_s, end_s) of the long current step, or None.

    Looks for contiguous runs where the stimulus deviates from baseline by
    >50% of the nominal amplitude and keeps the longest run >= MIN_STEP_S
    (the brief test pulse at the sweep start is shorter and gets rejected).
    """
    if not np.isfinite(amp_pa) or amp_pa == 0:
        return None
    baseline = np.median(stim_pa[: max(1, len(stim_pa) // 20)])
    mask = np.abs(stim_pa - baseline) > 0.5 * abs(amp_pa)
    if not mask.any():
        return None
    idx = np.flatnonzero(mask)
    gaps = np.flatnonzero(np.diff(idx) > 1)
    run_starts = np.r_[idx[0], idx[gaps + 1]]
    run_ends = np.r_[idx[gaps], idx[-1]]
    best = None
    for s, e in zip(run_starts, run_ends):
        dur = (e - s + 1) / fs
        if dur >= MIN_STEP_S and (best is None or dur > best[2]):
            best = (s / fs, (e + 1) / fs, dur)
    return None if best is None else (best[0], best[1])


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_cell(nwb_path: Path, out_path: Path, specimen: dict, log) -> dict:
    """Extract Long Square sweeps from one NWB1 file -> compact HDF5."""
    sid = specimen["specimen__id"]
    with h5py.File(nwb_path, "r") as f:
        acq = f["acquisition/timeseries"]
        stim_grp = f["stimulus/presentation"]
        sweeps = []
        for name in acq:
            g = acq[name]
            if "aibs_stimulus_name" not in g:
                continue
            if g["aibs_stimulus_name"][()] != b"Long Square":
                continue
            fs = float(g["starting_time"].attrs["rate"])
            amp = float(g["aibs_stimulus_amplitude_pa"][()])
            resp_mv = response_to_mv(np.asarray(g["data"][:], np.float64), log)
            spa = stim_to_pa(np.asarray(stim_grp[name]["data"][:], np.float64))
            win = find_step_window(spa, amp, fs)
            num = int(name.split("_")[-1])
            sweeps.append(dict(num=num, fs=fs, amp=amp, mv=resp_mv, win=win))

    if not sweeps:
        raise ValueError("no Long Square sweeps in file")

    # fall back to the modal window for sweeps where detection failed
    wins = [s["win"] for s in sweeps if s["win"] is not None]
    if not wins:
        raise ValueError("no detectable current step in any Long Square sweep")
    med_win = (float(np.median([w[0] for w in wins])),
               float(np.median([w[1] for w in wins])))

    traces, meta = [], []
    for s in sorted(sweeps, key=lambda x: x["amp"]):
        fs = s["fs"]
        w0, w1 = s["win"] if s["win"] is not None else med_win
        q = max(1, int(round(fs / TARGET_FS_HZ)))
        i0 = max(0, int((w0 - PRE_S) * fs))
        i1 = min(len(s["mv"]), int((w1 + POST_S) * fs))
        seg = s["mv"][i0:i1]
        if q > 1:
            seg = decimate(seg, q, ftype="fir", zero_phase=True)
        traces.append(seg.astype(np.float32))
        meta.append(dict(
            num=s["num"], amp=s["amp"], fs_native=fs, fs_out=fs / q,
            crop_offset_s=i0 / fs,
            stim_start_s=w0 - i0 / fs, stim_end_s=w1 - i0 / fs,
            step_detected=s["win"] is not None,
        ))

    fs_out = {m["fs_out"] for m in meta}
    if len(fs_out) > 1:
        log(f"    ! {sid}: mixed output rates {fs_out}, keeping all")

    T = max(len(t) for t in traces)
    mat = np.full((T, len(traces)), np.nan, np.float32)
    for j, t in enumerate(traces):
        mat[: len(t), j] = t

    tmp = out_path.with_suffix(".h5.part")
    with h5py.File(tmp, "w") as hf:
        hf.create_dataset("response", data=mat, compression="gzip",
                          compression_opts=4)
        hf.create_dataset("current_pa", data=[m["amp"] for m in meta])
        hf.create_dataset("sweep_number", data=[m["num"] for m in meta],
                          dtype=np.int32)
        hf.create_dataset("stim_start_s", data=[m["stim_start_s"] for m in meta])
        hf.create_dataset("stim_end_s", data=[m["stim_end_s"] for m in meta])
        hf.create_dataset("crop_offset_s", data=[m["crop_offset_s"] for m in meta])
        hf.create_dataset("step_detected",
                          data=[m["step_detected"] for m in meta], dtype=np.int8)
        hf.attrs["specimen_id"] = sid
        hf.attrs["specimen_name"] = specimen.get("specimen__name") or ""
        hf.attrs["species"] = specimen.get("donor__species") or ""
        hf.attrs["structure"] = specimen.get("structure__acronym") or ""
        hf.attrs["layer"] = specimen.get("structure__layer") or ""
        hf.attrs["line_name"] = specimen.get("line_name") or ""
        hf.attrs["dendrite_type"] = specimen.get("tag__dendrite_type") or ""
        hf.attrs["fs_hz"] = meta[0]["fs_out"]
        hf.attrs["fs_native_hz"] = meta[0]["fs_native"]
        hf.attrs["units"] = "mV"
        hf.attrs["stim_name"] = "Long Square"
    os.replace(tmp, out_path)
    return dict(n_sweeps=len(traces), T=T,
                amps=f"{meta[0]['amp']:.0f}..{meta[-1]['amp']:.0f}")


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

def download_nwb(erwkf_id: int, dest: Path, tries: int = 3):
    url = f"{API}/well_known_file_download/{erwkf_id}"
    for attempt in range(1, tries + 1):
        try:
            tmp = dest.with_suffix(".part")
            with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f, length=1 << 20)
            os.replace(tmp, dest)
            return
        except Exception:
            if attempt == tries:
                raise
            time.sleep(5 * attempt)


def process_one(specimen: dict, root: Path, log) -> str:
    sid = specimen["specimen__id"]
    out = root / "cells" / f"{sid}.h5"
    if out.exists():
        return "skip"
    if shutil.disk_usage(root).free / 1e9 < MIN_FREE_GB:
        raise RuntimeError(f"disk below {MIN_FREE_GB} GB free — aborting")
    nwb = root / "nwb_tmp" / f"{sid}.nwb"
    try:
        download_nwb(specimen["erwkf__id"], nwb)
        info = extract_cell(nwb, out, specimen, log)
        return f"ok {info['n_sweeps']} sweeps, T={info['T']}, {info['amps']} pA"
    finally:
        nwb.unlink(missing_ok=True)
        nwb.with_suffix(".part").unlink(missing_ok=True)


# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=str(Path.home() / "WASSUP_allen"))
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--species", choices=["all", "mouse", "human"], default="all",
                    help="restrict downloads (metadata.csv always keeps all cells)")
    args = ap.parse_args(argv)

    root = Path(args.root)
    for d in ("cells", "nwb_tmp", "logs"):
        (root / d).mkdir(parents=True, exist_ok=True)

    logf = open(root / "logs" / "fetch.log", "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    log(f"=== run start (pid {os.getpid()}) ===")
    cells = fetch_cell_list()
    write_metadata_csv(cells, root / "metadata.csv")
    n_h = sum(c["donor__species"] == "Homo Sapiens" for c in cells)
    log(f"{len(cells)} cells with ephys NWB ({n_h} human, {len(cells)-n_h} mouse); "
        f"metadata.csv written")

    want = {"mouse": "Mus musculus", "human": "Homo Sapiens"}.get(args.species)
    todo = [c for c in cells
            if (want is None or c["donor__species"] == want)
            and not (root / "cells" / f"{c['specimen__id']}.h5").exists()]
    if args.limit:
        todo = todo[: args.limit]
    log(f"{len(todo)} to fetch, {len(cells) - len(todo)} already done")

    failures, done = [], 0
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(process_one, c, root, log): c for c in todo}
        for fut in as_completed(futs):
            c = futs[fut]
            sid = c["specimen__id"]
            done += 1
            try:
                res = fut.result()
                log(f"[{done}/{len(todo)}] {sid} ({c['donor__species'][:5]}): {res}")
            except Exception as e:
                log(f"[{done}/{len(todo)}] {sid} FAILED: {type(e).__name__}: {e}")
                failures.append((sid, c["erwkf__id"], f"{type(e).__name__}: {e}"))
                if "disk below" in str(e):
                    for other in futs:
                        other.cancel()
                    break

    if failures:
        with open(root / "failures.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["specimen_id", "erwkf_id", "error"])
            w.writerows(failures)
        log(f"{len(failures)} failures -> failures.csv (rerun to retry)")
    n_done = len(list((root / "cells").glob("*.h5")))
    log(f"=== run end: {n_done}/{len(cells)} cells on disk ===")


if __name__ == "__main__":
    main()
