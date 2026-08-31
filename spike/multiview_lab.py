#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
multiview_lab.py — measure a real two-phone capture, offline, today.

The linked-capture app (docs/SWINGLAB_PRO.md, P1-P4) does not exist yet, and
waiting for it to exist before pointing two phones at a ball would be the
wrong order: the 3D math is the part that can be wrong in ways a synthetic
test cannot catch, and it can be tested right now with two clips, a tape
measure, and no Xcode.

So this is the merge-later path, used as a MEASURING INSTRUMENT rather than
as a product: two clips filmed independently, aligned here, triangulated
here, and checked against physics here.

  python multiview_lab.py --a a.mov --b b.mov --rig rig.json
  python multiview_lab.py --selftest        # proves itself first, no clips

Why this is worth doing before the app:

  The single-camera scale comes from the ball's apparent diameter, and
  docs/VALIDATION.md's G0 runs found that measurement under-reads by 11% on
  a 37 px ball and 43% on a 26 px one — size-dependent, so no constant fixes
  it. TWO cameras do not use the diameter at all. Their scale is the
  distance between the tripods, which is a tape measure, and the reported
  |g| is a witness that a tape measure cannot fake. This tool can therefore
  produce a trustworthy speed on footage where the one-camera path currently
  cannot.

The rig is MEASURED, not solved (P2 solves it from a wand pass). That is
deliberate: it removes the calibration solver from the experiment, so when a
number comes out wrong there is one fewer place for the fault to hide.

Rig file (JSON) — five tape measurements and two taps:

  {
    "ground_distance_a_m":  6.00,   tripod A base -> the mark, along the ground
    "ground_distance_b_m":  6.00,   tripod B base -> the mark
    "ground_distance_ab_m": 8.49,   tripod A base -> tripod B base
    "lens_height_a_m":      1.10,
    "lens_height_b_m":      1.10,
    "b_toward_plus_x":      true,   B is on the pitcher side of A's view
    "fov_deg":              60.0,
    "reference_height_m":   0.90,   height of the stationary reference ball
    "reference_px_a":     [960, 700],   where that ball sits in A's frame
    "reference_px_b":     [900, 690]    ... and in B's
  }

All three distances are HORIZONTAL, base to base, because a slant distance
to a lens is the one measurement a person cannot take accurately alone.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import cv2
import numpy as np

import sla_common as sla
import sla_multiview as mv
from armed_phone_test import FrameSource, extract_mono

SELFTEST_OFFSET_S = 0.37          # deliberate clock disagreement in the rehearsal
SELFTEST_FPS = 240.0
SELFTEST_W, SELFTEST_H = 1920, 1080
SELFTEST_FOV = 60.0
SELFTEST_DROP_HEIGHT_M = 1.70
SELFTEST_REF_HEIGHT_M = 0.90
BALL_BGR = (0, 255, 204)


class Stage:
    def __init__(self, name: str, ok: bool, detail: str):
        self.name, self.ok, self.detail = name, ok, detail

    def line(self) -> str:
        return f"  [{'ok ' if self.ok else 'FAIL'}] {self.name}: {self.detail}"


# --- Per-view 2D tracking (the production chain, unchanged) -----------------

def track_view(path: str, fps_override: float | None, label: str,
               stages: list[Stage]):
    """Decode one clip and run the exact production 2D chain over it.

    Timestamps come from FrameSource, i.e. from presentation timestamps, not
    from counting frames. armed_phone_test.py's first finding was that the
    Photos export path produces slow-motion EDITS whose headers claim 175 and
    147 fps for 240fps footage — and two views aligned on a wrong clock are
    not two views of the same instant.
    """
    src = FrameSource(path, fps_override)
    per_frame = {}
    prev_gray = None
    n_frames = 0
    first_frame = None
    for idx, t, frame in src.iter():
        n_frames += 1
        if first_frame is None:
            first_frame = frame.copy()
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fg = sla.motion_mask(gray, prev_gray)
        prev_gray = gray
        if fg is None:
            continue
        cands = sla.detect_ball_candidates(frame, idx, t, fg_mask=fg)
        if cands:
            per_frame[idx] = cands

    stages.append(Stage(
        f"{label} decode",
        n_frames > 0,
        f"{n_frames} frames, {src.width}x{src.height}, "
        f"{src.fps:.2f} fps measured"
        + (f", {src.irregular_fraction*100:.0f}% irregular intervals"
           if src.irregular_fraction > 0.02 else "")))

    n_cands = sum(len(v) for v in per_frame.values())
    tracks = sla.build_tracks(per_frame, src.fps)
    tracks = sla.stitch_tracks(tracks)
    stages.append(Stage(
        f"{label} detect",
        bool(tracks),
        f"{n_cands} candidates over {len(per_frame)} frames -> "
        f"{len(tracks)} chains"
        + (f", longest {max(len(t) for t in tracks)} frames" if tracks else "")))

    # LONGEST, not fastest. `select_outbound_track` scores on speed because
    # its job is to tell a struck ball from the pitch that preceded it; here
    # the job is different and the speed heuristic actively hurts. On the
    # rehearsal it picked a 44-frame fragment over the 87-frame chain of the
    # same fall, and a gravity fit over the short one reads 5% low.
    #
    # Picking the longest chain per view independently is safe ONLY because
    # the two views are checked against each other afterwards: if they follow
    # different objects the reprojection error explodes, which is exactly
    # what the sync and triangulate stages measure. Two cameras are their own
    # guard against picking the wrong ball, which one camera never was.
    track = max(tracks, key=len) if tracks else None
    ok = track is not None and len(track) >= 6
    stages.append(Stage(
        f"{label} track",
        ok,
        f"{len(track)} frames over {track[-1].t - track[0].t:.3f} s, "
        f"straightness {sla.track_straightness(track):.2f}"
        if ok else "no usable chain — the ball was never followed in this view"))
    return src, track, first_frame


def refine_reference(frame, tap) -> tuple[float, float]:
    """Sharpen a rough tap onto the reference ball's actual centre.

    Detected WITHOUT a motion mask on purpose: the reference ball is the one
    ball in the scene that must not move, so the motion gate — the thing that
    makes detection work at all on the moving ball — is exactly what would
    hide it.
    """
    cands = sla.detect_ball_candidates(frame, 0, 0.0, fg_mask=None)
    if not cands:
        return float(tap[0]), float(tap[1])
    near = min(cands, key=lambda c: (c.x - tap[0]) ** 2 + (c.y - tap[1]) ** 2)
    if math.hypot(near.x - tap[0], near.y - tap[1]) > 60.0:
        return float(tap[0]), float(tap[1])
    return float(near.x), float(near.y)


# --- The run ----------------------------------------------------------------

def run(path_a: str, path_b: str, rig_spec: dict,
        fps_override: float | None = None) -> int:
    stages: list[Stage] = []
    print(f"A: {path_a}\nB: {path_b}\n")

    src_a, track_a, frame_a = track_view(path_a, fps_override, "A", stages)
    src_b, track_b, frame_b = track_view(path_b, fps_override, "B", stages)

    intr = mv.CameraIntrinsics.from_fov(
        src_a.width, src_a.height, float(rig_spec.get("fov_deg", 60.0)))
    rig = mv.rig_from_ground_triangle(
        float(rig_spec["ground_distance_a_m"]),
        float(rig_spec["ground_distance_b_m"]),
        float(rig_spec["ground_distance_ab_m"]),
        float(rig_spec["lens_height_a_m"]),
        float(rig_spec["lens_height_b_m"]),
        bool(rig_spec.get("b_toward_plus_x", True)))
    if rig is None:
        stages.append(Stage("rig", False,
                            "those three ground distances cannot form a "
                            "triangle — one of them is mis-measured"))
        return report(stages, None)

    sep_ok = mv.CAM_SEP_MIN_DEG <= rig.separation_deg <= mv.CAM_SEP_MAX_DEG
    stages.append(Stage(
        "rig", True,
        f"separation {rig.separation_deg:.1f} deg"
        + ("" if sep_ok else
           f" — OUTSIDE the {mv.CAM_SEP_MIN_DEG:.0f}-{mv.CAM_SEP_MAX_DEG:.0f} deg "
           f"band; move a tripod before trusting depth")))

    # Aim: solved from the reference ball when there is one, assumed otherwise.
    ref_h = float(rig_spec.get("reference_height_m", 0.9))
    ref_world = np.array([0.0, 0.0, ref_h])
    extr_a = extr_b = None
    if rig_spec.get("reference_px_a") and rig_spec.get("reference_px_b"):
        ua, va = refine_reference(frame_a, rig_spec["reference_px_a"])
        ub, vb = refine_reference(frame_b, rig_spec["reference_px_b"])
        extr_a = mv.solve_aim_from_reference(intr, rig.pos_a, ref_world, ua, va)
        extr_b = mv.solve_aim_from_reference(intr, rig.pos_b, ref_world, ub, vb)
        stages.append(Stage(
            "aim", extr_a is not None and extr_b is not None,
            f"solved from the reference ball at A({ua:.0f},{va:.0f}) "
            f"B({ub:.0f},{vb:.0f})" if extr_a is not None and extr_b is not None
            else "reference ball given but the aim solve did not converge"))
    if extr_a is None or extr_b is None:
        extr_a = mv.look_at_extrinsics(rig.pos_a, ref_world)
        extr_b = mv.look_at_extrinsics(rig.pos_b, ref_world)
        stages.append(Stage(
            "aim", True,
            "ASSUMED both cameras point exactly at the mark — no reference "
            "ball supplied, so aiming error goes straight into the answer"))

    p_a = mv.projection_matrix(intr, extr_a)
    p_b = mv.projection_matrix(intr, extr_b)

    if track_a is None or track_b is None:
        return report(stages, None)

    ts_a = np.array([o.t for o in track_a])
    us_a = np.array([o.x for o in track_a])
    vs_a = np.array([o.y for o in track_a])
    ts_b = np.array([o.t for o in track_b])
    us_b = np.array([o.x for o in track_b])
    vs_b = np.array([o.y for o in track_b])

    # Sync. Geometry is the primary method because it needs nothing from the
    # clips but the ball, and the slow-motion export path is known to drop or
    # time-stretch audio (audio_lab.py). Audio, when it survives, is an
    # INDEPENDENT witness — two methods agreeing is the evidence.
    got = mv.solve_time_offset(p_a, ts_a, us_a, vs_a, p_b, ts_b, us_b, vs_b)
    if got is None:
        stages.append(Stage("sync", False,
                            "no offset made the two views geometrically "
                            "consistent — check the rig, or the two clips may "
                            "not overlap in time at all"))
        return report(stages, None)
    offset_s, sync_rms = got
    stages.append(Stage(
        "sync (geometry)", sync_rms <= mv.REPROJ_RMS_MAX_PX,
        f"B's clock reads {offset_s*1000:+.1f} ms vs A; "
        f"median reprojection {sync_rms:.2f} px"))

    audio_note = try_audio_cross_check(path_a, path_b, offset_s, stages)

    # Triangulate on a common grid.
    tb = ts_b - offset_s
    lo, hi = max(ts_a.min(), tb.min()), min(ts_a.max(), tb.max())
    grid = np.arange(lo, hi, 1.0 / 240.0)
    ua_g, va_g, wa_g, gap_a = mv.resample_view(ts_a, us_a, vs_a,
                                               np.ones_like(ts_a), grid)
    ub_g, vb_g, wb_g, gap_b = mv.resample_view(tb, us_b, vs_b,
                                               np.ones_like(tb), grid)
    track3d = mv.triangulate_series(
        grid,
        [mv.ViewTrack2D(p_a, ua_g, va_g, wa_g),
         mv.ViewTrack2D(p_b, ub_g, vb_g, wb_g)],
        had_gap=gap_a or gap_b)
    n3d = int(np.sum(np.isfinite(track3d.xyz[:, 0])))
    stages.append(Stage(
        "triangulate", n3d >= 12,
        f"{n3d} of {grid.size} instants reconstructed "
        f"({track3d.coverage*100:.0f}% coverage), median reprojection "
        f"{np.nanmedian(track3d.reproj_rms_px):.2f} px"
        + (f", flags {track3d.flags}" if track3d.flags else "")))

    return report(stages, track3d, grid, audio_note)


def try_audio_cross_check(path_a: str, path_b: str, geo_offset_s: float,
                          stages: list[Stage]) -> str | None:
    """Independent offset from the sound, when the export left any."""
    try:
        a, sr_a = extract_mono(path_a)
        b, sr_b = extract_mono(path_b)
    except Exception as exc:                                   # noqa: BLE001
        stages.append(Stage("sync (audio)", True,
                            f"skipped — no usable audio track ({exc}). "
                            "Expected on slow-motion exports; the geometry "
                            "solve above does not need it"))
        return None
    if sr_a != sr_b or a.size < 1000 or b.size < 1000:
        stages.append(Stage("sync (audio)", True,
                            "skipped — sample rates differ or the tracks are "
                            "too short to correlate"))
        return None
    got = mv.gcc_phat_offset(a, b, float(sr_a))
    if got is None:
        stages.append(Stage("sync (audio)", True, "skipped — correlation failed"))
        return None
    audio_off, conf = got
    disagree_ms = abs(audio_off - geo_offset_s) * 1000.0
    # Loose on purpose: the two phones stand at different distances from the
    # clap, which is ~2.9 ms per metre of path difference and is NOT corrected
    # here. This check is for gross disagreement — a wrong clip pairing, a
    # missed second clap — not for sub-frame agreement.
    stages.append(Stage(
        "sync (audio)", disagree_ms <= 40.0,
        f"audio says {audio_off*1000:+.1f} ms (peak {conf:.1f}x median), "
        f"geometry says {geo_offset_s*1000:+.1f} ms — "
        f"{disagree_ms:.1f} ms apart"
        + ("" if disagree_ms <= 40.0 else
           " — that is too far apart to be sound travel; are these two clips "
           "of the SAME event?")))
    return f"{audio_off*1000:+.1f} ms"


def report(stages: list[Stage], track3d, grid=None, audio_note=None) -> int:
    print("stages")
    for s in stages:
        print(s.line())

    if track3d is None:
        print("\nverdict")
        failed = next((s for s in stages if not s.ok), None)
        print(f"  FAILED at: {failed.name if failed else 'unknown'}")
        print(f"  {failed.detail if failed else ''}")
        print("\n  Send me this whole report. The stage named above is the one "
              "to fix first;\n  everything downstream of it is meaningless "
              "until it passes.")
        return 1

    xyz = track3d.xyz
    g_est = mv.gravity_magnitude_3d(grid, xyz)
    finite = np.isfinite(xyz[:, 0])

    print("\nmeasurements")
    if g_est is not None:
        err = (g_est / sla.G - 1.0) * 100.0
        print(f"  gravity      |a| = {g_est:.3f} m/s^2 vs 9.807 ({err:+.1f}%)")
        print("               This is the whole rig's witness: it needs no "
              "reference object,\n               no ball diameter and no "
              "radar. If it is right, the geometry is right.")
    else:
        print("  gravity      not computable — the ball needs "
              f"{mv.GRAVITY3D_MIN_SPAN_S:.2f} s of tracked flight")

    if finite.sum() >= 2:
        first = xyz[np.flatnonzero(finite)[0]]
        last = xyz[np.flatnonzero(finite)[-1]]
        print(f"  path         from ({first[0]:+.2f}, {first[1]:+.2f}, "
              f"{first[2]:+.2f}) m to ({last[0]:+.2f}, {last[1]:+.2f}, "
              f"{last[2]:+.2f}) m")
        print(f"               fell {first[2] - last[2]:+.2f} m, moved "
              f"{math.hypot(last[0]-first[0], last[1]-first[1]):.2f} m "
              "horizontally")

    print("\nverdict")
    hard_fail = [s for s in stages if not s.ok]
    if g_est is not None and abs(g_est / sla.G - 1.0) <= 0.05 and not hard_fail:
        print("  PASS — the reconstruction recovers gravity from a "
              "tape-measured rig.")
        print("  The geometry, the sync and the triangulation are all working "
              "on real footage.")
        return 0
    if g_est is not None and abs(g_est / sla.G - 1.0) > 0.05:
        print(f"  Gravity is off by {(g_est/sla.G-1)*100:+.1f}%. In order of "
              "likelihood:")
        print("    1. a tape measurement is wrong (the scale rides directly "
              "on the baseline)")
        print("    2. the field of view is wrong for this phone/format")
        print("    3. the cameras were not aimed where the rig assumes")
    if hard_fail:
        print(f"  Stage '{hard_fail[0].name}' did not pass — fix that first.")
    print("\n  Send me this whole report and I will tell you which one it is.")
    return 1


# --- Self-test: rehearse the whole thing on clips whose answer is known -----

def drop_height(t_s: float, h0: float = SELFTEST_DROP_HEIGHT_M) -> float:
    """Height of a dropped softball at time t, WITH drag.

    A drag-free drop would be one line, and the first version of this was.
    It made the rehearsal unfair in a way that flattered nothing: the ball
    fell without drag while `gravity_magnitude_3d` corrected for drag that
    was not there, and the recovered |g| came out 3.2% high — an error
    invented entirely by the test. A real dropped ball reaches about 4 m/s in
    half a second, where drag is ~2% of g, so the honest rehearsal integrates
    it and the drag-aware estimator then has the right thing to undo.
    """
    k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD
                * math.pi * (sla.BALL_DIAMETER_M / 2.0) ** 2 / sla.BALL_MASS_KG)
    dt = 1.0 / (SELFTEST_FPS * 10.0)
    z, v = h0, 0.0
    for _ in range(max(0, int(t_s / dt))):
        v += (-sla.G + k_over_m * v * v) * dt      # drag opposes the fall
        z += v * dt
    return z


def render_drop_clip(path: str, intr, extr, t_offset_s: float,
                     n_frames: int = 200) -> None:
    """A ball dropped past a stationary reference ball, filmed by one camera.

    Same rendering recipe as synth_test.py — grassy gradient, fence posts,
    seeded noise, motion-smeared ellipse — because the compression halo and
    the motion gate are part of what is being rehearsed, not scenery.
    `t_offset_s` shifts this camera's clock, so the sync solve has something
    real to find.
    """
    rng = np.random.default_rng(5)
    h, w = intr.height_px, intr.width_px
    yy = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    base = np.zeros((h, w, 3), np.uint8)
    base[:, :, 0] = (40 + 30 * yy).astype(np.uint8)
    base[:, :, 1] = (95 + 40 * yy).astype(np.uint8)
    base[:, :, 2] = (55 + 25 * yy).astype(np.uint8)
    for x in range(0, w, 160):
        cv2.line(base, (x, 0), (x, h), (35, 60, 40), 5)

    vw = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 60.0, (w, h))
    if not vw.isOpened():
        raise IOError("VideoWriter failed to open (mp4v)")
    p_mat = mv.projection_matrix(intr, extr)
    ref_world = np.array([0.0, 0.0, SELFTEST_REF_HEIGHT_M])
    drop_start = np.array([0.30, 0.05, SELFTEST_DROP_HEIGHT_M])

    def draw(frame, world_pt, smear_vec):
        uv = mv.project_point(p_mat, world_pt)
        if uv is None or not (0 <= uv[0] < w and 0 <= uv[1] < h):
            return
        depth = float((extr.r @ world_pt + extr.t)[2])
        d_px = sla.BALL_DIAMETER_M * intr.fx / depth
        smear = float(np.linalg.norm(smear_vec)) if smear_vec is not None else 0.0
        ang = (math.degrees(math.atan2(smear_vec[1], smear_vec[0]))
               if smear_vec is not None and smear > 1e-6 else 0.0)
        axes = (int(round((d_px + smear) / 2)), int(round(d_px / 2)))
        if min(axes) >= 2:
            cv2.ellipse(frame, (int(round(uv[0])), int(round(uv[1]))),
                        axes, ang, 0, 360, BALL_BGR, -1)

    for i in range(n_frames):
        # This camera's own clock: frame i is shown at i/fps, but the world
        # event it sees happened at (i/fps - t_offset_s) of true time.
        t_true = i / SELFTEST_FPS - t_offset_s
        frame = base.copy()
        noise = rng.integers(-6, 7, (h, w, 1), dtype=np.int16)
        frame = np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        draw(frame, ref_world, None)
        if t_true > 0.0:
            z = drop_height(t_true)
            if z > 0.05:
                pos = np.array([drop_start[0], drop_start[1], z])
                nxt = np.array([drop_start[0], drop_start[1],
                                drop_height(t_true + 1.0 / SELFTEST_FPS)])
                uv0 = mv.project_point(p_mat, pos)
                uv1 = mv.project_point(p_mat, nxt)
                smear = ((np.array(uv1) - np.array(uv0)) * 0.24
                         if uv0 and uv1 else None)
                draw(frame, pos, smear)
        vw.write(frame)
    vw.release()


def selftest() -> int:
    """Rehearse a real two-phone drop test end to end, with known answers.

    The repo's habit: any tool that renders a verdict passes first on a case
    where the answer is known (audio_lab.selftest, armed_phone_test.selftest).
    Here the known answers are the rig geometry, a 370 ms clock disagreement,
    and gravity.
    """
    os.makedirs("out", exist_ok=True)
    print("Rehearsing a two-phone drop test on synthetic clips.\n"
          "Truth: 6.00 m / 6.00 m tripods 8.49 m apart (90 deg separation), "
          f"B's clock {SELFTEST_OFFSET_S*1000:.0f} ms behind A's, "
          "ball dropped from 1.70 m.\n")

    intr = mv.CameraIntrinsics.from_fov(SELFTEST_W, SELFTEST_H, SELFTEST_FOV)
    d_a = d_b = 6.0
    d_ab = math.sqrt(d_a * d_a + d_b * d_b)          # exactly 90 degrees
    rig = mv.rig_from_ground_triangle(d_a, d_b, d_ab, 1.10, 1.10, True)
    ref_world = np.array([0.0, 0.0, SELFTEST_REF_HEIGHT_M])
    extr_a = mv.look_at_extrinsics(rig.pos_a, ref_world)
    extr_b = mv.look_at_extrinsics(rig.pos_b, ref_world)

    path_a = os.path.join("out", "lab_A.mp4")
    path_b = os.path.join("out", "lab_B.mp4")
    render_drop_clip(path_a, intr, extr_a, 0.0)
    render_drop_clip(path_b, intr, extr_b, SELFTEST_OFFSET_S)

    ref_a = mv.project_point(mv.projection_matrix(intr, extr_a), ref_world)
    ref_b = mv.project_point(mv.projection_matrix(intr, extr_b), ref_world)
    spec = {
        "ground_distance_a_m": d_a, "ground_distance_b_m": d_b,
        "ground_distance_ab_m": d_ab,
        "lens_height_a_m": 1.10, "lens_height_b_m": 1.10,
        "b_toward_plus_x": True, "fov_deg": SELFTEST_FOV,
        "reference_height_m": SELFTEST_REF_HEIGHT_M,
        "reference_px_a": [round(ref_a[0]), round(ref_a[1])],
        "reference_px_b": [round(ref_b[0]), round(ref_b[1])],
    }
    spec_path = os.path.join("out", "lab_rig.json")
    with open(spec_path, "w") as f:
        json.dump(spec, f, indent=2)
    print(f"wrote {path_a}, {path_b}, {spec_path}\n")

    rc = run(path_a, path_b, spec, fps_override=SELFTEST_FPS)
    print()
    if rc == 0:
        print("SELFTEST PASS — the lab recovers a known rig and gravity from "
              "two encoded clips.\nIt is ready for real footage; see "
              "docs/PRO_FIELD_GUIDE.md for what to film.")
    else:
        print("SELFTEST FAILED — fix this before trusting it on real clips.")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", help="clip from camera A (the side-on phone)")
    ap.add_argument("--b", help="clip from camera B")
    ap.add_argument("--rig", help="JSON file of tape measurements")
    ap.add_argument("--fps", type=float, default=None,
                    help="override the clip's clock (use 240 only when you "
                         "know the container is lying and the frames are "
                         "evenly spaced)")
    ap.add_argument("--selftest", action="store_true",
                    help="rehearse on synthetic clips with known answers")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not (args.a and args.b and args.rig):
        ap.error("need --a, --b and --rig (or --selftest)")
    with open(args.rig) as f:
        spec = json.load(f)
    return run(args.a, args.b, spec, args.fps)


if __name__ == "__main__":
    sys.exit(main())
