#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
batch_run.py — run the whole clips/ folder and build the go/no-go summary.

Usage:
  python batch_run.py                    # tracks (auto mode) + analyzes clips/
  python batch_run.py --fps 240          # force fps for every clip
  python batch_run.py --clips-dir clips  --out out/summary.csv

Relies on the naming convention from docs/CAPTURE_PROTOCOL.md:
  <setting>_<nn>.mov   where setting is one of: tee, teeid (the 5
  identical-intent repeatability swings), toss, live, cage, net, fly
Clips that already have a CSV in out/ are not re-tracked (delete the CSV to
redo one, e.g. after fixing its contact frame interactively).

Output: out/summary.csv + a printed G1/G2/G4 scoreboard against the
VALIDATION.md thresholds.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import statistics
import subprocess
import sys

import numpy as np

import sla_common as sla

SETTINGS = ("teeid", "tee", "toss", "live", "cage", "net", "fly")
G1_THRESHOLDS = {"tee": 0.90, "teeid": 0.90, "toss": 0.90, "live": 0.80,
                 "cage": 0.70, "net": 0.0, "fly": 0.80}
G1_MIN_FRAMES = 12


def setting_of(name: str) -> str:
    base = os.path.basename(name).lower()
    for s in SETTINGS:
        if base.startswith(s):
            return s
    return "other"


def ensure_tracked(clip: str, fps: float | None) -> str | None:
    stem = os.path.splitext(os.path.basename(clip))[0]
    out_csv = os.path.join("out", stem + ".csv")
    if os.path.exists(out_csv):
        return out_csv
    cmd = [sys.executable, "track_ball.py", clip, "--auto", "--out", out_csv]
    if fps:
        cmd += ["--fps", str(fps)]
    print(f"tracking {clip} ...")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  no track: {os.path.basename(clip)}")
        return None
    return out_csv


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips-dir", default="clips")
    ap.add_argument("--fps", type=float, help="override container fps for all clips (use 240)")
    ap.add_argument("--out", default="out/summary.csv")
    args = ap.parse_args()

    clips = sorted(
        p for ext in ("*.mov", "*.MOV", "*.mp4", "*.MP4")
        for p in glob.glob(os.path.join(args.clips_dir, ext))
    )
    if not clips:
        print(f"no clips found in {args.clips_dir}/ — see clips/README.md")
        sys.exit(1)

    os.makedirs("out", exist_ok=True)
    rows = []
    for clip in clips:
        setting = setting_of(clip)
        csv_path = ensure_tracked(clip, args.fps)
        if csv_path is None:
            rows.append({"clip": os.path.basename(clip), "setting": setting, "tracked": 0})
            continue
        track, meta = sla.read_track_csv(csv_path)
        contact_time = float(meta["contact_time"]) if "contact_time" in meta else None
        m = sla.analyze_track(track, contact_time=contact_time)
        rows.append({
            "clip": os.path.basename(clip), "setting": setting, "tracked": m.n_frames,
            "la_deg": round(m.launch_angle_deg, 2), "ev_mph": round(m.exit_velo_mph, 2),
            "scale_ball_mm_px": round(m.scale_ball_m_per_px * 1000, 3),
            "scale_grav_mm_px": round(m.scale_gravity_m_per_px * 1000, 3) if m.scale_gravity_m_per_px else "",
            "disagree_pct": round(m.scale_disagreement * 100, 1) if m.scale_disagreement is not None else "",
            "drift_pct": round(m.diameter_drift * 100, 1),
            "fit_rms_px": round(m.fit_rms_px, 2),
            "flags": "|".join(m.flags),
            "verdict": "ok" if m.high_confidence else "low-conf",
        })

    fields = ["clip", "setting", "tracked", "la_deg", "ev_mph", "scale_ball_mm_px",
              "scale_grav_mm_px", "disagree_pct", "drift_pct", "fit_rms_px", "flags", "verdict"]
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})
    print(f"\nwrote {args.out}  ({len(rows)} clips)\n")

    # ---- scoreboard vs VALIDATION.md ----
    print("=== go/no-go scoreboard (fill VALIDATION.md with these) ===")
    by_setting: dict[str, list[dict]] = {}
    for r in rows:
        by_setting.setdefault(r["setting"], []).append(r)

    print("\nG1 trackability (>=12 consecutive tracked frames):")
    for s, rs in sorted(by_setting.items()):
        ok = sum(1 for r in rs if int(r.get("tracked", 0)) >= G1_MIN_FRAMES)
        pct = ok / len(rs)
        thr = G1_THRESHOLDS.get(s)
        mark = "" if thr is None else ("  PASS" if pct >= thr else f"  FAIL (need {thr:.0%})")
        print(f"  {s:6s}: {ok}/{len(rs)} = {pct:.0%}{mark}")

    dis = [float(r["disagree_pct"]) for r in rows
           if r.get("disagree_pct") not in ("", None) and r["setting"] not in ("cage", "net")]
    if dis:
        med = statistics.median(dis)
        print(f"\nG2 scale agreement (outdoor, median): {med:.1f}%  "
              f"{'PASS' if med <= sla.SCALE_DISAGREE_TOL*100 else 'FAIL'} (tol {sla.SCALE_DISAGREE_TOL*100:.0f}%)")
    else:
        print("\nG2 scale agreement: no clips with a usable gravity check yet")

    ident = [r for r in by_setting.get("teeid", []) if r.get("ev_mph")]
    if len(ident) >= 3:
        evs = [float(r["ev_mph"]) for r in ident]
        las = [float(r["la_deg"]) for r in ident]
        ev_sd, la_sd = float(np.std(evs, ddof=1)), float(np.std(las, ddof=1))
        print(f"\nG4 repeatability (teeid_*): EV sd={ev_sd:.2f} mph "
              f"{'PASS' if ev_sd <= 3 else 'FAIL'} | LA sd={la_sd:.2f} deg "
              f"{'PASS' if la_sd <= 3 else 'FAIL'}")
    else:
        print("\nG4 repeatability: need >=3 tracked teeid_* clips")

    print("\nG3 (fly balls) is per-clip: run analyze_swing.py --flyball on fly_* CSVs")
    print("G5 (audio trigger): run check_audio_trigger.py on a few clips")


if __name__ == "__main__":
    main()
