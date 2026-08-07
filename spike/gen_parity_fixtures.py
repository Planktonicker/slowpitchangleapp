#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
gen_parity_fixtures.py — freeze the reference math into golden vectors.

sla_common.py is the single source of truth for tracking and physics; the Swift
port must reproduce it number-for-number. This script evaluates the reference
implementation on a fixed set of inputs and writes the results to

    app/Tests/Fixtures/parity.json

which SwingLabTests/ParityTests.swift reads and asserts against. Re-run it
whenever sla_common.py changes, and re-run the Swift tests:

    python gen_parity_fixtures.py

Everything here is deterministic — no RNG, no video, no cv2 detection. The
fixtures cover the parts a port can silently get wrong:

  * solve_gravity_scale   — the drag-aware quadratic, including the two-root
                            rising-ball branch where root selection matters
  * fit_quadratic         — least-squares coefficients and residual
  * analyze_track         — full SwingMetrics incl. every confidence flag
  * simulate_flight       — the drag integrator used for the G3 cross-check
"""

from __future__ import annotations

import json
import math
import os

import numpy as np

import sla_common as sla

FPS = 240.0


# ---------------------------------------------------------------------------
# Deterministic track synthesis (drag model -> pixel observations)
# ---------------------------------------------------------------------------

def drag_positions(ev_mph: float, la_deg: float, px_per_m: float,
                   n_frames: int, fps: float, x0: float, y0: float):
    """Integrate the same drag model synth_test.py renders, sample per frame.

    Returns pixel positions with y down-positive, matching image convention.
    """
    ev = ev_mph / sla.MPH_PER_MPS
    la = math.radians(la_deg)
    k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD * math.pi
                * (sla.BALL_DIAMETER_M / 2) ** 2 / sla.BALL_MASS_KG)
    vx, vy = ev * math.cos(la), ev * math.sin(la)      # m/s, y up-positive
    x_m, y_m = 0.0, 0.0
    dt = 1.0 / (fps * 10.0)
    pts = []
    for _ in range(n_frames):
        pts.append((x0 + x_m * px_per_m, y0 - y_m * px_per_m))
        for _ in range(10):
            v = math.hypot(vx, vy)
            vx += -k_over_m * v * vx * dt
            vy += (-sla.G - k_over_m * v * vy) * dt
            x_m += vx * dt
            y_m += vy * dt
    return pts


def make_track(ev_mph, la_deg, px_per_m, n_frames, fps=FPS,
               x0=150.0, y0=900.0, diameter_px=None, diameter_growth=0.0,
               wobble_px=0.0, start_frame=0):
    """Build a list of BallObservation from the drag model.

    diameter_growth: fractional change in apparent diameter across the track
                     (simulates depth motion -> FLAG_DEPTH_MOTION).
    wobble_px:       deterministic sinusoidal position perturbation
                     (simulates detector jitter -> FLAG_HIGH_RESIDUAL).
    """
    d0 = diameter_px if diameter_px is not None else sla.BALL_DIAMETER_M * px_per_m
    pts = drag_positions(ev_mph, la_deg, px_per_m, n_frames, fps, x0, y0)
    track = []
    for i, (x, y) in enumerate(pts):
        frac = i / max(1, n_frames - 1)
        if wobble_px:
            x += wobble_px * math.sin(i * 1.7)
            y += wobble_px * math.cos(i * 2.3)
        d = d0 * (1.0 + diameter_growth * frac)
        track.append(sla.BallObservation(
            frame=start_frame + i,
            t=(start_frame + i) / fps,
            x=x, y=y,
            diameter_px=d,
            area_px=math.pi * (d / 2) ** 2,
        ))
    return track


def track_to_json(track):
    return [{"frame": o.frame, "t": o.t, "x": o.x, "y": o.y,
             "diameter_px": o.diameter_px, "area_px": o.area_px} for o in track]


def metrics_to_json(m: sla.SwingMetrics):
    return {
        "launch_angle_deg": m.launch_angle_deg,
        "exit_velo_mph": m.exit_velo_mph,
        "exit_velo_mps": m.exit_velo_mps,
        "scale_ball_m_per_px": m.scale_ball_m_per_px,
        "scale_gravity_m_per_px": m.scale_gravity_m_per_px,
        "scale_disagreement": m.scale_disagreement,
        "diameter_drift": m.diameter_drift,
        "n_frames": m.n_frames,
        "track_duration_s": m.track_duration_s,
        "fit_rms_px": m.fit_rms_px,
        "t0": m.t0,
        "vx_px_s": m.vx_px_s,
        "vy_px_s": m.vy_px_s,
        "x0_px": m.x0_px,
        "y0_px": m.y0_px,
        "flags": m.flags,
    }


# ---------------------------------------------------------------------------
# Case tables
# ---------------------------------------------------------------------------

def analyze_cases():
    """(name, track, contact_time, roll_deg) tuples exercising every flag."""
    cases = []

    # Clean line drive: long enough for the gravity check, no flags expected.
    cases.append(("clean_line_drive",
                  make_track(72.0, 18.0, 250.0, 80), None, 0.0))

    # Fly ball: steeper, more curvature, still clean.
    cases.append(("clean_fly_ball",
                  make_track(78.0, 32.0, 220.0, 96), None, 0.0))

    # Low exit velocity, high angle (pop-up).
    cases.append(("popup",
                  make_track(45.0, 55.0, 260.0, 90), None, 0.0))

    # Contact time earlier than the first tracked point: the fit must
    # extrapolate back to t0 (batter occlusion case).
    cases.append(("occluded_start_extrapolates",
                  make_track(70.0, 20.0, 250.0, 70, start_frame=12),
                  8 / FPS, 0.0))

    # Camera roll correction applied to the velocity vector.
    cases.append(("camera_roll_3deg",
                  make_track(70.0, 20.0, 250.0, 80), None, 3.0))
    cases.append(("camera_roll_negative",
                  make_track(70.0, 20.0, 250.0, 80), None, -2.5))

    # Hit toward the other side of the frame: LA must stay up-positive.
    left = make_track(70.0, 22.0, 250.0, 80, x0=1800.0)
    for o in left:
        o.x = 1950.0 - (o.x - 1800.0) - 150.0
    cases.append(("leftward_hit_angle_sign", left, None, 0.0))

    # FLAG_SHORT_TRACK + FLAG_NO_GRAVITY_CHECK (too few frames / too brief).
    cases.append(("short_track",
                  make_track(70.0, 20.0, 250.0, 6), None, 0.0))

    # FLAG_NO_GRAVITY_CHECK alone: enough frames, under MIN_GRAVITY_TRACK_S.
    cases.append(("no_gravity_check",
                  make_track(70.0, 20.0, 250.0, 40), None, 0.0))

    # FLAG_SCALE_DISAGREE: diameter deliberately 20% wrong.
    cases.append(("scale_disagree",
                  make_track(72.0, 18.0, 250.0, 80,
                             diameter_px=sla.BALL_DIAMETER_M * 250.0 * 1.20),
                  None, 0.0))

    # FLAG_DEPTH_MOTION: ball growing in frame (moving toward the camera).
    cases.append(("depth_motion",
                  make_track(72.0, 18.0, 250.0, 80, diameter_growth=0.18),
                  None, 0.0))

    # FLAG_HIGH_RESIDUAL: noisy detections.
    cases.append(("high_residual",
                  make_track(72.0, 18.0, 250.0, 80, wobble_px=6.0), None, 0.0))

    return cases


def gravity_scale_cases():
    """Inputs chosen to hit every branch of solve_gravity_scale."""
    # The rising cases below are a real 70 mph / 20 deg ball at 250 px/m:
    # vx_px = 7350, vy_px = -2675, and the drag-inflated ay_px = 3390 that
    # such a ball actually shows. Both quadratic roots are positive there
    # (~0.0040 and ~0.0105 m/px), so root selection is what the fixture pins.
    return [
        # Hint near the physical root: must return ~0.004, NOT the larger root.
        {"name": "rising_two_roots", "ay_px": 3390.0,
         "vx_px_mid": 7350.0, "vy_px_mid": -2675.0, "scale_hint": 0.004},
        # Same inputs, no hint: the implementation falls back to min(roots).
        {"name": "rising_no_hint", "ay_px": 3390.0,
         "vx_px_mid": 7350.0, "vy_px_mid": -2675.0, "scale_hint": None},
        # Hint near the LARGER root: proves selection is nearest-to-hint and
        # not simply "always the smaller one" — a port that hardcodes min()
        # passes the two cases above and fails this one.
        {"name": "rising_hint_picks_larger_root", "ay_px": 3390.0,
         "vx_px_mid": 7350.0, "vy_px_mid": -2675.0, "scale_hint": 0.0104},
        # Descending ball (vy_px > 0): drag opposes gravity in the vertical.
        {"name": "descending", "ay_px": 1800.0,
         "vx_px_mid": 3000.0, "vy_px_mid": 900.0, "scale_hint": 0.004},
        # Near apex: vy ~ 0, A ~ 0, falls back to the naive G/ay branch.
        {"name": "near_apex_naive", "ay_px": 2450.0,
         "vx_px_mid": 3500.0, "vy_px_mid": 0.0, "scale_hint": 0.004},
        # Slow, shallow: drag term small but nonzero.
        {"name": "slow_shallow", "ay_px": 2000.0,
         "vx_px_mid": 900.0, "vy_px_mid": -200.0, "scale_hint": 0.004},
        # Non-physical vertical acceleration: must return nil, not a number.
        {"name": "zero_accel_returns_nil", "ay_px": 0.0,
         "vx_px_mid": 3000.0, "vy_px_mid": -1000.0, "scale_hint": 0.004},
        {"name": "negative_accel_returns_nil", "ay_px": -500.0,
         "vx_px_mid": 3000.0, "vy_px_mid": -1000.0, "scale_hint": 0.004},
        # Strong rising drag: discriminant can go negative -> nil.
        {"name": "steep_rise_large_speed", "ay_px": 120.0,
         "vx_px_mid": 9000.0, "vy_px_mid": -6000.0, "scale_hint": 0.004},
    ]


def fit_cases():
    return [
        {"name": "exact_quadratic",
         "ts": [0.0, 0.1, 0.2, 0.3, 0.4],
         "vs": [1.0, 1.21, 1.44, 1.69, 1.96]},
        {"name": "pixel_trajectory",
         "ts": [i / FPS for i in range(12)],
         "vs": [900.0 - 1500.0 * (i / FPS) + 0.5 * 2450.0 * (i / FPS) ** 2
                for i in range(12)]},
        {"name": "with_residual",
         "ts": [0.0, 0.05, 0.10, 0.15, 0.20, 0.25],
         "vs": [10.0, 12.5, 14.0, 17.5, 19.0, 23.0]},
        {"name": "descending_line",
         "ts": [0.0, 0.25, 0.5, 0.75, 1.0],
         "vs": [5.0, 4.0, 3.0, 2.0, 1.0]},
    ]


def bat_cases():
    """Inputs for bat_speed_mps / smash_factor / smash_quality, covering the
    poor/fair/flush bands and the bat-not-tracked (None) path."""
    return [
        # ~65 mph barrel at contact (7000 px/s downward-ish at 240 px/m), a
        # solid slow-pitch swing; EV 78 mph -> smash ~1.20 (fair/flush edge).
        {"name": "solid_swing", "vx_px_s": 6800.0, "vy_px_s": -1600.0,
         "scale_m_per_px": 1.0 / 240.0, "exit_velo_mps": 78.0 / sla.MPH_PER_MPS},
        # Flush: high EV relative to bat speed.
        {"name": "flush_contact", "vx_px_s": 5000.0, "vy_px_s": -500.0,
         "scale_m_per_px": 1.0 / 250.0, "exit_velo_mps": 34.0},
        # Poor: mishit, EV well below bat speed.
        {"name": "poor_contact", "vx_px_s": 7000.0, "vy_px_s": -1000.0,
         "scale_m_per_px": 1.0 / 240.0, "exit_velo_mps": 20.0},
        # Bat not tracked: zero speed -> smash None -> quality "unknown".
        {"name": "bat_not_tracked", "vx_px_s": 0.0, "vy_px_s": 0.0,
         "scale_m_per_px": 1.0 / 240.0, "exit_velo_mps": 30.0},
    ]


def contact_offset_cases():
    """(ball_y0_px, bat_y0_px, scale) hitting every contact_quality band.

    At scale 1/240 m/px, 1 px ~ 4.17 mm. Bands: topped < -6 mm,
    centred <= +10 mm, carry <= +30 mm, popup beyond, implausible > ~77 mm.
    """
    s = 1.0 / 240.0
    return [
        # Barrel 4 px (~16.7 mm) below ball centre: carry zone.
        {"name": "under_carry", "ball_y0_px": 500.0, "bat_y0_px": 504.0,
         "scale_m_per_px": s},
        # Dead centre.
        {"name": "centered_flush", "ball_y0_px": 500.0, "bat_y0_px": 500.5,
         "scale_m_per_px": s},
        # Barrel 3 px (~12.5 mm) ABOVE the ball: topped.
        {"name": "topped", "ball_y0_px": 500.0, "bat_y0_px": 497.0,
         "scale_m_per_px": s},
        # Barrel 9 px (~37.5 mm) below: under it, popup territory.
        {"name": "under_popup", "ball_y0_px": 500.0, "bat_y0_px": 509.0,
         "scale_m_per_px": s},
        # 25 px (~104 mm) apart: centres could not have touched.
        {"name": "implausible_gap", "ball_y0_px": 500.0, "bat_y0_px": 525.0,
         "scale_m_per_px": s},
        # Exactly on the topped boundary (-6 mm): stays topped-side check.
        {"name": "boundary_neg6mm", "ball_y0_px": 500.0,
         "bat_y0_px": 500.0 - 0.006 / s, "scale_m_per_px": s},
    ]


def tilt_rectify_cases():
    """Camera-tilt homography cases.

    1920x1080 at a 60 deg horizontal FOV, so f = 1662.77 px and the principal
    point is (960, 540). Covers: no tilt (identity), aimed up, aimed down, a
    point on the optical axis (where only v moves), a point near the frame
    corner (largest magnification swing), and a tilt past
    TILT_CORRECTABLE_MAX_DEG so the port cannot quietly clamp.
    """
    f = sla.focal_px_from_fov(1920.0, 60.0)
    cx, cy = 960.0, 540.0
    pts = [
        ("axis", 960.0, 540.0, 40.0),
        ("upper_left", 300.0, 180.0, 36.0),
        ("lower_right", 1700.0, 900.0, 44.0),
    ]
    cases = []
    for tilt in (0.0, 6.0, -6.0, 12.0, -12.0, 25.0):
        for name, x, y, d in pts:
            cases.append({"name": f"{name}_tilt{tilt:+.0f}".replace("+", "p").replace("-", "m"),
                          "x": x, "y": y, "diameter_px": d,
                          "tilt_deg": tilt, "focal_px": f, "cx": cx, "cy": cy})
    # Unusable optics: no FOV, so no rectification is possible at all.
    cases.append({"name": "no_focal", "x": 300.0, "y": 180.0, "diameter_px": 36.0,
                  "tilt_deg": 12.0, "focal_px": 0.0, "cx": cx, "cy": cy})
    return cases


def focal_cases():
    return [
        {"name": "hd_60deg", "width_px": 1920.0, "fov_deg": 60.0},
        {"name": "hd_73deg", "width_px": 1920.0, "fov_deg": 73.0},
        {"name": "vga_45deg", "width_px": 640.0, "fov_deg": 45.0},
        {"name": "zero_fov", "width_px": 1920.0, "fov_deg": 0.0},
        {"name": "zero_width", "width_px": 0.0, "fov_deg": 60.0},
    ]


def _json_number(v):
    """NaN is not JSON. It is also a real, meaningful result here — a degenerate
    joint must produce NaN and not a plausible angle — so it is encoded as null
    and the Swift test asserts NaN for a null expectation. Writing a bare NaN
    would produce a file Foundation's JSONDecoder refuses outright, taking every
    other parity assertion down with it."""
    return None if v != v else v


def body_cases():
    """Sagittal-plane body geometry, covering every branch.

    Points are image pixels (y down) at 240 px/m — the scale the ball pipeline
    produces at the protocol distance. The degenerate cases matter as much as
    the ordinary ones: a pose model that loses a joint hands back two coincident
    points, and the port must return NaN there rather than a plausible angle.
    """
    s = 1.0 / 240.0
    return {
        "angles": [
            # Straight leg: hip, knee, ankle collinear -> 180.
            {"name": "straight_leg", "ax": 500.0, "ay": 400.0,
             "bx": 500.0, "by": 550.0, "cx": 500.0, "cy": 700.0},
            {"name": "right_angle", "ax": 400.0, "ay": 550.0,
             "bx": 500.0, "by": 550.0, "cx": 500.0, "cy": 650.0},
            # Typical flexed front knee at contact.
            {"name": "flexed_knee", "ax": 470.0, "ay": 410.0,
             "bx": 500.0, "by": 550.0, "cx": 560.0, "cy": 690.0},
            # Degenerate: knee and ankle on the same pixel -> NaN.
            {"name": "coincident", "ax": 470.0, "ay": 410.0,
             "bx": 500.0, "by": 550.0, "cx": 500.0, "cy": 550.0},
        ],
        "tilts": [
            {"name": "upright", "hip_x": 500.0, "hip_y": 500.0,
             "shoulder_x": 500.0, "shoulder_y": 350.0},
            {"name": "leaning_forward", "hip_x": 500.0, "hip_y": 500.0,
             "shoulder_x": 560.0, "shoulder_y": 350.0},
            {"name": "leaning_back", "hip_x": 500.0, "hip_y": 500.0,
             "shoulder_x": 440.0, "shoulder_y": 350.0},
            {"name": "degenerate", "hip_x": 500.0, "hip_y": 500.0,
             "shoulder_x": 500.0, "shoulder_y": 500.0},
        ],
        "distances": [
            {"name": "head_still", "x0": 500.0, "y0": 300.0,
             "x1": 506.0, "y1": 303.0, "scale_m_per_px": s},
            {"name": "head_lunge", "x0": 500.0, "y0": 300.0,
             "x1": 560.0, "y1": 320.0, "scale_m_per_px": s},
            {"name": "no_movement", "x0": 500.0, "y0": 300.0,
             "x1": 500.0, "y1": 300.0, "scale_m_per_px": s},
        ],
        "strides": [
            {"name": "normal_stride", "load_x": 520.0, "contact_x": 400.0,
             "scale_m_per_px": s},
            {"name": "no_stride", "load_x": 520.0, "contact_x": 520.0,
             "scale_m_per_px": s},
            # Mirrored hitter: the foot travels the other way, same length.
            {"name": "mirrored_stride", "load_x": 400.0, "contact_x": 520.0,
             "scale_m_per_px": s},
        ],
        # Head-drift plausibility gate, both sides of the limit and the
        # no-reading case.
        "drift_gate": [None, 0.0, 0.05, 0.39, 0.40, 0.41, 1.2],
    }


def flight_cases():
    return [
        {"name": "synth_test_reference", "ev_mps": 65.0 / sla.MPH_PER_MPS,
         "la_deg": 25.0, "contact_height_m": 0.9},
        {"name": "line_drive", "ev_mps": 32.0, "la_deg": 12.0,
         "contact_height_m": 0.9},
        {"name": "high_fly", "ev_mps": 34.0, "la_deg": 40.0,
         "contact_height_m": 0.95},
        {"name": "popup", "ev_mps": 22.0, "la_deg": 65.0,
         "contact_height_m": 0.9},
        {"name": "ground_ball", "ev_mps": 30.0, "la_deg": -5.0,
         "contact_height_m": 0.9},
        {"name": "tee_height", "ev_mps": 28.0, "la_deg": 20.0,
         "contact_height_m": 0.6},
    ]


# ---------------------------------------------------------------------------

def main():
    out = {
        "_generated_by": "spike/gen_parity_fixtures.py",
        "_source_of_truth": "spike/sla_common.py",
        "_copyright": "Copyright (C) 2026 Planktonicker",
        "_license": "AGPL-3.0-only",
        "constants": {
            "G": sla.G,
            "BALL_CIRCUMFERENCE_M": sla.BALL_CIRCUMFERENCE_M,
            "BALL_DIAMETER_M": sla.BALL_DIAMETER_M,
            "BALL_MASS_KG": sla.BALL_MASS_KG,
            "AIR_DENSITY": sla.AIR_DENSITY,
            "DRAG_CD": sla.DRAG_CD,
            "MPH_PER_MPS": sla.MPH_PER_MPS,
            "VELOCITY_WINDOW_S": sla.VELOCITY_WINDOW_S,
            "GRAVITY_WINDOW_S": sla.GRAVITY_WINDOW_S,
            "MIN_TRACK_FRAMES": sla.MIN_TRACK_FRAMES,
            "MIN_GRAVITY_TRACK_S": sla.MIN_GRAVITY_TRACK_S,
            "SCALE_DISAGREE_TOL": sla.SCALE_DISAGREE_TOL,
            "DIAMETER_DRIFT_TOL": sla.DIAMETER_DRIFT_TOL,
            "RESIDUAL_TOL_PX": sla.RESIDUAL_TOL_PX,
            "DIAMETER_PROFILE_STEP_PX": sla.DIAMETER_PROFILE_STEP_PX,
            "k_over_m": (0.5 * sla.AIR_DENSITY * sla.DRAG_CD * math.pi
                         * (sla.BALL_DIAMETER_M / 2) ** 2 / sla.BALL_MASS_KG),
            "SMASH_POOR_BELOW": sla.SMASH_POOR_BELOW,
            "SMASH_GOOD_LO": sla.SMASH_GOOD_LO,
            "SMASH_GOOD_HI": sla.SMASH_GOOD_HI,
            "SLOWPITCH_LAUNCH_LO": sla.SLOWPITCH_LAUNCH_LO,
            "SLOWPITCH_LAUNCH_HI": sla.SLOWPITCH_LAUNCH_HI,
            # Detector defaults. These are mirrored by hand into
            # SLAConstants.swift; pinning them here is what turns that mirror
            # from a convention into a test.
            "HSV_LO_H": float(sla.HSV_LO_DEFAULT[0]),
            "HSV_LO_S": float(sla.HSV_LO_DEFAULT[1]),
            "HSV_LO_V": float(sla.HSV_LO_DEFAULT[2]),
            "HSV_HI_H": float(sla.HSV_HI_DEFAULT[0]),
            "HSV_HI_S": float(sla.HSV_HI_DEFAULT[1]),
            "HSV_HI_V": float(sla.HSV_HI_DEFAULT[2]),
            "MIN_RADIUS_PX_DEFAULT": sla.MIN_RADIUS_PX_DEFAULT,
            "MAX_RADIUS_PX_DEFAULT": sla.MAX_RADIUS_PX_DEFAULT,
            "BAT_BARREL_DIAMETER_M": sla.BAT_BARREL_DIAMETER_M,
            "CONTACT_PLAUSIBLE_M": sla.CONTACT_PLAUSIBLE_M,
            "UNDERCUT_TOPPED_BELOW_M": sla.UNDERCUT_TOPPED_BELOW_M,
            "UNDERCUT_CENTERED_MAX_M": sla.UNDERCUT_CENTERED_MAX_M,
            "UNDERCUT_CARRY_MAX_M": sla.UNDERCUT_CARRY_MAX_M,
            "TILT_CORRECTABLE_MAX_DEG": sla.TILT_CORRECTABLE_MAX_DEG,
            "JOINT_CONFIDENCE_MIN": sla.JOINT_CONFIDENCE_MIN,
            "HEAD_DRIFT_IMPLAUSIBLE_M": sla.HEAD_DRIFT_IMPLAUSIBLE_M,
        },
        "fit_quadratic": [],
        "solve_gravity_scale": [],
        "analyze_track": [],
        "simulate_flight": [],
        "vy0_from_hang_time": [],
        "bat_metrics": [],
        "contact_offset": [],
        "focal_px_from_fov": [],
        "rectify_tilt": [],
        "body_angles": [],
        "body_tilts": [],
        "body_distances": [],
        "body_strides": [],
        "body_drift_gate": [],
    }

    for c in fit_cases():
        coeffs, rms = sla.fit_quadratic(np.array(c["ts"]), np.array(c["vs"]))
        out["fit_quadratic"].append({
            "name": c["name"], "ts": c["ts"], "vs": c["vs"],
            "a": float(coeffs[0]), "b": float(coeffs[1]), "c": float(coeffs[2]),
            "rms": rms,
        })

    for c in gravity_scale_cases():
        out["solve_gravity_scale"].append({
            **c,
            "expected": sla.solve_gravity_scale(
                c["ay_px"], c["vx_px_mid"], c["vy_px_mid"], c["scale_hint"]),
        })

    for name, track, contact_time, roll in analyze_cases():
        m = sla.analyze_track(track, contact_time=contact_time, roll_deg=roll)
        out["analyze_track"].append({
            "name": name,
            "contact_time": contact_time,
            "roll_deg": roll,
            "track": track_to_json(track),
            "expected": metrics_to_json(m),
        })

    for c in flight_cases():
        carry, hang, apex = sla.simulate_flight(
            c["ev_mps"], c["la_deg"], c["contact_height_m"])
        out["simulate_flight"].append({
            **c, "carry_m": carry, "hang_s": hang, "apex_m": apex})

    for hang in (1.5, 2.33, 3.0, 4.1):
        out["vy0_from_hang_time"].append(
            {"hang_s": hang, "expected": sla.vy0_from_hang_time(hang)})

    for c in bat_cases():
        bs = sla.bat_speed_mps(c["vx_px_s"], c["vy_px_s"], c["scale_m_per_px"])
        smash = sla.smash_factor(c["exit_velo_mps"], bs)
        out["bat_metrics"].append({
            **c,
            "bat_speed_mps": bs,
            "bat_speed_mph": bs * sla.MPH_PER_MPS,
            "smash_factor": smash,
            "smash_quality": sla.smash_quality(smash),
        })

    for c in contact_offset_cases():
        u = sla.undercut_m(c["ball_y0_px"], c["bat_y0_px"], c["scale_m_per_px"])
        out["contact_offset"].append({
            **c,
            "undercut_m": u,
            "undercut_mm": u * 1000,
            "quality": sla.contact_quality(u),
        })

    for c in focal_cases():
        out["focal_px_from_fov"].append({
            **c, "expected": sla.focal_px_from_fov(c["width_px"], c["fov_deg"]),
        })

    for c in tilt_rectify_cases():
        x, y, mag = sla.rectify_tilt_point(
            c["x"], c["y"], c["tilt_deg"], c["focal_px"], c["cx"], c["cy"])
        out["rectify_tilt"].append({
            **c,
            "expected_x": x,
            "expected_y": y,
            "expected_magnification": mag,
            "expected_diameter_px": c["diameter_px"] * mag,
        })

    body = body_cases()
    for c in body["angles"]:
        out["body_angles"].append({
            **c, "expected": _json_number(sla.sagittal_angle_deg(
                c["ax"], c["ay"], c["bx"], c["by"], c["cx"], c["cy"])),
        })
    for c in body["tilts"]:
        out["body_tilts"].append({
            **c, "expected": _json_number(sla.spine_tilt_deg(
                c["hip_x"], c["hip_y"], c["shoulder_x"], c["shoulder_y"])),
        })
    for c in body["distances"]:
        out["body_distances"].append({
            **c, "expected": sla.planar_distance_m(
                c["x0"], c["y0"], c["x1"], c["y1"], c["scale_m_per_px"]),
        })
    for c in body["strides"]:
        out["body_strides"].append({
            **c, "expected": sla.stride_length_m(
                c["load_x"], c["contact_x"], c["scale_m_per_px"]),
        })
    for d in body["drift_gate"]:
        out["body_drift_gate"].append({
            "drift_m": d, "expected": sla.head_drift_plausible(d),
        })

    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "app", "Tests", "Fixtures", "parity.json")
    dst = os.path.normpath(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        json.dump(out, f, indent=1, sort_keys=False, allow_nan=False)
        f.write("\n")

    n_obs = sum(len(c["track"]) for c in out["analyze_track"])
    print(f"wrote {dst}")
    print(f"  {len(out['fit_quadratic'])} fit cases, "
          f"{len(out['solve_gravity_scale'])} gravity-scale cases, "
          f"{len(out['analyze_track'])} analyze cases ({n_obs} observations), "
          f"{len(out['simulate_flight'])} flight cases, "
          f"{len(out['bat_metrics'])} bat cases, "
          f"{len(out['contact_offset'])} contact-offset cases, "
          f"{len(out['rectify_tilt'])} tilt-rectify cases, "
          f"{len(out['body_angles']) + len(out['body_tilts']) + len(out['body_distances']) + len(out['body_strides'])} body cases")


if __name__ == "__main__":
    main()
