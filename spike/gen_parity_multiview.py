#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
gen_parity_multiview.py — freeze sla_multiview's answers for the Swift port.

The sibling of gen_parity_fixtures.py, for the second reference module. Same
law, same habits: deterministic inputs only (no RNG, no video, no cv2), NaN
encoded as JSON null because Foundation's JSONDecoder refuses bare NaN, and
every case named for the failure it exists to prevent.

Writes app/TestsPro/Fixtures/parity_multiview.json, which
app/TestsPro/ParityMultiviewTests.swift decodes. It deliberately does NOT
touch app/Tests/Fixtures/parity.json: that file is decoded by a non-optional
struct in the SHIPPING test target, so adding 3D sections there would drag
the 3D port into the shipping app.

  cd spike && python gen_parity_multiview.py
"""

from __future__ import annotations

import json
import math
import os

import numpy as np

import sla_common as sla
import sla_multiview as mv

OUT = os.path.join(os.path.dirname(__file__), "..", "app", "TestsPro",
                   "Fixtures", "parity_multiview.json")


def num(v):
    """NaN -> None. One bare NaN in the file takes every other assertion
    down with it, because the decode fails before a single case is read."""
    if v is None:
        return None
    v = float(v)
    return None if v != v else v


def nums(seq):
    return [num(v) for v in seq]


# --- clock ------------------------------------------------------------------

def clock_cases():
    cases = []

    def exchange(t_send, d1, proc, d2, offset, skew):
        worker = lambda t: (1.0 + skew) * t + offset          # noqa: E731
        t1 = t_send
        t2 = worker(t_send + d1)
        t3 = worker(t_send + d1 + proc)
        t4 = t_send + d1 + proc + d2
        return t1, t2, t3, t4

    # Clean, symmetric: offset must come back exactly.
    c = [exchange(0.1 * i, 0.002, 0.0003, 0.002, 0.1375, 0.0) for i in range(12)]
    cases.append({"name": "symmetric_delays_recover_offset", "samples": c})

    # Skewed clock over a long window: a port that ignores skew passes the
    # case above and fails this one.
    c = [exchange(0.5 * i, 0.002, 0.0003, 0.002, 0.1375, 20e-6) for i in range(20)]
    cases.append({"name": "skew_must_be_fitted_not_ignored", "samples": c})

    # A heavy tail. Every third exchange is delayed 80 ms one way. The
    # min-RTT filter must discard them; an averaging port reads badly wrong.
    c = []
    for i in range(24):
        slow = 0.080 if i % 3 == 0 else 0.0
        c.append(exchange(0.2 * i, 0.002 + slow, 0.0003, 0.002, 0.1375, 0.0))
    cases.append({"name": "delayed_pings_are_discarded_not_averaged", "samples": c})

    # Asymmetric path: NTP's known blind spot. Recorded so the port matches
    # the reference's (biased) answer rather than inventing a better one.
    c = [exchange(0.1 * i, 0.006, 0.0003, 0.001, 0.1375, 0.0) for i in range(10)]
    cases.append({"name": "asymmetric_path_biases_offset_by_half_the_gap", "samples": c})

    out = []
    for case in cases:
        samples = [{"t1": num(a), "t2": num(b), "t3": num(cc), "t4": num(d)}
                   for (a, b, cc, d) in case["samples"]]
        m = mv.fit_clock_model([s["t1"] for s in samples], [s["t2"] for s in samples],
                               [s["t3"] for s in samples], [s["t4"] for s in samples])
        probe = [0.0, 5.0, 12.0]
        out.append({
            "name": case["name"],
            "samples": samples,
            "expected": {
                "offset_s": num(m.offset_s), "skew": num(m.skew),
                "t_ref_s": num(m.t_ref_s), "rtt_min_s": num(m.rtt_min_s),
                "n_used": m.n_used, "ci_s": num(m.ci_s),
                "probe_t": nums(probe),
                "probe_mapped": nums([mv.map_clock_s(t, m) for t in probe]),
            },
        })
    return out


# --- resampling -------------------------------------------------------------

def resample_cases():
    cases = []

    ts = [i / 240.0 for i in range(24)]
    vs = [math.sin(2 * math.pi * t) for t in ts]
    grid = [t + 0.0021 for t in ts[:-1]]
    cases.append({"name": "smooth_curve_offgrid", "ts": ts, "vs": vs, "grid": grid})

    # Monotone data must stay monotone: a plain cubic spline overshoots here,
    # and an overshoot through contact is an invented bat speed.
    mono = [1.0 / (1.0 + math.exp(-(t - 0.05) / 0.01)) for t in ts]
    cases.append({"name": "monotone_stays_monotone_no_overshoot",
                  "ts": ts, "vs": mono, "grid": grid})

    # A dropout wider than the gap tolerance: the middle must be NaN, not
    # bridged. This is the absent-not-guessed rule in the resampler.
    gappy_t = [0.0, 0.004, 0.008, 0.012, 0.20, 0.204, 0.208]
    gappy_v = [0.0, 1.0, 2.0, 3.0, 10.0, 11.0, 12.0]
    cases.append({"name": "wide_gap_is_absent_not_bridged",
                  "ts": gappy_t, "vs": gappy_v,
                  "grid": [0.006, 0.05, 0.10, 0.15, 0.202]})

    # Outside the sample span at both ends.
    cases.append({"name": "outside_span_is_nan",
                  "ts": [0.0, 0.01, 0.02], "vs": [1.0, 2.0, 3.0],
                  "grid": [-0.005, 0.0, 0.015, 0.02, 0.03]})

    # Unsorted input with a duplicate timestamp — two samples at one instant
    # would be an infinite slope.
    cases.append({"name": "unsorted_with_duplicate_stamp",
                  "ts": [0.02, 0.0, 0.01, 0.01], "vs": [3.0, 1.0, 2.0, 9.0],
                  "grid": [0.005, 0.015]})

    for c in cases:
        c["expected"] = nums(mv.pchip_resample(c["ts"], c["vs"], c["grid"]))
    return cases


# --- camera + triangulation -------------------------------------------------

RIG = [
    ("side_on_and_90", 0.0, 90.0),
    ("side_on_and_60", 0.0, 60.0),
    ("narrow_30_ill_conditioned", 0.0, 30.0),
]


def cam(az_deg, dist=6.0, height=1.1, target=(0.0, 0.0, 1.0)):
    a = math.radians(az_deg)
    t = np.array(target, dtype=float)
    pos = np.array([t[0] + dist * math.sin(a), t[1] - dist * math.cos(a), height])
    intr = mv.CameraIntrinsics.from_fov(1920, 1080, 60.0)
    extr = mv.look_at_extrinsics(pos, t)
    return intr, extr


def camera_cases():
    out = []
    intr, extr = cam(0.0)
    p = mv.projection_matrix(intr, extr)
    pts = [(0.0, 0.0, 1.0), (0.5, 0.3, 1.4), (-0.4, -0.2, 0.6), (0.0, 0.0, 2.2)]
    out.append({
        "name": "side_on_projection",
        "fov_deg": 60.0, "width": 1920, "height": 1080,
        "cam_pos": nums(-(extr.r.T @ extr.t)), "target": [0.0, 0.0, 1.0],
        "points": [list(map(float, q)) for q in pts],
        "expected_uv": [list(mv.project_point(p, q)) if mv.project_point(p, q) else None
                        for q in pts],
        "expected_r": [nums(row) for row in extr.r],
        "expected_t": nums(extr.t),
    })

    rows = []
    for y in (0.0, 270.0, 540.0, 1080.0, 1300.0, -20.0):
        rows.append({"y": y, "height": 1080.0, "readout_s": mv.T_READOUT_DEFAULT_S,
                     "expected": num(mv.rs_row_delay_s(y, 1080.0, mv.T_READOUT_DEFAULT_S))})
    return {"projection": out, "row_delay": rows}


def triangulation_cases():
    out = []
    truth = [(0.0, 0.0, 1.0), (0.35, -0.2, 1.45), (-0.5, 0.4, 0.8)]
    for name, az_a, sep in RIG:
        ia, ea = cam(az_a)
        ib, eb = cam(az_a - sep)
        pa, pb = mv.projection_matrix(ia, ea), mv.projection_matrix(ib, eb)
        for i, q in enumerate(truth):
            ua, va = mv.project_point(pa, q)
            ub, vb = mv.project_point(pb, q)
            got = mv.triangulate_point([(pa, ua, va, 1.0), (pb, ub, vb, 1.0)])
            out.append({
                "name": f"{name}_pt{i}", "separation_deg": sep,
                "az_a": az_a, "rays": [{"az": az_a, "u": num(ua), "v": num(va), "w": 1.0},
                                       {"az": az_a - sep, "u": num(ub), "v": num(vb), "w": 1.0}],
                "expected_xyz": nums(got[0]), "expected_reproj_px": num(got[1]),
                "truth_xyz": list(map(float, q)),
            })
    # A deliberately wrong correspondence: the two views look at different
    # points, so reprojection must blow up rather than return something
    # plausible. This is the guard two cameras have and one never did.
    ia, ea = cam(0.0)
    ib, eb = cam(-90.0)
    pa, pb = mv.projection_matrix(ia, ea), mv.projection_matrix(ib, eb)
    ua, va = mv.project_point(pa, (0.0, 0.0, 1.0))
    ub, vb = mv.project_point(pb, (0.6, 0.5, 1.6))
    got = mv.triangulate_point([(pa, ua, va, 1.0), (pb, ub, vb, 1.0)])
    out.append({"name": "mismatched_correspondence_blows_up_reprojection",
                "separation_deg": 90.0, "az_a": 0.0,
                "rays": [{"az": 0.0, "u": num(ua), "v": num(va), "w": 1.0},
                         {"az": -90.0, "u": num(ub), "v": num(vb), "w": 1.0}],
                "expected_xyz": nums(got[0]), "expected_reproj_px": num(got[1]),
                "truth_xyz": None})
    return out


# --- rotation metrics -------------------------------------------------------

def rotation_cases():
    out = []
    def seg(az_deg, half, z):
        a = math.radians(az_deg)
        c = np.array([0.0, 0.0, z])
        d = np.array([math.cos(a), math.sin(a), 0.0]) * half
        return (c + d), (c - d)

    for pelvis_az, thorax_az, name in [
        (30.0, -12.0, "pelvis_leads_thorax_42deg"),
        (0.0, 0.0, "square_is_zero"),
        (-40.0, -40.0, "both_turned_equally_is_still_zero"),
        (170.0, -170.0, "wraps_across_180"),
    ]:
        hl, hr = seg(pelvis_az, 0.17, 1.0)
        sl, sr = seg(thorax_az, 0.20, 1.45)
        out.append({
            "name": name,
            "hip_l": nums(hl), "hip_r": nums(hr),
            "sh_l": nums(sl), "sh_r": nums(sr),
            "expected_pelvis_az": num(mv.segment_azimuth_deg(hl, hr)),
            "expected_thorax_az": num(mv.segment_azimuth_deg(sl, sr)),
            "expected_separation": num(mv.hip_shoulder_separation_deg(hl, hr, sl, sr)),
        })

    # Near-vertical segment: azimuth of an upright line is noise wearing
    # units, and must come back absent rather than as a number.
    vl = np.array([0.0, 0.0, 1.2])
    vr = np.array([0.01, 0.0, 1.0])
    out.append({
        "name": "near_vertical_segment_has_no_azimuth",
        "hip_l": nums(vl), "hip_r": nums(vr),
        "sh_l": nums(np.array([0.2, 0.0, 1.45])), "sh_r": nums(np.array([-0.2, 0.0, 1.45])),
        "expected_pelvis_az": num(mv.segment_azimuth_deg(vl, vr)),
        "expected_thorax_az": num(mv.segment_azimuth_deg(
            np.array([0.2, 0.0, 1.45]), np.array([-0.2, 0.0, 1.45]))),
        "expected_separation": num(mv.hip_shoulder_separation_deg(
            vl, vr, np.array([0.2, 0.0, 1.45]), np.array([-0.2, 0.0, 1.45]))),
    })
    return out


# --- flight -----------------------------------------------------------------

def flight_track(ev_mph, la_deg, spray_deg, n, fps=240.0, tilt_deg=0.0):
    """A drag-integrated flight, optionally with the whole world rolled by
    `tilt_deg` — which is what a rig rotated bodily out of the world frame
    looks like, and what |g| alone cannot see."""
    ev = ev_mph / sla.MPH_PER_MPS
    la, sp = math.radians(la_deg), math.radians(spray_deg)
    v = np.array([ev * math.cos(la) * math.cos(sp),
                  ev * math.cos(la) * math.sin(sp), ev * math.sin(la)])
    k = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD * math.pi
         * (sla.BALL_DIAMETER_M / 2) ** 2 / sla.BALL_MASS_KG)
    p = np.array([0.0, 0.0, 0.9])
    dt = 1.0 / (fps * 10.0)
    ts, pts = [], []
    for i in range(n):
        ts.append(i / fps)
        pts.append(p.copy())
        for _ in range(10):
            a = np.array([0.0, 0.0, -sla.G]) - k * np.linalg.norm(v) * v
            v = v + a * dt
            p = p + v * dt
    if tilt_deg:
        c, s = math.cos(math.radians(tilt_deg)), math.sin(math.radians(tilt_deg))
        rot = np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])
        pts = [rot @ q for q in pts]
    return ts, pts


def flight_cases():
    out = []
    for name, ev, la, spray, n, tilt in [
        ("straight_65mph_25deg", 65.0, 25.0, 0.0, 60, 0.0),
        ("pulled_spray_minus8", 65.0, 25.0, -8.0, 60, 0.0),
        ("low_liner", 78.0, 8.0, 4.0, 60, 0.0),
        ("rig_rolled_5deg_magnitude_blind", 65.0, 25.0, 0.0, 90, 5.0),
        ("too_short_for_gravity", 65.0, 25.0, 0.0, 20, 0.0),
    ]:
        ts, pts = flight_track(ev, la, spray, n, tilt_deg=tilt)
        lm = mv.launch_metrics_3d(ts, np.array(pts), 0.0)
        out.append({
            "name": name,
            "t": nums(ts), "xyz": [nums(q) for q in pts], "contact_t": 0.0,
            "expected": {
                "ev_mph": num(lm.ev_mph) if lm else None,
                "la_deg": num(lm.la_deg) if lm else None,
                "spray_deg": num(lm.spray_deg) if lm else None,
                "n_samples": lm.n_samples if lm else None,
                "gravity_mag": num(mv.gravity_magnitude_3d(ts, np.array(pts))),
                "gravity_tilt_deg": num(mv.gravity_tilt_deg(ts, np.array(pts))),
            },
        })
    return out


# --- flags ------------------------------------------------------------------

def flag_cases():
    """Every Swing3DFlag needs a case that provokes it, or the Swift
    coverage test fails — the same rule testFixturesCoverEveryFlag enforces
    on the 2D side."""
    out = []
    ia, ea = cam(0.0)
    ib, eb = cam(-90.0)
    pa, pb = mv.projection_matrix(ia, ea), mv.projection_matrix(ib, eb)
    grid = [i / 240.0 for i in range(24)]
    truth = [np.array([0.0, 0.0, 1.0 + 0.01 * i]) for i in range(24)]
    ua = np.array([mv.project_point(pa, q)[0] for q in truth])
    va = np.array([mv.project_point(pa, q)[1] for q in truth])
    ub = np.array([mv.project_point(pb, q)[0] for q in truth])
    vb = np.array([mv.project_point(pb, q)[1] for q in truth])
    ones = np.ones(24)
    nan = np.full(24, np.nan)

    def emit(name, views, had_gap):
        tr = mv.triangulate_series(grid, views, had_gap=had_gap)
        out.append({
            "name": name, "grid": nums(grid), "had_gap": had_gap,
            "views": [{"az": az, "us": nums(u), "vs": nums(v), "ws": nums(w)}
                      for az, u, v, w in raw],
            "expected": {"coverage": num(tr.coverage), "flags": list(tr.flags),
                         "xyz": [nums(q) for q in tr.xyz]},
        })

    raw = [(0.0, ua, va, ones), (-90.0, ub, vb, ones)]
    emit("clean_two_views_no_flags",
         [mv.ViewTrack2D(pa, ua, va, ones), mv.ViewTrack2D(pb, ub, vb, ones)], False)

    raw = [(0.0, ua, va, ones), (-90.0, nan, nan, nan)]
    emit("one_view_only",
         [mv.ViewTrack2D(pa, ua, va, ones), mv.ViewTrack2D(pb, nan, nan, nan)], False)

    half = ub.copy(); half[10:] = np.nan
    halfv = vb.copy(); halfv[10:] = np.nan
    halfw = ones.copy(); halfw[10:] = np.nan
    raw = [(0.0, ua, va, ones), (-90.0, half, halfv, halfw)]
    emit("low_coverage_when_a_view_drops_out",
         [mv.ViewTrack2D(pa, ua, va, ones), mv.ViewTrack2D(pb, half, halfv, halfw)], False)

    # Perturb V, not U. At 90 degrees a horizontal shift in one view is
    # ABSORBABLE — the solver just slides the point along the other camera's
    # line of sight and the residual stays small, which is why the first
    # attempt at this case produced no flag at all. Both cameras sit at the
    # same height, so a VERTICAL disagreement is about world Z and neither
    # view can absorb it. That asymmetry is worth knowing: two cameras at a
    # shared height are far better at catching vertical miscorrespondence
    # than horizontal.
    bad_v = vb + 60.0
    raw = [(0.0, ua, va, ones), (-90.0, ub, bad_v, ones)]
    emit("high_reprojection_when_views_disagree",
         [mv.ViewTrack2D(pa, ua, va, ones), mv.ViewTrack2D(pb, ub, bad_v, ones)], False)

    raw = [(0.0, ua, va, ones), (-90.0, ub, vb, ones)]
    emit("resample_gap_is_reported", 
         [mv.ViewTrack2D(pa, ua, va, ones), mv.ViewTrack2D(pb, ub, vb, ones)], True)
    return out


def main():
    cams = camera_cases()
    doc = {
        "_generated_by": "spike/gen_parity_multiview.py",
        "_source_of_truth": "spike/sla_multiview.py",
        "_copyright": "SwingLab — Copyright (C) 2026 Planktonicker",
        "_license": "AGPL-3.0-only",
        "constants": {
            "sync_budget_s": mv.SYNC_BUDGET_S,
            "sync_degraded_s": mv.SYNC_DEGRADED_S,
            "readout_default_s": mv.T_READOUT_DEFAULT_S,
            "cam_sep_min_deg": mv.CAM_SEP_MIN_DEG,
            "cam_sep_ideal_deg": mv.CAM_SEP_IDEAL_DEG,
            "cam_sep_max_deg": mv.CAM_SEP_MAX_DEG,
            "min_views": mv.MIN_VIEWS,
            "reproj_rms_max_px": mv.REPROJ_RMS_MAX_PX,
            "scale_check_tol": mv.SCALE_CHECK_TOL,
            "plate_width_m": mv.PLATE_WIDTH_M,
            "coverage_min_3d": mv.COVERAGE_MIN_3D,
            "resample_max_gap_s": mv.RESAMPLE_MAX_GAP_S,
            "segment_azimuth_min_horiz": mv.SEGMENT_AZIMUTH_MIN_HORIZ,
            "gravity_min_span_s": mv.GRAVITY3D_MIN_SPAN_S,
            "launch_min_samples": mv.LAUNCH3D_MIN_SAMPLES,
            "min_rtt_keep_factor": mv.MIN_RTT_KEEP_FACTOR,
        },
        "flag_strings": [mv.FLAG3D_ONE_VIEW, mv.FLAG3D_LOW_COVERAGE,
                         mv.FLAG3D_HIGH_REPROJECTION, mv.FLAG3D_RESAMPLE_GAP],
        "clock": clock_cases(),
        "resample": resample_cases(),
        "projection": cams["projection"],
        "row_delay": cams["row_delay"],
        "triangulation": triangulation_cases(),
        "rotation": rotation_cases(),
        "flight": flight_cases(),
        "series_flags": flag_cases(),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(doc, f, indent=1, allow_nan=False)
    print(f"wrote {os.path.normpath(OUT)}")
    for k, v in doc.items():
        if isinstance(v, list):
            print(f"  {k}: {len(v)} cases")


if __name__ == "__main__":
    main()
