#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
synth_test.py — end-to-end self-test of the measurement pipeline.

Renders a synthetic 240fps clip of a motion-blurred optic-yellow ball flying
a drag-affected trajectory with KNOWN launch angle, exit velocity and scale,
then runs the exact detection -> tracking -> analysis pipeline the field
scripts use, and asserts the truth is recovered within tolerance.

Run it after `pip install -r requirements.txt` to confirm your install works:

  python synth_test.py            ->  ... ALL PASS

No GUI, no clip files needed. Writes its temp video into out/.
"""

from __future__ import annotations

import math
import os
import sys

import cv2
import numpy as np

import sla_common as sla

# Ground truth
FPS = 240.0
W, H = 1920, 1080
PX_PER_M = 250.0                    # true scale = 4.000 mm/px
TRUE_SCALE = 1.0 / PX_PER_M
TRUE_EV_MPH = 65.0
TRUE_LA_DEG = 25.0
SHUTTER_S = 1.0 / 1000.0            # motion-blur smear length source
WARMUP_FRAMES = 30                  # static frames so MOG2 learns the background
LAUNCH_XY = (150.0, 900.0)          # px, y down-positive
CONTACT_FRAME = WARMUP_FRAMES

BALL_BGR = (0, 255, 204)            # optic yellow


def simulate_positions(n_frames: int):
    """Integrate the drag model at fine dt; sample position/velocity per frame."""
    ev = TRUE_EV_MPH / sla.MPH_PER_MPS
    la = math.radians(TRUE_LA_DEG)
    k_over_m = 0.5 * sla.AIR_DENSITY * sla.DRAG_CD * math.pi * (sla.BALL_DIAMETER_M / 2) ** 2 / sla.BALL_MASS_KG
    vx, vy = ev * math.cos(la), ev * math.sin(la)      # m/s, y up-positive
    x_m, y_m = 0.0, 0.0
    dt = 1.0 / (FPS * 10.0)
    out = []                                           # (x_px, y_px, vx_px, vy_px_down)
    for _f in range(n_frames):
        out.append((
            LAUNCH_XY[0] + x_m * PX_PER_M,
            LAUNCH_XY[1] - y_m * PX_PER_M,
            vx * PX_PER_M,
            -vy * PX_PER_M,
        ))
        for _ in range(10):
            v = math.hypot(vx, vy)
            ax = -k_over_m * v * vx
            ay = -sla.G - k_over_m * v * vy
            vx += ax * dt
            vy += ay * dt
            x_m += vx * dt
            y_m += vy * dt
    return out


def render_clip(path: str) -> int:
    """Draw background + motion-blurred ball; return number of ball frames."""
    rng = np.random.default_rng(7)
    yy = np.linspace(0, 1, H, dtype=np.float32)[:, None]
    base = np.zeros((H, W, 3), np.uint8)
    base[:, :, 0] = (40 + 30 * yy).astype(np.uint8)          # B
    base[:, :, 1] = (95 + 40 * yy).astype(np.uint8)          # G (grassy)
    base[:, :, 2] = (55 + 25 * yy).astype(np.uint8)          # R
    for x in range(0, W, 160):                                # fence posts
        cv2.line(base, (x, 0), (x, H), (35, 60, 40), 5)

    vw = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 60.0, (W, H))
    if not vw.isOpened():
        raise IOError("VideoWriter failed to open (mp4v)")

    d_px = sla.BALL_DIAMETER_M * PX_PER_M                     # 24.3 px
    traj = simulate_positions(400)
    ball_frames = 0
    total = 0
    for f in range(WARMUP_FRAMES + 400):
        frame = base.copy()
        noise = rng.integers(-6, 7, (H, W, 1), dtype=np.int16)
        frame = np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        if f >= CONTACT_FRAME:
            x, y, vx_px, vy_px = traj[f - CONTACT_FRAME]
            if not (0 <= x < W and 0 <= y < H):
                break
            speed_px = math.hypot(vx_px, vy_px)
            smear = speed_px * SHUTTER_S
            ang = math.degrees(math.atan2(vy_px, vx_px))
            axes = (int(round((d_px + smear) / 2)), int(round(d_px / 2)))
            cv2.ellipse(frame, (int(round(x)), int(round(y))), axes, ang, 0, 360, BALL_BGR, -1)
            ball_frames += 1
        vw.write(frame)
        total += 1
    vw.release()
    print(f"rendered {total} frames ({ball_frames} with ball) -> {path}")
    return ball_frames


def run_pipeline(path: str):
    cap = cv2.VideoCapture(path)
    bg = sla.make_bg_subtractor()
    per_frame = {}
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        fg = bg.apply(frame)
        _, fg = cv2.threshold(fg, 127, 255, cv2.THRESH_BINARY)
        fg = cv2.dilate(fg, np.ones((5, 5), np.uint8))
        cands = sla.detect_ball_candidates(frame, idx, idx / FPS, fg_mask=fg)
        if cands:
            per_frame[idx] = cands
        idx += 1
    cap.release()

    tracks = sla.build_tracks(per_frame, FPS)
    track = sla.select_outbound_track(tracks, FPS)
    if track is None:
        raise AssertionError("no track found on synthetic clip")
    return track


def check_tilt_against_pinhole(check) -> None:
    """Rectify a track projected by an INDEPENDENT pinhole camera.

    The round-trip test in `main` cannot catch a wrong tilt model, because it
    projects with the algebraic inverse of the thing it is testing. This starts
    from world coordinates — a ball at a known elevation, seen by a camera
    pitched by a known angle — and asks whether rectification recovers what a
    level camera would have seen. Nothing here shares code with
    `rectify_tilt_point`, so agreement means the model is right, not merely
    self-consistent.
    """
    w, h, fov = 1280, 720, 60.0
    focal = sla.focal_px_from_fov(w, fov)
    cx, cy = w / 2.0, h / 2.0

    def image_y(elev_deg: float, tilt_deg: float) -> float:
        # A ray at `elev` above horizontal sits (elev + tilt) above the optical
        # axis of a camera pitched DOWN by `tilt`.
        return cy - focal * math.tan(math.radians(elev_deg + tilt_deg))

    worst = 0.0
    for elev in (-10.0, 0.0, 5.0, 15.0):
        for tilt in (8.0, -8.0, 16.0, -16.0):
            _, y_rect, _ = sla.rectify_tilt_point(
                cx, image_y(elev, tilt), tilt, focal, cx, cy)
            worst = max(worst, abs(y_rect - image_y(elev, 0.0)))
    check("tilt model matches an independent pinhole", worst < 1e-6,
          f"worst error {worst:.4f} px (tol 1e-6)")


def main():
    os.makedirs("out", exist_ok=True)
    path = os.path.join("out", "synthetic.mp4")
    render_clip(path)
    track = run_pipeline(path)
    m = sla.analyze_track(track, contact_time=CONTACT_FRAME / FPS)

    print(f"\ntruth   : LA={TRUE_LA_DEG:.2f} deg  EV={TRUE_EV_MPH:.2f} mph  scale={TRUE_SCALE*1000:.3f} mm/px")
    print(f"measured: LA={m.launch_angle_deg:.2f} deg  EV={m.exit_velo_mph:.2f} mph  "
          f"scale_ball={m.scale_ball_m_per_px*1000:.3f} mm/px  "
          f"scale_grav={(m.scale_gravity_m_per_px or float('nan'))*1000:.3f} mm/px")
    print(f"track   : {m.n_frames} frames, {m.track_duration_s*1000:.0f} ms, "
          f"fit rms {m.fit_rms_px:.2f} px, flags={m.flags or 'none'}\n")

    checks = []

    def check(name, ok, detail):
        checks.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    check("contact frame", track[0].frame - CONTACT_FRAME <= 2,
          f"track starts frame {track[0].frame}, truth {CONTACT_FRAME}")
    check("launch angle", abs(m.launch_angle_deg - TRUE_LA_DEG) <= 1.5,
          f"err {m.launch_angle_deg - TRUE_LA_DEG:+.2f} deg (tol 1.5)")
    ev_err = m.exit_velo_mph / TRUE_EV_MPH - 1
    check("exit velocity", abs(ev_err) <= 0.03, f"err {ev_err*100:+.1f}% (tol 3%)")
    sb_err = m.scale_ball_m_per_px / TRUE_SCALE - 1
    check("diameter scale", abs(sb_err) <= 0.03, f"err {sb_err*100:+.1f}% (tol 3%)")
    if m.scale_gravity_m_per_px:
        sg_err = m.scale_gravity_m_per_px / TRUE_SCALE - 1
        check("gravity scale (drag-aware)", abs(sg_err) <= 0.05, f"err {sg_err*100:+.1f}% (tol 5%)")
        check("scale cross-check agrees", (m.scale_disagreement or 1) <= sla.SCALE_DISAGREE_TOL,
              f"disagreement {(m.scale_disagreement or 1)*100:.1f}% (tol {sla.SCALE_DISAGREE_TOL*100:.0f}%)")
    else:
        check("gravity scale (drag-aware)", False, "not computed (track too short?)")

    # CSV round-trip
    csv_path = os.path.join("out", "synthetic.csv")
    sla.write_track_csv(csv_path, track, FPS, meta={"contact_frame": CONTACT_FRAME,
                                                    "contact_time": f"{CONTACT_FRAME/FPS:.6f}"})
    rt, meta = sla.read_track_csv(csv_path)
    check("CSV round-trip", len(rt) == len(track) and "contact_time" in meta,
          f"{len(rt)} rows, meta keys {sorted(meta)}")

    # --- camera tilt: does the rectification actually recover the truth? ---
    #
    # NOTE ON WHAT THIS DOES AND DOES NOT PROVE. The re-projection below is the
    # algebraic inverse of `rectify_tilt`, so this half is a ROUND TRIP: it
    # would pass even if both directions shared a wrong model or a flipped
    # sign, because the error would cancel. It is still worth having — it pins
    # the two against each other numerically — but it cannot tell you the model
    # is right. The independent check that can is `check_tilt_against_pinhole`
    # below, which starts from world geometry instead.
    #
    # Re-project this very track through a camera pitched up at the contact
    # point (the mistake a short tripod invites), then rectify it back. The
    # uncorrected numbers are printed too, because the size of the error is the
    # argument for bothering: tilt costs far more exit velocity than launch
    # angle, which is the opposite of what "the camera is aimed up so the angle
    # will be wrong" intuition suggests.
    fov_deg = 60.0
    focal = sla.focal_px_from_fov(W, fov_deg)
    ccx, ccy = W / 2.0, H / 2.0
    for tilt in (-8.0, -16.0):
        t = math.radians(tilt)
        tilted = []
        for o in track:
            u, v = o.x - ccx, o.y - ccy
            d = focal * math.cos(t) + v * math.sin(t)
            mag = focal / d
            tilted.append(sla.BallObservation(
                o.frame, o.t, ccx + u * mag,
                ccy + (v * math.cos(t) - focal * math.sin(t)) * mag,
                o.diameter_px * mag, o.area_px))
        m_raw = sla.analyze_track(tilted, contact_time=CONTACT_FRAME / FPS)
        m_fix = sla.analyze_track(
            sla.rectify_tilt(tilted, tilt, focal, ccx, ccy),
            contact_time=CONTACT_FRAME / FPS)
        print(f"    tilt {tilt:+.0f} deg  uncorrected LA {m_raw.launch_angle_deg:.2f} "
              f"EV {m_raw.exit_velo_mph:.2f}  ->  corrected LA {m_fix.launch_angle_deg:.2f} "
              f"EV {m_fix.exit_velo_mph:.2f}")
        check(f"tilt {tilt:+.0f} deg rectified",
              abs(m_fix.launch_angle_deg - m.launch_angle_deg) <= 0.05
              and abs(m_fix.exit_velo_mph / m.exit_velo_mph - 1) <= 0.005,
              f"LA err {m_fix.launch_angle_deg - m.launch_angle_deg:+.3f} deg, "
              f"EV err {(m_fix.exit_velo_mph / m.exit_velo_mph - 1) * 100:+.2f}%")

    # flight model sanity: 65 mph @ 25 deg carries roughly 130-190 ft in air
    carry_m, hang_s, _apex = sla.simulate_flight(TRUE_EV_MPH / sla.MPH_PER_MPS, TRUE_LA_DEG)
    check_tilt_against_pinhole(check)

    check("drag flight model sanity", 36 <= carry_m <= 61 and 1.5 <= hang_s <= 4.0,
          f"carry {carry_m:.1f} m, hang {hang_s:.2f} s")

    print()
    if all(checks):
        print("ALL PASS — install and measurement pipeline are working.")
        sys.exit(0)
    print("SOME CHECKS FAILED — see above.")
    sys.exit(1)


if __name__ == "__main__":
    main()
