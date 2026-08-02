#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
analyze_swing.py — turn a tracked ball path (CSV from track_ball.py) into
launch angle + exit velocity, with confidence flags and diagnostic plots.

Usage:
  python analyze_swing.py out/tee_01.csv
  python analyze_swing.py out/fly_02.csv --flyball --hang 4.2 --carry-m 210

Fly-ball mode cross-checks the video-derived numbers against physics you can
measure with no instruments: stopwatch hang time and a paced-off landing
distance. That is the ground truth substitute for a radar gun (G3).
"""

from __future__ import annotations

import argparse
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

import sla_common as sla



def make_plots(track, metrics, stem):
    ts = np.array([o.t for o in track]) - metrics.t0
    xs = np.array([o.x for o in track])
    ys = np.array([o.y for o in track])
    ds = np.array([o.diameter_px for o in track])

    fig, axes = plt.subplots(1, 3, figsize=(16, 5))
    ax = axes[0]
    ax.plot(xs, -ys, "o-", ms=3, label="track (y up)")
    ax.set_title(f"trajectory  LA={metrics.launch_angle_deg:.1f} deg  EV={metrics.exit_velo_mph:.1f} mph")
    ax.set_xlabel("x [px]")
    ax.set_ylabel("-y [px]")
    ax.axis("equal")
    ax.legend()

    ax = axes[1]
    cx = np.polyfit(ts, xs, 2)
    cy = np.polyfit(ts, ys, 2)
    ax.plot(ts, xs - np.polyval(cx, ts), ".-", label="x residual")
    ax.plot(ts, ys - np.polyval(cy, ts), ".-", label="y residual")
    ax.axhline(0, color="k", lw=0.5)
    ax.set_title(f"quadratic-fit residuals (rms={metrics.fit_rms_px:.2f} px)")
    ax.set_xlabel("t - t0 [s]")
    ax.set_ylabel("px")
    ax.legend()

    ax = axes[2]
    ax.plot(ts, ds, ".-")
    ax.set_title(f"apparent diameter (drift={metrics.diameter_drift*100:+.1f}%)")
    ax.set_xlabel("t - t0 [s]")
    ax.set_ylabel("minor axis [px]")

    fig.tight_layout()
    out = os.path.join("out", stem + "_analysis.png")
    os.makedirs("out", exist_ok=True)
    fig.savefig(out, dpi=110)
    plt.close(fig)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--roll-deg", type=float, default=0.0, help="camera roll correction (deg, CCW positive)")
    ap.add_argument("--window-s", type=float, default=sla.VELOCITY_WINDOW_S)
    ap.add_argument("--gravity-window-s", type=float, default=sla.GRAVITY_WINDOW_S)
    ap.add_argument("--no-plots", action="store_true")
    ap.add_argument("--json", help="also write metrics as JSON to this path")
    ap.add_argument("--flyball", action="store_true", help="enable physics cross-check")
    ap.add_argument("--hang", type=float, help="stopwatch hang time [s] (flyball mode)")
    ap.add_argument("--carry-m", type=float, help="paced-off carry distance [ft] (flyball mode)")
    args = ap.parse_args()

    track, meta = sla.read_track_csv(args.csv)
    contact_time = float(meta["contact_time"]) if "contact_time" in meta else None
    metrics = sla.analyze_track(
        track,
        contact_time=contact_time,
        velocity_window_s=args.window_s,
        gravity_window_s=args.gravity_window_s,
        roll_deg=args.roll_deg,
    )

    print(f"== {os.path.basename(args.csv)} ==")
    print(f"  launch angle : {metrics.launch_angle_deg:8.2f} deg")
    print(f"  exit velo    : {metrics.exit_velo_mph:8.2f} mph  ({metrics.exit_velo_mps:.2f} m/s)")
    print(f"  frames       : {metrics.n_frames}  ({metrics.track_duration_s*1000:.0f} ms of flight)")
    print(f"  scale (ball) : {metrics.scale_ball_m_per_px*1000:8.3f} mm/px")
    if metrics.scale_gravity_m_per_px:
        print(f"  scale (grav) : {metrics.scale_gravity_m_per_px*1000:8.3f} mm/px"
              f"   disagreement {metrics.scale_disagreement*100:.1f}%")
    else:
        print("  scale (grav) : n/a (track too short for a per-swing gravity check)")
    print(f"  diam drift   : {metrics.diameter_drift*100:+8.1f}%  (depth-motion indicator)")
    print(f"  fit rms      : {metrics.fit_rms_px:8.2f} px")
    print(f"  confidence   : {'HIGH' if metrics.high_confidence else 'LOW: ' + ', '.join(metrics.flags)}")

    if args.flyball:
        # Drag matters: a softball flies at ~terminal velocity, so all G3
        # comparisons go through the drag model, never vacuum formulas.
        print("  -- fly-ball physics cross-check (G3) --")
        carry_m, hang_s, apex_m = sla.simulate_flight(metrics.exit_velo_mps, metrics.launch_angle_deg)
        print(f"  drag model from video LA/EV: carry {carry_m*FT_PER_M:.0f} ft, "
              f"hang {hang_s:.2f} s, apex {apex_m*FT_PER_M:.0f} ft")
        if args.hang:
            diff = (hang_s - args.hang) / args.hang * 100
            print(f"  hang: model {hang_s:.2f} s vs stopwatch {args.hang:.2f} s ({diff:+.1f}%)"
                  f"  {'PASS' if abs(diff) <= 15 else 'FAIL'} (tol 15%)")
        if args.carry_m:
            diff = (carry_m - args.carry_m) / args.carry_m * 100
            print(f"  carry: model {carry_m:.1f} m vs paced {args.carry_m:.1f} m ({diff:+.1f}%)"
                  f"  {'PASS' if abs(diff) <= 20 else 'FAIL'} (tol 20%)")

    if not args.no_plots:
        out = make_plots(track, metrics, os.path.splitext(os.path.basename(args.csv))[0])
        print(f"  plots        : {out}")

    if args.json:
        with open(args.json, "w") as f:
            json.dump({
                "csv": args.csv, "la_deg": metrics.launch_angle_deg,
                "ev_mph": metrics.exit_velo_mph, "n_frames": metrics.n_frames,
                "scale_ball": metrics.scale_ball_m_per_px,
                "scale_gravity": metrics.scale_gravity_m_per_px,
                "scale_disagreement": metrics.scale_disagreement,
                "diameter_drift": metrics.diameter_drift,
                "fit_rms_px": metrics.fit_rms_px, "flags": metrics.flags,
            }, f, indent=2)


if __name__ == "__main__":
    main()
