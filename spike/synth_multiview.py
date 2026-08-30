#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
synth_multiview.py — end-to-end self-test of the two-phone 3D reconstruction.

Simulates a KNOWN 3D swing scene (rotating pelvis/thorax proxy, swung bat,
drag-affected ball), films it with two modelled iPhones — pinhole projection,
rolling shutter, free-running frame phase, per-phone clock offset and skew,
pixel noise, occlusion — then reconstructs it with the exact sla_multiview
pipeline the app will port, and asserts the truth is recovered within
tolerance. The ball path additionally goes the long way: rendered into two
actually-ENCODED clips and pushed through sla_common's production 2D
detection before triangulation, because the compression halo and the motion
gate are part of the system under test.

Following synth_test.py's law, reconstruction checks that merely invert this
file's own projector prove self-consistency, not correctness — so the
projector and the triangulator are first checked against image coordinates
and an intersection point derived BY HAND (in the comments), sharing no code
with sla_multiview.

  python synth_multiview.py            ->  ... ALL PASS       (~1 minute)
  python synth_multiview.py --sweep    ->  out/multiview_budget.csv

The sweep is the error budget behind docs/SWINGLAB_PRO.md's accuracy table:
sync error x calibration error x camera separation x rolling shutter, each
mapped to hip-shoulder-separation / joint / bat / launch error.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from dataclasses import dataclass, field, replace

import cv2
import numpy as np

import sla_common as sla
import sla_multiview as mv

# --- Ground truth -----------------------------------------------------------
FPS = 240.0
W, H = 1920, 1080
FOV_DEG = 60.0

CONTACT_T = 0.50                    # true-clock instant of bat-ball contact
GRID_T0, GRID_T1 = 0.10, 0.62      # analysis span (ends contact + VELOCITY_WINDOW_S)

TRUE_EV_MPH = 65.0
TRUE_LA_DEG = 25.0
TRUE_SPRAY_DEG = -8.0              # pulled slightly toward -Y

# Hip-shoulder separation is CONSTRUCTED, not tuned: the thorax profile is
# defined as pelvis minus a Gaussian bump, so the true curve peaks at exactly
# TRUE_HSS_PEAK_DEG at exactly HSS_PEAK_T. Peak comparisons apply the same
# estimator (mv.quadratic_peak) to truth and to reconstruction, so they
# measure reconstruction error, not estimator bias.
TRUE_HSS_PEAK_DEG = 42.0
HSS_BASE_DEG = 12.0
HSS_PEAK_T = CONTACT_T - 0.060
HSS_SIGMA_S = 0.045
HSS_PEAK_HALFWIN_S = 0.030

HIP_W_M, SHOULDER_W_M = 0.34, 0.40
HIP_Z_M, SHOULDER_Z_M = 1.00, 1.45
BAT_R_M = 0.86                     # pivot-to-tip lever
BAT_TIP_SPEED_MPS = 30.0           # slow-pitch bats swing ~60-70 mph
BAT_DROOP_M = 0.28

SCENE_TARGET = np.array([0.15, 0.0, 1.20])
CAM_DIST_M = 6.0
CAM_H_M = 1.10
CAM_A_AZ_DEG = 0.0                 # side-on, per CAPTURE_PROTOCOL.md
CAM_B_AZ_DEG = -85.0               # 85 deg of separation, NOT downrange:
                                   # the ball flies out at spray -8 deg off
                                   # +X, so the second phone goes on the side
                                   # the ball leaves, never the side it
                                   # arrives at.

# Worker phone B's true clock: t_local = (1 + skew) * t_true + offset.
CAM_B_CLOCK_OFFSET_S = 0.1375
CAM_B_CLOCK_SKEW = 20e-6
CAM_B_PHASE_S = 0.0021             # free-running shutter phase vs phone A

BODY_NAMES = ["left_hip", "right_hip", "left_shoulder", "right_shoulder",
              "left_ankle", "right_ankle"]
ALL_NAMES = BODY_NAMES + ["bat_tape", "bat_tip", "ball"]

BALL_BGR = (0, 255, 204)           # optic yellow, as in synth_test.py
E2E_SHUTTER_S = 1.0 / 1000.0


def _sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))


# --- The scene ---------------------------------------------------------------

class Scene:
    """Closed-form 3D swing proxy. point(name, t) at ANY true time — the
    rolling-shutter forward model needs positions between frame instants."""

    def __init__(self):
        # Drag-integrated ball table at 10x frame rate; linear interp below.
        ev = TRUE_EV_MPH / sla.MPH_PER_MPS
        la = math.radians(TRUE_LA_DEG)
        sp = math.radians(TRUE_SPRAY_DEG)
        v = np.array([ev * math.cos(la) * math.cos(sp),
                      ev * math.cos(la) * math.sin(sp),
                      ev * math.sin(la)])
        k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD
                    * math.pi * (sla.BALL_DIAMETER_M / 2.0) ** 2 / sla.BALL_MASS_KG)
        self.ball_rest = np.array([0.35, 0.0, 0.95])
        dt = 1.0 / (FPS * 10.0)
        n = int((GRID_T1 + 0.10 - CONTACT_T) / dt) + 2
        pos = np.zeros((n, 3))
        p = self.ball_rest.copy()
        for i in range(n):
            pos[i] = p
            a = np.array([0.0, 0.0, -sla.G]) - k_over_m * np.linalg.norm(v) * v
            v = v + a * dt
            p = p + v * dt
        self._ball_t = CONTACT_T + dt * np.arange(n)
        self._ball_p = pos

        # Bat: logistic sweep whose peak angular velocity gives the tip speed.
        omega_max = BAT_TIP_SPEED_MPS / BAT_R_M
        self._bat_dtheta = 3.0
        self._bat_tau = self._bat_dtheta / (4.0 * omega_max)
        self._bat_t0 = CONTACT_T - 0.010
        self._bat_theta0 = -2.4

    # segment azimuth profiles, degrees
    def pelvis_az_deg(self, t: float) -> float:
        return -40.0 + 100.0 * _sigmoid((t - (CONTACT_T - 0.075)) / 0.050)

    def hss_true_deg(self, t: float) -> float:
        z = (t - HSS_PEAK_T) / HSS_SIGMA_S
        return HSS_BASE_DEG + (TRUE_HSS_PEAK_DEG - HSS_BASE_DEG) * math.exp(-z * z)

    def thorax_az_deg(self, t: float) -> float:
        return self.pelvis_az_deg(t) - self.hss_true_deg(t)

    def _x_shift(self, t: float) -> float:
        return 0.12 * _sigmoid((t - 0.35) / 0.08)      # weight shift

    def point(self, name: str, t: float) -> np.ndarray:
        if name == "ball":
            if t <= CONTACT_T:
                return self.ball_rest.copy()
            i = np.searchsorted(self._ball_t, t) - 1
            i = min(max(i, 0), len(self._ball_t) - 2)
            f = (t - self._ball_t[i]) / (self._ball_t[i + 1] - self._ball_t[i])
            return self._ball_p[i] * (1.0 - f) + self._ball_p[i + 1] * f
        if name in ("bat_tape", "bat_tip"):
            theta = self._bat_theta0 + self._bat_dtheta * _sigmoid((t - self._bat_t0) / self._bat_tau)
            pivot = np.array([self._x_shift(t) + 0.08, 0.0, 1.32])
            offs = np.array([BAT_R_M * math.cos(theta), BAT_R_M * math.sin(theta), -BAT_DROOP_M])
            return pivot + (offs if name == "bat_tip" else 0.72 * offs)
        if name.endswith("_ankle"):
            return np.array([0.02, 0.22 if name.startswith("left") else -0.22, 0.09])
        if name.endswith("_hip"):
            az = math.radians(self.pelvis_az_deg(t))
            half, z = HIP_W_M / 2.0, HIP_Z_M
        else:
            az = math.radians(self.thorax_az_deg(t))
            half, z = SHOULDER_W_M / 2.0, SHOULDER_Z_M
        c = np.array([self._x_shift(t) + (0.05 if z == SHOULDER_Z_M else 0.0), 0.0, z])
        d = np.array([math.cos(az), math.sin(az), 0.0]) * half
        return c + d if name.startswith("left") else c - d


def cam_position(az_deg: float, dist_m: float, h_m: float,
                 target: np.ndarray) -> np.ndarray:
    """Azimuth 0 is the classic side-on spot: on the -Y side, looking across
    the hit line. Positive azimuth walks the camera toward +X (downrange)."""
    a = math.radians(az_deg)
    return np.array([target[0] + dist_m * math.sin(a),
                     target[1] - dist_m * math.cos(a),
                     h_m])


def make_camera(az_deg: float, dist_m: float = CAM_DIST_M, h_m: float = CAM_H_M,
                target: np.ndarray = SCENE_TARGET):
    intr = mv.CameraIntrinsics.from_fov(W, H, FOV_DEG)
    pos = cam_position(az_deg, dist_m, h_m, target)
    extr = mv.look_at_extrinsics(pos, target)
    assert intr is not None and extr is not None
    return intr, extr, pos


# --- Filming (observation level) ---------------------------------------------

@dataclass
class ViewRaw:
    """One camera's raw observations of one point: frame PTS on that
    camera's OWN clock, pixel coords, confidences."""
    pts: np.ndarray
    us: np.ndarray
    vs: np.ndarray
    ws: np.ndarray


def render_view(scene: Scene, names, intr, extr, *,
                t0: float, t1: float, fps: float = FPS,
                phase_s: float = 0.0,
                clock_offset_s: float = 0.0, clock_skew: float = 0.0,
                readout_s: float = 0.0,
                noise_px: float = 0.0, conf_dips: bool = False,
                occlusions: dict | None = None,
                rng: np.random.Generator | None = None) -> dict:
    """Film the scene with one modelled phone; observation-level (no pixels).

    Rolling shutter is a forward model: the row an observation lands on
    decides when it was actually exposed, solved by two fixed-point passes
    (the point moves millimetres within one readout, so two converge).
    Reported timestamps are the FRAME's PTS on the camera's own clock —
    reconstruction must undo both the clock and the row delay, exactly as
    the app will have to.
    """
    p_mat = mv.projection_matrix(intr, extr)
    occlusions = occlusions or {}
    if rng is None:
        rng = np.random.default_rng(0)
    k0 = int(math.floor((t0 - phase_s) * fps)) - 1
    k1 = int(math.ceil((t1 - phase_s) * fps)) + 1
    out = {}
    for name in names:
        pts, us, vs, ws = [], [], [], []
        occ = occlusions.get(name)
        for k in range(k0, k1 + 1):
            t_f = phase_s + k / fps
            if occ is not None and occ[0] <= t_f <= occ[1]:
                continue
            uv = mv.project_point(p_mat, scene.point(name, t_f))
            if uv is None:
                continue
            if readout_s > 0.0:
                for _ in range(2):
                    t_cap = t_f + mv.rs_row_delay_s(uv[1], H, readout_s)
                    uv = mv.project_point(p_mat, scene.point(name, t_cap))
                    if uv is None:
                        break
                if uv is None:
                    continue
            u, v = uv
            if noise_px > 0.0:
                u += rng.normal(0.0, noise_px)
                v += rng.normal(0.0, noise_px)
            if not (0.0 <= u < W and 0.0 <= v < H):
                continue
            w = float(rng.uniform(0.55, 0.95)) if conf_dips else 0.9
            if w < sla.JOINT_CONFIDENCE_MIN:
                continue
            pts.append((1.0 + clock_skew) * t_f + clock_offset_s)
            us.append(u)
            vs.append(v)
            ws.append(w)
        out[name] = ViewRaw(np.array(pts), np.array(us), np.array(vs), np.array(ws))
    return out


def true_clock_model(offset_s: float, skew: float, t_ref_s: float = 0.0) -> mv.ClockModel:
    """The EXACT inverse of t_local = (1+skew)*t + offset, expressed in
    ClockModel's parameterisation — so a perfectly-known clock reconstructs
    perfectly and any residual error in the checks is someone else's."""
    sk = skew / (1.0 + skew)
    return mv.ClockModel(offset_s=sk * t_ref_s + offset_s / (1.0 + skew),
                         skew=sk, t_ref_s=t_ref_s,
                         rtt_min_s=0.0, n_used=0, ci_s=0.0)


IDENTITY_CLOCK = mv.ClockModel(0.0, 0.0, 0.0, 0.0, 0, 0.0)


# --- Reconstruction (the exact production sequence) --------------------------

def reconstruct(views_raw: dict, p_est: dict, clocks: dict, readouts: dict,
                t_grid: np.ndarray, names=None) -> dict:
    """views_raw[cam][name] -> ViewRaw; p_est[cam] -> 3x4; clocks[cam] ->
    ClockModel; readouts[cam] -> assumed readout (0 = no correction).
    Clock map -> rolling-shutter row delay -> resample -> triangulate:
    nothing here but sla_multiview calls, in the order the app will run them.
    """
    names = names or ALL_NAMES
    tracks = {}
    for name in names:
        view_tracks, had_gap = [], False
        for cam, raws in views_raw.items():
            raw = raws[name]
            t_master = mv.map_clock_s(raw.pts, clocks[cam])
            if readouts[cam] > 0.0 and raw.pts.size:
                t_master = t_master + np.array(
                    [mv.rs_row_delay_s(v, H, readouts[cam]) for v in raw.vs])
            us_g, vs_g, ws_g, gap = mv.resample_view(t_master, raw.us, raw.vs,
                                                     raw.ws, t_grid)
            had_gap = had_gap or gap
            view_tracks.append(mv.ViewTrack2D(p_est[cam], us_g, vs_g, ws_g))
        tracks[name] = mv.triangulate_series(t_grid, view_tracks, had_gap=had_gap)
    return tracks


def hss_series(tracks: dict, t_grid: np.ndarray) -> np.ndarray:
    out = np.full(t_grid.shape, np.nan)
    hl, hr = tracks["left_hip"].xyz, tracks["right_hip"].xyz
    sl, sr = tracks["left_shoulder"].xyz, tracks["right_shoulder"].xyz
    for i in range(t_grid.size):
        if all(np.all(np.isfinite(a[i])) for a in (hl, hr, sl, sr)):
            v = mv.hip_shoulder_separation_deg(hl[i], hr[i], sl[i], sr[i])
            if v is not None:
                out[i] = v
    return out


# --- One configured run ------------------------------------------------------

@dataclass
class RunCfg:
    sep_deg: float = 85.0
    noise_px: float = 0.3
    conf_dips: bool = False
    clock_est_err_s: float = 0.0      # error injected into B's clock model
    az_err_deg: float = 0.0           # error injected into B's extrinsics
    pos_err_m: float = 0.0
    readout_s: float = 0.0            # true sensor readout while filming
    correct_readout: bool = True      # does reconstruction apply the row delay
    occl_a: dict = field(default_factory=dict)
    seed: int = 11


@dataclass
class RunResult:
    t_grid: np.ndarray
    tracks: dict
    hss_meas: np.ndarray
    hss_true: np.ndarray
    launch: mv.LaunchMetrics3D | None


def run_reconstruction(scene: Scene, cfg: RunCfg) -> RunResult:
    rng = np.random.default_rng(cfg.seed)
    t_grid = np.arange(GRID_T0, GRID_T1 + 1e-9, 1.0 / FPS)

    intr_a, extr_a, _ = make_camera(CAM_A_AZ_DEG)
    intr_b, extr_b, _ = make_camera(-cfg.sep_deg)

    raw_a = render_view(scene, ALL_NAMES, intr_a, extr_a,
                        t0=GRID_T0, t1=GRID_T1,
                        readout_s=cfg.readout_s, noise_px=cfg.noise_px,
                        conf_dips=cfg.conf_dips, occlusions=cfg.occl_a, rng=rng)
    raw_b = render_view(scene, ALL_NAMES, intr_b, extr_b,
                        t0=GRID_T0, t1=GRID_T1,
                        phase_s=CAM_B_PHASE_S,
                        clock_offset_s=CAM_B_CLOCK_OFFSET_S,
                        clock_skew=CAM_B_CLOCK_SKEW,
                        readout_s=cfg.readout_s, noise_px=cfg.noise_px,
                        conf_dips=cfg.conf_dips, rng=rng)

    # Estimated calibration for B: the true rig, corrupted the way a bad
    # wand pass would corrupt it — bearing error plus a position error.
    intr_be, extr_be, _ = make_camera(-cfg.sep_deg + cfg.az_err_deg)
    if cfg.pos_err_m != 0.0:
        pos = cam_position(-cfg.sep_deg + cfg.az_err_deg, CAM_DIST_M, CAM_H_M,
                           SCENE_TARGET) + np.array([cfg.pos_err_m, 0.0, cfg.pos_err_m / 2.0])
        extr_be = mv.look_at_extrinsics(pos, SCENE_TARGET)

    clock_b = true_clock_model(CAM_B_CLOCK_OFFSET_S, CAM_B_CLOCK_SKEW)
    clock_b = replace(clock_b, offset_s=clock_b.offset_s + cfg.clock_est_err_s)

    readout_est = cfg.readout_s if cfg.correct_readout else 0.0
    tracks = reconstruct(
        {"A": raw_a, "B": raw_b},
        {"A": mv.projection_matrix(intr_a, extr_a),
         "B": mv.projection_matrix(intr_be, extr_be)},
        {"A": IDENTITY_CLOCK, "B": clock_b},
        {"A": readout_est, "B": readout_est},
        t_grid)

    hss_m = hss_series(tracks, t_grid)
    hss_t = np.array([scene.hss_true_deg(t) for t in t_grid])
    launch = mv.launch_metrics_3d(t_grid, tracks["ball"].xyz, CONTACT_T)
    return RunResult(t_grid, tracks, hss_m, hss_t, launch)


# --- Error measures ----------------------------------------------------------

def track_rmse_m(scene: Scene, res: RunResult, names) -> float:
    errs = []
    for name in names:
        xyz = res.tracks[name].xyz
        for i, t in enumerate(res.t_grid):
            if np.all(np.isfinite(xyz[i])):
                errs.append(float(np.sum((xyz[i] - scene.point(name, t)) ** 2)))
    return math.sqrt(float(np.mean(errs))) if errs else float("nan")


def depth_rmse_m(scene: Scene, res: RunResult, names) -> float:
    """Error along world Y — camera A's optical axis, the axis only the
    second camera can pin down."""
    errs = []
    for name in names:
        xyz = res.tracks[name].xyz
        for i, t in enumerate(res.t_grid):
            if np.all(np.isfinite(xyz[i])):
                errs.append((float(xyz[i][1]) - float(scene.point(name, t)[1])) ** 2)
    return math.sqrt(float(np.mean(errs))) if errs else float("nan")


def hss_peak_est(t_grid: np.ndarray, series: np.ndarray):
    m = np.isfinite(series)
    if not m.any():
        return None
    t_c = float(t_grid[m][int(np.argmax(series[m]))])
    return mv.quadratic_peak(t_grid, series, t_c, HSS_PEAK_HALFWIN_S)


def hss_rmse_deg(res: RunResult) -> float:
    m = np.isfinite(res.hss_meas)
    if not m.any():
        return float("nan")
    return math.sqrt(float(np.mean((res.hss_meas[m] - res.hss_true[m]) ** 2)))


# --- Independent geometry checks (no shared code with the projector) ---------

def independent_checks(check) -> None:
    intr = mv.CameraIntrinsics.from_fov(W, H, FOV_DEG)
    f, cx, cy = intr.fx, intr.cx, intr.cy
    d, h = 6.0, 1.1

    # A level camera at (-d, 0, h) looking straight along +X at (0, 0, h).
    # By hand: image right is -Y (stand behind the camera: world +Y is to
    # its left), image down is -Z. A world point (px, py, pz) is at depth
    # (px + d), so u = cx - f*py/(px+d) and v = cy - f*(pz-h)/(px+d).
    def hand_uv(px, py, pz):
        depth = px + d
        return cx - f * py / depth, cy - f * (pz - h) / depth

    extr1 = mv.look_at_extrinsics((-d, 0.0, h), (0.0, 0.0, h))
    p1 = mv.projection_matrix(intr, extr1)
    worst = 0.0
    for pt in [(1.0, 0.5, h + 0.3), (0.0, -0.8, h - 0.4), (2.0, 0.0, h)]:
        got = mv.project_point(p1, pt)
        exp = hand_uv(*pt)
        worst = max(worst, abs(got[0] - exp[0]), abs(got[1] - exp[1]))
    check("projector matches hand-derived pinhole", worst < 1e-9,
          f"worst error {worst:.2e} px (tol 1e-9)")

    # Second camera at (0, -d, h) looking along +Y: by the same hand
    # argument its u = cx + f*px/(py+d), v = cy - f*(pz-h)/(py+d). Feed the
    # triangulator pixels computed from THESE formulas — not from
    # project_point — and it must return the world point.
    extr2 = mv.look_at_extrinsics((0.0, -d, h), (0.0, 0.0, h))
    p2 = mv.projection_matrix(intr, extr2)
    target = (0.3, 0.2, 1.4)
    uv1 = hand_uv(*target)
    uv2 = (cx + f * target[0] / (target[1] + d), cy - f * (target[2] - h) / (target[1] + d))
    got = mv.triangulate_point([(p1, uv1[0], uv1[1], 1.0), (p2, uv2[0], uv2[1], 1.0)])
    err = float(np.linalg.norm(np.asarray(got[0]) - np.asarray(target))) if got else float("inf")
    check("triangulation matches hand-derived intersection", err < 1e-9,
          f"error {err:.2e} m (tol 1e-9), reproj {got[1]:.2e} px" if got else "solver returned None")

    # Hip-shoulder separation closed form: pelvis azimuth 30, thorax -12,
    # separation exactly 42.
    hip_r = np.array([0.0, 0.0, 1.0])
    hip_l = hip_r + HIP_W_M * np.array([math.cos(math.radians(30.0)),
                                        math.sin(math.radians(30.0)), 0.0])
    sh_r = np.array([0.0, 0.0, 1.45])
    sh_l = sh_r + SHOULDER_W_M * np.array([math.cos(math.radians(-12.0)),
                                           math.sin(math.radians(-12.0)), 0.0])
    hss = mv.hip_shoulder_separation_deg(hip_l, hip_r, sh_l, sh_r)
    check("hip-shoulder separation closed form", hss is not None and abs(hss - 42.0) < 1e-9,
          f"got {hss:.12f} deg, truth 42 (tol 1e-9)")


def check_clock_fit(check, rng: np.random.Generator) -> None:
    """Synthetic ping storm with MultipeerConnectivity-shaped delays: a few-ms
    floor and a vicious tail. The min-RTT filter plus Theil-Sen must recover
    offset and skew despite the tail."""
    n = 150
    t_send = np.sort(rng.uniform(0.0, 20.0, n))
    d1 = 0.0018 + rng.lognormal(math.log(0.0006), 1.2, n)
    d2 = 0.0018 + rng.lognormal(math.log(0.0006), 1.2, n)
    proc = 0.0003
    true_off, true_skew = 0.1375, 20e-6

    def worker_clock(t):
        return (1.0 + true_skew) * t + true_off

    t1 = t_send
    t2 = worker_clock(t_send + d1)
    t3 = worker_clock(t_send + d1 + proc)
    t4 = t_send + d1 + proc + d2

    model = mv.fit_clock_model(t1, t2, t3, t4)
    ok = model is not None
    if ok:
        # Judge the model by what it is FOR: map a worker stamp back to the
        # master timeline and measure the round-trip error at both ends of
        # the session.
        errs = [abs(mv.map_clock_s(worker_clock(t), model) - t) for t in (0.0, 10.0, 20.0)]
        map_err = max(errs)
        skew_err = abs(model.skew - true_skew / (1.0 + true_skew))
        ok = map_err <= 300e-6 and skew_err <= 5e-6
        check("clock fit through a heavy-tailed network", ok,
              f"map err {map_err*1e6:.0f} us (tol 300), skew err {skew_err*1e6:.2f} ppm "
              f"(tol 5), kept {model.n_used}/{n}, rtt_min {model.rtt_min_s*1e3:.2f} ms")
    else:
        check("clock fit through a heavy-tailed network", False, "fit returned None")


def check_resampler(check) -> None:
    ts = np.arange(0.0, 2.0, 1.0 / FPS)
    vs = np.sin(2.0 * math.pi * 1.0 * ts)
    grid = ts[:-1] + 0.0021
    out = mv.pchip_resample(ts, vs, grid)
    err = float(np.nanmax(np.abs(out - np.sin(2.0 * math.pi * grid))))
    check("resampler accuracy on a smooth curve", err <= 1e-4,
          f"max err {err:.2e} of amplitude 1 (tol 1e-4)")

    mono = np.array([_sigmoid((t - 1.0) / 0.05) for t in ts])
    out2 = mv.pchip_resample(ts, mono, grid)
    dmin = float(np.nanmin(np.diff(out2[np.isfinite(out2)])))
    check("resampler preserves monotonicity (no overshoot)", dmin >= -1e-9,
          f"min consecutive step {dmin:.2e}")

    gappy = vs.copy()
    cut = (ts > 0.90) & (ts < 0.96)
    us_g, _vs_g, _ws_g, had_gap = mv.resample_view(
        np.where(cut, np.nan, ts), np.where(cut, np.nan, vs),
        np.where(cut, np.nan, vs), np.where(cut, np.nan, 0.9 * np.ones_like(vs)), grid)
    inside = (grid > 0.905) & (grid < 0.955)
    check("dropouts come back absent, not bridged",
          had_gap and bool(np.all(np.isnan(us_g[inside]))),
          f"had_gap={had_gap}, NaN inside gap: {bool(np.all(np.isnan(us_g[inside])))}")


# --- End-to-end: encoded clips through the production 2D pipeline ------------

E2E_TARGET = np.array([0.0, 0.0, 1.60])
E2E_LAUNCH = np.array([-2.40, 0.0, 0.90])
E2E_CONTACT_FRAME = 30
E2E_FRAMES = 110


def e2e_ball_positions(n: int):
    """Drag-integrated flight from E2E_LAUNCH, world metres, per frame."""
    ev = TRUE_EV_MPH / sla.MPH_PER_MPS
    la, sp = math.radians(TRUE_LA_DEG), math.radians(TRUE_SPRAY_DEG)
    v = np.array([ev * math.cos(la) * math.cos(sp),
                  ev * math.cos(la) * math.sin(sp),
                  ev * math.sin(la)])
    k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD
                * math.pi * (sla.BALL_DIAMETER_M / 2.0) ** 2 / sla.BALL_MASS_KG)
    p = E2E_LAUNCH.astype(float).copy()
    dt = 1.0 / (FPS * 10.0)
    out = []
    for _ in range(n):
        out.append(p.copy())
        for _ in range(10):
            a = np.array([0.0, 0.0, -sla.G]) - k_over_m * np.linalg.norm(v) * v
            v = v + a * dt
            p = p + v * dt
    return out


def render_e2e_clip(path: str, intr, extr) -> None:
    """synth_test.py's rendering recipe, aimed by a real projection matrix:
    grassy gradient, fence posts, seeded sensor noise, and the ball as an
    ellipse smeared along its image velocity. Encoding is part of the test —
    the compression halo is exactly what the sub-pixel diameter fights."""
    rng = np.random.default_rng(7)
    yy = np.linspace(0, 1, H, dtype=np.float32)[:, None]
    base = np.zeros((H, W, 3), np.uint8)
    base[:, :, 0] = (40 + 30 * yy).astype(np.uint8)
    base[:, :, 1] = (95 + 40 * yy).astype(np.uint8)
    base[:, :, 2] = (55 + 25 * yy).astype(np.uint8)
    for x in range(0, W, 160):
        cv2.line(base, (x, 0), (x, H), (35, 60, 40), 5)

    vw = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 60.0, (W, H))
    if not vw.isOpened():
        raise IOError("VideoWriter failed to open (mp4v)")

    p_mat = mv.projection_matrix(intr, extr)
    flight = e2e_ball_positions(E2E_FRAMES)
    r_wc = extr.r
    for fidx in range(E2E_FRAMES):
        frame = base.copy()
        noise = rng.integers(-6, 7, (H, W, 1), dtype=np.int16)
        frame = np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        if fidx >= E2E_CONTACT_FRAME:
            p3 = flight[fidx - E2E_CONTACT_FRAME]
            uv = mv.project_point(p_mat, p3)
            if uv is not None and 0 <= uv[0] < W and 0 <= uv[1] < H:
                depth = float((r_wc @ p3 + extr.t)[2])
                d_px = sla.BALL_DIAMETER_M * intr.fx / depth
                nxt = flight[min(fidx - E2E_CONTACT_FRAME + 1, len(flight) - 1)]
                uv2 = mv.project_point(p_mat, nxt)
                if uv2 is not None:
                    vel = (np.array(uv2) - np.array(uv)) * FPS
                    smear = float(np.linalg.norm(vel)) * E2E_SHUTTER_S
                    ang = math.degrees(math.atan2(vel[1], vel[0]))
                else:
                    smear, ang = 0.0, 0.0
                axes = (int(round((d_px + smear) / 2)), int(round(d_px / 2)))
                if min(axes) >= 2:
                    cv2.ellipse(frame, (int(round(uv[0])), int(round(uv[1]))),
                                axes, ang, 0, 360, BALL_BGR, -1)
        vw.write(frame)
    vw.release()


def run_2d_pipeline(path: str):
    """The identical production per-view chain synth_test.py exercises."""
    cap = cv2.VideoCapture(path)
    per_frame = {}
    idx = 0
    prev_gray = None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fg = sla.motion_mask(gray, prev_gray)
        prev_gray = gray
        if fg is not None:
            cands = sla.detect_ball_candidates(frame, idx, idx / FPS, fg_mask=fg)
            if cands:
                per_frame[idx] = cands
        idx += 1
    cap.release()
    tracks = sla.build_tracks(per_frame, FPS)
    return sla.select_outbound_track(tracks, FPS)


def e2e_ball_check(check) -> None:
    os.makedirs("out", exist_ok=True)
    intr = mv.CameraIntrinsics.from_fov(W, H, FOV_DEG)
    cams = {}
    for label, az in (("A", CAM_A_AZ_DEG), ("B", CAM_B_AZ_DEG)):
        pos = cam_position(az, CAM_DIST_M, CAM_H_M, E2E_TARGET)
        extr = mv.look_at_extrinsics(pos, E2E_TARGET)
        path = os.path.join("out", f"multiview_{label}.mp4")
        render_e2e_clip(path, intr, extr)
        track = run_2d_pipeline(path)
        cams[label] = (extr, track)
        n = len(track) if track else 0
        print(f"    view {label}: production 2D pipeline tracked "
              f"{n} frames from the encoded clip")

    if any(t is None or len(t) < sla.MIN_TRACK_FRAMES for _e, t in cams.values()):
        check("e2e two-view ball (encoded clips)", False, "a view lost the ball")
        return

    # Both clips share one timeline here (same phase, no clock error): the
    # e2e case isolates detector + geometry; clocks are exercised at
    # observation level above.
    t_grid = np.arange(E2E_CONTACT_FRAME / FPS + 1.0 / FPS,
                       (E2E_CONTACT_FRAME + 55) / FPS, 1.0 / FPS)
    views, had_gap = [], False
    for label, (extr, track) in cams.items():
        ts = np.array([o.t for o in track])
        us = np.array([o.x for o in track])
        vs = np.array([o.y for o in track])
        ws = np.ones_like(ts)
        us_g, vs_g, ws_g, gap = mv.resample_view(ts, us, vs, ws, t_grid)
        had_gap = had_gap or gap
        views.append(mv.ViewTrack2D(mv.projection_matrix(intr, extr), us_g, vs_g, ws_g))
    track3d = mv.triangulate_series(t_grid, views, had_gap=had_gap)

    launch = mv.launch_metrics_3d(t_grid, track3d.xyz, E2E_CONTACT_FRAME / FPS)
    g_est = mv.gravity_magnitude_3d(t_grid, track3d.xyz)
    if launch is None:
        check("e2e two-view ball (encoded clips)", False, "launch fit failed")
        return
    ev_err = launch.ev_mph / TRUE_EV_MPH - 1.0
    la_err = launch.la_deg - TRUE_LA_DEG
    spray_err = launch.spray_deg - TRUE_SPRAY_DEG
    print(f"    e2e truth   : EV {TRUE_EV_MPH:.1f} mph  LA {TRUE_LA_DEG:.1f} deg  "
          f"spray {TRUE_SPRAY_DEG:.1f} deg  |g| {sla.G:.3f}")
    print(f"    e2e measured: EV {launch.ev_mph:.1f} mph  LA {launch.la_deg:.2f} deg  "
          f"spray {launch.spray_deg:.2f} deg  |g| {g_est if g_est else float('nan'):.3f}  "
          f"(coverage {track3d.coverage*100:.0f}%, median reproj "
          f"{np.nanmedian(track3d.reproj_rms_px):.2f} px)")
    check("e2e exit velocity (3D, no scale step)", abs(ev_err) <= 0.03,
          f"err {ev_err*100:+.1f}% (tol 3%)")
    check("e2e launch angle (3D)", abs(la_err) <= 1.5,
          f"err {la_err:+.2f} deg (tol 1.5)")
    check("e2e spray angle — the metric one camera cannot see", abs(spray_err) <= 2.0,
          f"err {spray_err:+.2f} deg (tol 2.0)")
    ok_g = g_est is not None and abs(g_est / sla.G - 1.0) <= 0.03
    check("e2e 3D gravity witness (drag-aware, scale-free)", ok_g,
          f"|g| {g_est:.3f} vs {sla.G:.3f} ({(g_est/sla.G-1)*100:+.1f}%, tol 3%)"
          if g_est else "not computed")


# --- The sweep: the error budget ---------------------------------------------

def sweep(scene: Scene, out_csv: str) -> None:
    seps = [30.0, 45.0, 60.0, 75.0, 90.0, 110.0, 120.0]
    sync_ms = [0.0, 0.5, 1.0, 2.0, 4.0]
    az_errs = [0.0, 0.25, 0.5, 1.0, 2.0]
    rs_modes = [("off", 0.0, True), ("uncorrected", mv.T_READOUT_DEFAULT_S, False),
                ("corrected", mv.T_READOUT_DEFAULT_S, True)]
    rows = ["sep_deg,sync_err_ms,az_err_deg,rs_mode,"
            "hss_peak_err_deg,hss_rmse_deg,joint_rmse_mm,battip_rmse_mm,"
            "ev_err_mph,la_err_deg"]
    total = len(seps) * len(sync_ms) * len(az_errs) * len(rs_modes)
    done = 0
    for sep in seps:
        for sync in sync_ms:
            for az in az_errs:
                for rs_name, readout, correct in rs_modes:
                    cfg = RunCfg(sep_deg=sep, noise_px=3.0, conf_dips=True,
                                 clock_est_err_s=sync / 1000.0, az_err_deg=az,
                                 pos_err_m=0.02 if az > 0 else 0.0,
                                 readout_s=readout, correct_readout=correct)
                    res = run_reconstruction(scene, cfg)
                    pk_m = hss_peak_est(res.t_grid, res.hss_meas)
                    pk_t = hss_peak_est(res.t_grid, res.hss_true)
                    pk_err = (abs(pk_m[1] - pk_t[1])
                              if pk_m and pk_t else float("nan"))
                    ev_err = (res.launch.ev_mph - TRUE_EV_MPH
                              if res.launch else float("nan"))
                    la_err = (res.launch.la_deg - TRUE_LA_DEG
                              if res.launch else float("nan"))
                    rows.append(f"{sep:.0f},{sync:.1f},{az:.2f},{rs_name},"
                                f"{pk_err:.2f},{hss_rmse_deg(res):.2f},"
                                f"{track_rmse_m(scene, res, BODY_NAMES)*1000:.1f},"
                                f"{track_rmse_m(scene, res, ['bat_tip'])*1000:.1f},"
                                f"{ev_err:.2f},{la_err:.2f}")
                    done += 1
                    if done % 25 == 0:
                        print(f"  sweep {done}/{total}")
    with open(out_csv, "w") as f:
        f.write("\n".join(rows) + "\n")
    print(f"wrote {out_csv} ({total} configurations)")


# --- Self-test ---------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sweep", action="store_true",
                    help="write the sync x calibration x separation x shutter "
                         "error budget to out/multiview_budget.csv (slow)")
    args = ap.parse_args()

    os.makedirs("out", exist_ok=True)
    scene = Scene()

    if args.sweep:
        sweep(scene, os.path.join("out", "multiview_budget.csv"))
        return

    checks = []

    def check(name, ok, detail):
        checks.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    print("independent geometry (hand-derived, shares no code with the projector):")
    independent_checks(check)
    check_clock_fit(check, np.random.default_rng(3))
    check_resampler(check)

    # -- clean reconstruction: everything known, tiny noise ------------------
    clean = run_reconstruction(scene, RunCfg(noise_px=0.3))
    pk_true = hss_peak_est(clean.t_grid, clean.hss_true)
    pk_clean = hss_peak_est(clean.t_grid, clean.hss_meas)
    print(f"\ntruth   : HSS peak {TRUE_HSS_PEAK_DEG:.1f} deg at t {HSS_PEAK_T:.3f}  "
          f"EV {TRUE_EV_MPH:.1f} mph  LA {TRUE_LA_DEG:.1f} deg")
    if pk_clean and clean.launch:
        print(f"clean   : HSS peak {pk_clean[1]:.2f} deg at t {pk_clean[0]:.3f}  "
              f"EV {clean.launch.ev_mph:.1f} mph  LA {clean.launch.la_deg:.2f} deg  "
              f"joints {track_rmse_m(scene, clean, BODY_NAMES)*1000:.1f} mm rms")
    check("peak estimator sane on the true curve",
          pk_true is not None and abs(pk_true[1] - TRUE_HSS_PEAK_DEG) <= 2.5,
          f"estimator reads the truth as {pk_true[1]:.2f} deg (tol 2.5 of "
          f"{TRUE_HSS_PEAK_DEG})" if pk_true else "no peak found")
    jr = track_rmse_m(scene, clean, BODY_NAMES)
    check("clean reconstruction: joints", jr <= 0.008, f"rms {jr*1000:.2f} mm (tol 8)")
    ok_pk = pk_clean is not None and pk_true is not None
    pk_err = abs(pk_clean[1] - pk_true[1]) if ok_pk else float("inf")
    check("clean reconstruction: HSS peak", pk_err <= 1.0,
          f"err {pk_err:.2f} deg vs same estimator on truth (tol 1.0)")
    ev_ok = clean.launch is not None
    check("clean reconstruction: EV",
          ev_ok and abs(clean.launch.ev_mph / TRUE_EV_MPH - 1.0) <= 0.015,
          f"err {(clean.launch.ev_mph/TRUE_EV_MPH-1)*100:+.1f}% (tol 1.5%)"
          if ev_ok else "no launch fit")
    check("clean reconstruction: LA",
          ev_ok and abs(clean.launch.la_deg - TRUE_LA_DEG) <= 0.8,
          f"err {clean.launch.la_deg - TRUE_LA_DEG:+.2f} deg (tol 0.8)"
          if ev_ok else "no launch fit")

    # -- realistic reconstruction: the accuracy-table row --------------------
    real = run_reconstruction(scene, RunCfg(
        noise_px=3.0, conf_dips=True, clock_est_err_s=0.001,
        az_err_deg=0.5, pos_err_m=0.02,
        readout_s=mv.T_READOUT_DEFAULT_S, correct_readout=True))
    pk_real = hss_peak_est(real.t_grid, real.hss_meas)
    pk_rt = hss_peak_est(real.t_grid, real.hss_true)
    jr_r = track_rmse_m(scene, real, BODY_NAMES)
    if pk_real and real.launch:
        print(f"realistic: HSS peak {pk_real[1]:.2f} deg  "
              f"HSS rmse {hss_rmse_deg(real):.2f} deg  "
              f"EV {real.launch.ev_mph:.1f} mph  LA {real.launch.la_deg:.2f} deg  "
              f"joints {jr_r*1000:.1f} mm rms")
    check("realistic (1 ms clock, 0.5 deg + 2 cm calib, 3 px noise, RS "
          "corrected): joints", jr_r <= 0.055, f"rms {jr_r*1000:.1f} mm (tol 55)")
    ok = pk_real is not None and pk_rt is not None
    check("realistic: HSS peak",
          ok and abs(pk_real[1] - pk_rt[1]) <= 6.0,
          f"err {abs(pk_real[1]-pk_rt[1]):.2f} deg (tol 6.0)" if ok else "no peak")
    check("realistic: HSS curve", hss_rmse_deg(real) <= 10.0,
          f"rmse {hss_rmse_deg(real):.2f} deg (tol 10)")
    ok = real.launch is not None
    check("realistic: EV", ok and abs(real.launch.ev_mph - TRUE_EV_MPH) <= 3.0,
          f"err {real.launch.ev_mph - TRUE_EV_MPH:+.2f} mph (tol 3)" if ok else "no fit")
    check("realistic: LA", ok and abs(real.launch.la_deg - TRUE_LA_DEG) <= 2.5,
          f"err {real.launch.la_deg - TRUE_LA_DEG:+.2f} deg (tol 2.5)" if ok else "no fit")

    # -- sync sensitivity ----------------------------------------------------
    base = run_reconstruction(scene, RunCfg(noise_px=0.0))
    sync4 = run_reconstruction(scene, RunCfg(noise_px=0.0, clock_est_err_s=0.004))
    sync1 = run_reconstruction(scene, RunCfg(noise_px=0.0, clock_est_err_s=0.001))
    bt0 = track_rmse_m(scene, base, ["bat_tip"])
    bt4 = track_rmse_m(scene, sync4, ["bat_tip"])
    check("sync error is visible where it must be (bat tip)", bt4 >= 2.0 * bt0,
          f"bat-tip rms {bt0*1000:.1f} mm at 0 -> {bt4*1000:.1f} mm at 4 ms")
    pk0 = hss_peak_est(base.t_grid, base.hss_meas)
    pk1 = hss_peak_est(sync1.t_grid, sync1.hss_meas)
    ok = pk0 is not None and pk1 is not None
    check("1 ms of clock error barely moves HSS (slow joints forgive)",
          ok and abs(pk1[1] - pk0[1]) <= 1.0,
          f"HSS peak shift {abs(pk1[1]-pk0[1]):.2f} deg (tol 1.0)" if ok else "no peak")

    # -- rolling shutter -----------------------------------------------------
    rs_off = run_reconstruction(scene, RunCfg(noise_px=0.0))
    rs_raw = run_reconstruction(scene, RunCfg(
        noise_px=0.0, readout_s=mv.T_READOUT_DEFAULT_S, correct_readout=False))
    rs_fix = run_reconstruction(scene, RunCfg(
        noise_px=0.0, readout_s=mv.T_READOUT_DEFAULT_S, correct_readout=True))
    a = track_rmse_m(scene, rs_off, ["bat_tip"])
    b = track_rmse_m(scene, rs_raw, ["bat_tip"])
    c = track_rmse_m(scene, rs_fix, ["bat_tip"])
    recovered = (b - c) / (b - a) if b > a else float("nan")
    check("rolling-shutter correction recovers the bat tip",
          b > a and recovered >= 0.70,
          f"bat-tip rms: shutter off {a*1000:.1f} mm, uncorrected {b*1000:.1f} mm, "
          f"corrected {c*1000:.1f} mm ({recovered*100:.0f}% recovered, need 70%)")

    # -- camera separation ---------------------------------------------------
    wide = run_reconstruction(scene, RunCfg(sep_deg=90.0, noise_px=2.0))
    narrow = run_reconstruction(scene, RunCfg(sep_deg=30.0, noise_px=2.0))
    d90 = depth_rmse_m(scene, wide, BODY_NAMES)
    d30 = depth_rmse_m(scene, narrow, BODY_NAMES)
    check("90 deg separation beats 30 deg on the depth axis", d90 <= 0.6 * d30,
          f"depth rms {d90*1000:.1f} mm at 90 vs {d30*1000:.1f} mm at 30")

    # -- occlusion honesty ---------------------------------------------------
    occ = run_reconstruction(scene, RunCfg(
        noise_px=0.3,
        occl_a={"right_hip": (CONTACT_T - 0.15, CONTACT_T + 0.10)}))
    tr = occ.tracks["right_hip"]
    window = (occ.t_grid >= CONTACT_T - 0.145) & (occ.t_grid <= CONTACT_T + 0.095)
    absent = bool(np.all(np.isnan(tr.xyz[window])))
    hss_absent = bool(np.all(np.isnan(occ.hss_meas[window])))
    check("occluded trail hip is ABSENT, never interpolated",
          absent and hss_absent and mv.FLAG3D_LOW_COVERAGE in tr.flags,
          f"3D absent in window: {absent}, HSS absent: {hss_absent}, "
          f"flags {tr.flags} (coverage {tr.coverage*100:.0f}%)")

    # -- the long way round: encoded video through the production detector ---
    print("\nend-to-end (two encoded clips, production 2D pipeline per view):")
    e2e_ball_check(check)

    print()
    if all(checks):
        print("ALL PASS — the multiview reference reconstructs a known swing.")
        sys.exit(0)
    print("SOME CHECKS FAILED — see above.")
    sys.exit(1)


if __name__ == "__main__":
    main()
