# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
sla_multiview.py — reference implementation for SwingLab Pro's multi-phone 3D
reconstruction. Second source-of-truth module under the same law as
sla_common.py: the math lives here first, gets fixtures
(gen_parity_multiview.py, arriving with the first Swift port), and the Swift
in app/SourcesPro/Core3D/ is a port pinned number-for-number. It is a second
file rather than an extension of sla_common.py because the existing
parity.json is decoded by a non-optional struct in the *shipping* test
target — extending it would drag the 3D port into the shipping app. See
docs/SWINGLAB_PRO.md.

Every public symbol is tagged in its docstring:

  [PARITY] — destined for the Swift port and fixture pinning.
  [SPIKE]  — Python-side tooling only; never ported.

Shared physics constants are IMPORTED from sla_common, never restated: one
number, one home.

Conventions (the sign errors live here, so they are spelled out):

  World frame   metres, right-handed, +Z up, origin at the resting ball both
                phones tapped during setup. +X points out toward the field in
                the primary hit direction; +Y completes the frame (to the
                left when looking out along +X). Gravity is (0, 0, -G).
  Camera frame  +X right, +Y down, +Z forward along the optical axis. Y-down
                keeps image coordinates in sla_common's convention: u right,
                v down, in pixels.
  Azimuth       of a horizontal direction: degrees(atan2(y, x)) — 0 along
                +X, increasing toward +Y (counterclockwise seen from above).
  Time          seconds. Every function's docstring says whose clock it
                expects; "master clock" is the reconstruction timeline.
  Clocks        a worker phone's clock is modelled as offset + skew relative
                to the master. `fit_clock_model` measures it from ping
                exchanges; `map_clock_s` converts worker timestamps onto the
                master timeline. The mapping direction is pinned by the
                synthetic self-test, because this is exactly the algebra a
                sign flip survives review in.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

import sla_common as sla

# --- Sync budgets -----------------------------------------------------------
# 1 ms of clock error moves a 30 m/s bat head 30 mm — about the floor set by
# 2D pose noise. Below SYNC_BUDGET_S sync stops being the dominant error;
# above SYNC_DEGRADED_S the app must gate 3D metrics (ProCaptureFlag
# .syncDegraded uses this number, which is why it lives here and not there).
SYNC_BUDGET_S = 0.001                # [PARITY]
SYNC_DEGRADED_S = 0.003              # [PARITY]

# Rolling-shutter readout at 1080p240 is close to the entire 4.17 ms frame
# period: the bottom of the frame is nearly a frame older than the top. The
# per-model measured value replaces this default in the app; the correction
# itself is rs_row_delay_s, folded into each observation's timestamp.
T_READOUT_DEFAULT_S = 0.004          # [PARITY]

# Camera separation. Below ~30 deg the depth axis is unconstrained; past
# ~110-120 deg with two cameras the pose estimator starts disagreeing about
# which side of the body it sees. 90 is the sweet spot in the markerless
# literature (and matches BIOMECHANICS.md's "45-90 deg" note per camera).
CAM_SEP_MIN_DEG = 60.0               # [PARITY]
CAM_SEP_IDEAL_DEG = 90.0             # [PARITY]
CAM_SEP_MAX_DEG = 110.0              # [PARITY]

MIN_VIEWS = 2                        # [PARITY] triangulation needs two rays
REPROJ_RMS_MAX_PX = 3.0              # [PARITY] calibration + per-swing acceptance
SCALE_CHECK_TOL = 0.05               # [PARITY] known-geometry check tolerance
PLATE_WIDTH_M = 0.4318               # [PARITY] home plate, 17 in across
COVERAGE_MIN_3D = 0.60               # [PARITY] below this a 3D track is flagged
RESAMPLE_MAX_GAP_S = 0.05            # [PARITY] larger gaps are absent, not bridged
SEGMENT_AZIMUTH_MIN_HORIZ = 0.2      # [PARITY] near-vertical segments have no azimuth
# Curvature needs time. Imported rather than restated, and deliberately NOT
# a looser number than the 2D path uses: triangulating changes where the
# positions come from, not how long a parabola must be watched before its
# quadratic term is conditioned. The synthetic drop rehearsal reads g 5% low
# over a 0.18 s window and correctly over 0.30 s, which is the same thing
# docs/VALIDATION.md's G0 runs found by fitting sliding windows on a real
# fall — the early ones are ill-posed and must not be reported.
GRAVITY3D_MIN_SPAN_S = sla.MIN_GRAVITY_TRACK_S   # [PARITY] 0.20 s
LAUNCH3D_MIN_SAMPLES = 8             # [PARITY] mirrors MIN_TRACK_FRAMES's intent
MIN_RTT_KEEP_FACTOR = 1.25           # [PARITY] ping filter: keep near-minimum RTT

# 3D measurement flags. Parity-pinned strings like SwingFlag's, appended in
# the fixed order ONE_VIEW_ONLY, LOW_COVERAGE_3D, HIGH_REPROJECTION,
# RESAMPLE_GAP (the fixture tests will assert the order, like SwingFlag's).
# App-only conditions (peer lost, rig moved) belong in ProCaptureFlag, not
# here — this module can only flag what it can compute from its inputs.
FLAG3D_ONE_VIEW = "ONE_VIEW_ONLY"            # [PARITY]
FLAG3D_LOW_COVERAGE = "LOW_COVERAGE_3D"      # [PARITY]
FLAG3D_HIGH_REPROJECTION = "HIGH_REPROJECTION"  # [PARITY]
FLAG3D_RESAMPLE_GAP = "RESAMPLE_GAP"         # [PARITY]


def wrap180(deg: float) -> float:
    """[PARITY] Wrap an angle difference into (-180, 180]."""
    wrapped = math.fmod(deg + 180.0, 360.0)
    if wrapped <= 0.0:
        wrapped += 360.0
    return wrapped - 180.0


# --- Camera model -----------------------------------------------------------

@dataclass
class CameraIntrinsics:
    """[PARITY] Pinhole intrinsics, pixels. fx/fy from the format's FOV (the
    same source TiltRectifier uses); square pixels assumed until the
    per-model intrinsics table says otherwise."""
    fx: float
    fy: float
    cx: float
    cy: float
    width_px: int
    height_px: int

    @staticmethod
    def from_fov(width_px: int, height_px: int, fov_deg: float) -> "CameraIntrinsics | None":
        f = sla.focal_px_from_fov(float(width_px), fov_deg)
        if f <= 0.0:
            return None
        return CameraIntrinsics(f, f, width_px / 2.0, height_px / 2.0,
                                int(width_px), int(height_px))


@dataclass
class CameraExtrinsics:
    """[PARITY] World-to-camera transform: X_cam = r @ X_world + t."""
    r: np.ndarray  # (3,3)
    t: np.ndarray  # (3,)


def look_at_extrinsics(cam_pos, target, up=(0.0, 0.0, 1.0)) -> CameraExtrinsics | None:
    """[PARITY] Extrinsics for a camera at `cam_pos` aimed at `target`.

    Rows of r are the camera axes expressed in world coordinates:
    x (image right), y (image DOWN — matching sla_common's y-down images),
    z (optical axis, toward the target). With +Z-up world and a mostly
    horizontal view, x = normalize(z_axis x up) points right and
    y = z_axis x x points down; both cross products were checked by hand and
    are re-checked against hand-derived image coordinates in
    synth_multiview's independent checks — the round trip through
    project_point alone could not catch a swapped row.

    Returns None when the view direction is (anti)parallel to `up`: a camera
    pointing straight down has no defined "image right".
    """
    pos = np.asarray(cam_pos, dtype=float)
    z = np.asarray(target, dtype=float) - pos
    nz = np.linalg.norm(z)
    if nz < 1e-12:
        return None
    z = z / nz
    x = np.cross(z, np.asarray(up, dtype=float))
    nx = np.linalg.norm(x)
    if nx < 1e-9:
        return None
    x = x / nx
    y = np.cross(z, x)
    r = np.vstack([x, y, z])
    return CameraExtrinsics(r=r, t=-(r @ pos))


def projection_matrix(intr: CameraIntrinsics, extr: CameraExtrinsics) -> np.ndarray:
    """[PARITY] 3x4 projection P = K [R|t]."""
    k = np.array([[intr.fx, 0.0, intr.cx],
                  [0.0, intr.fy, intr.cy],
                  [0.0, 0.0, 1.0]])
    rt = np.hstack([extr.r, extr.t.reshape(3, 1)])
    return k @ rt


def project_point(p: np.ndarray, xyz) -> tuple[float, float] | None:
    """[PARITY] Project a world point through P. None when at/behind the
    camera plane — a point you cannot see must not produce pixels."""
    v = np.asarray(xyz, dtype=float)
    h = p @ np.array([v[0], v[1], v[2], 1.0])
    if h[2] <= 1e-9:
        return None
    return float(h[0] / h[2]), float(h[1] / h[2])


def rs_row_delay_s(y_px: float, height_px: float, readout_s: float) -> float:
    """[PARITY] Rolling-shutter delay of an observation at image row y.

    The sensor reads top row first; a detection at row y was exposed
    (y/height)*readout after the frame's timestamp. Added to the frame PTS
    before resampling, this removes a 5-9 cm bat/ball error at 240fps.
    Clamped so a slightly out-of-frame centroid cannot produce a delay
    outside the physical readout window.
    """
    if height_px <= 0.0 or readout_s <= 0.0:
        return 0.0
    frac = min(max(y_px / height_px, 0.0), 1.0)
    return frac * readout_s


# --- Cross-device clock model ----------------------------------------------

@dataclass
class ClockModel:
    """[PARITY] Worker clock relative to master.

    offset_s is (worker - master) measured at worker time t_ref_s; skew is
    its rate of change (s/s). Master time for a worker stamp t_w is
    t_w - (offset_s + skew*(t_w - t_ref_s)). ci_s is a robust half-width of
    the fit residuals — informational for the sync HUD, not part of the map.
    """
    offset_s: float
    skew: float
    t_ref_s: float
    rtt_min_s: float
    n_used: int
    ci_s: float


def map_clock_s(t_remote: float, model: ClockModel) -> float:
    """[PARITY] Worker timestamp -> master timeline. See ClockModel."""
    return t_remote - (model.offset_s + model.skew * (t_remote - model.t_ref_s))


def fit_clock_model(t1, t2, t3, t4) -> ClockModel | None:
    """[PARITY] Fit offset + skew from NTP-style ping exchanges.

    t1: master send, t2: worker receive, t3: worker reply, t4: master
    receive (t1,t4 on the master clock; t2,t3 on the worker clock). Each
    exchange yields offset ((t2-t1)+(t3-t4))/2 and RTT (t4-t1)-(t3-t2).

    Only near-minimum-RTT exchanges are kept: MultipeerConnectivity's median
    round trip is a few ms but its tail reaches hundreds, and a delayed ping
    is not slightly wrong, it is garbage — averaging it in would be. Skew
    comes from a Theil-Sen fit (median of pairwise slopes) over the kept
    offsets: one more bad sample must move the answer by roughly nothing,
    because there is no operator watching for outliers at the field.
    """
    t1 = np.asarray(t1, dtype=float)
    t2 = np.asarray(t2, dtype=float)
    t3 = np.asarray(t3, dtype=float)
    t4 = np.asarray(t4, dtype=float)
    if not (t1.size == t2.size == t3.size == t4.size) or t1.size < 2:
        return None

    rtt = (t4 - t1) - (t3 - t2)
    off = ((t2 - t1) + (t3 - t4)) / 2.0
    tau = (t2 + t3) / 2.0                       # worker-clock abscissa

    valid = rtt >= 0.0
    if valid.sum() < 2:
        return None
    rtt, off, tau = rtt[valid], off[valid], tau[valid]

    rtt_min = float(rtt.min())
    # The +1e-6 keeps the multiplicative window from collapsing to a single
    # sample when rtt_min is ~0 (loopback, synthetic tests).
    keep = rtt <= rtt_min * MIN_RTT_KEEP_FACTOR + 1e-6
    offk, tauk = off[keep], tau[keep]

    if offk.size >= 2 and float(tauk.max() - tauk.min()) > 1e-9:
        dt = tauk[None, :] - tauk[:, None]
        dv = offk[None, :] - offk[:, None]
        pair = dt > 1e-9
        skew = float(np.median(dv[pair] / dt[pair])) if pair.any() else 0.0
    else:
        skew = 0.0

    t_ref = float(np.median(tauk))
    resid_base = offk - skew * (tauk - t_ref)
    offset = float(np.median(resid_base))
    ci = 1.4826 * float(np.median(np.abs(resid_base - offset)))
    return ClockModel(offset_s=offset, skew=skew, t_ref_s=t_ref,
                      rtt_min_s=rtt_min, n_used=int(offk.size), ci_s=ci)


# --- Resampling onto a common timeline --------------------------------------

def pchip_resample(ts, vs, t_grid, max_gap_s: float = RESAMPLE_MAX_GAP_S) -> np.ndarray:
    """[PARITY] Monotone cubic (Fritsch-Carlson) resampling with honest gaps.

    Two free-running sensors interleave with a uniformly random +-half-frame
    phase; no pairing of "frame k with frame k" fixes that, so each camera's
    track is resampled onto one shared grid before triangulation. Monotone
    cubic rather than a plain spline because a spline overshoots at the very
    place we care most about — the velocity spike through contact — and an
    overshoot there is an invented bat speed.

    Grid points outside the samples, or falling inside a sample gap wider
    than max_gap_s, come back NaN: a dropout is absent, not bridged.
    Hand-rolled (~50 lines) rather than scipy so the Swift port is a
    transliteration of code we own. Endpoint slopes use the one-sided secant
    (the "simple" shape-preserving variant) — pinned by fixtures, so the
    port cannot silently pick a different endpoint rule.
    """
    ts = np.asarray(ts, dtype=float)
    vs = np.asarray(vs, dtype=float)
    t_grid = np.asarray(t_grid, dtype=float)
    out = np.full(t_grid.shape, np.nan)

    m = np.isfinite(ts) & np.isfinite(vs)
    ts, vs = ts[m], vs[m]
    if ts.size < 2:
        return out
    order = np.argsort(ts, kind="stable")
    ts, vs = ts[order], vs[order]
    keep = np.concatenate(([True], np.diff(ts) > 0.0))   # drop duplicate stamps
    ts, vs = ts[keep], vs[keep]
    n = ts.size
    if n < 2:
        return out

    h = np.diff(ts)
    delta = np.diff(vs) / h
    d = np.zeros(n)
    d[0] = delta[0]
    d[n - 1] = delta[n - 2]
    for i in range(1, n - 1):
        if delta[i - 1] == 0.0 or delta[i] == 0.0 or (delta[i - 1] > 0.0) != (delta[i] > 0.0):
            d[i] = 0.0                       # local extremum: flat, no overshoot
        else:
            w1 = 2.0 * h[i] + h[i - 1]
            w2 = h[i] + 2.0 * h[i - 1]
            d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])

    idx = np.searchsorted(ts, t_grid, side="right") - 1
    at_last = t_grid == ts[n - 1]            # exact hit on the final sample
    idx[at_last] = n - 2
    ok = (idx >= 0) & (idx <= n - 2)
    ok &= (t_grid >= ts[0]) & (t_grid <= ts[n - 1])
    j = idx[ok]
    gap_ok = h[j] <= max_gap_s
    j = j[gap_ok]
    grid_ok = np.flatnonzero(ok)[gap_ok]

    s = (t_grid[grid_ok] - ts[j]) / h[j]
    s2 = s * s
    s3 = s2 * s
    out[grid_ok] = ((2.0 * s3 - 3.0 * s2 + 1.0) * vs[j]
                    + (s3 - 2.0 * s2 + s) * h[j] * d[j]
                    + (-2.0 * s3 + 3.0 * s2) * vs[j + 1]
                    + (s3 - s2) * h[j] * d[j + 1])
    return out


def resample_view(ts, us, vs, ws, t_grid,
                  max_gap_s: float = RESAMPLE_MAX_GAP_S):
    """[PARITY] Resample one camera's (u, v, weight) track onto the grid.

    Returns (us_g, vs_g, ws_g, had_gap). had_gap reports any interior sample
    gap wider than max_gap_s — the caller surfaces it as RESAMPLE_GAP so a
    dropout-riddled capture cannot pose as a clean one.
    """
    ts = np.asarray(ts, dtype=float)
    finite = np.isfinite(ts)
    tf = np.sort(ts[finite])
    had_gap = bool(tf.size >= 2 and float(np.max(np.diff(tf))) > max_gap_s)
    us_g = pchip_resample(ts, us, t_grid, max_gap_s)
    vs_g = pchip_resample(ts, vs, t_grid, max_gap_s)
    ws_g = pchip_resample(ts, ws, t_grid, max_gap_s)
    return us_g, vs_g, ws_g, had_gap


# --- Triangulation -----------------------------------------------------------

@dataclass
class ViewTrack2D:
    """[PARITY] One camera's observations of one point, aligned to the
    common grid: NaN where the camera has nothing to say."""
    p: np.ndarray    # (3,4) projection matrix
    us: np.ndarray   # (T,)
    vs: np.ndarray   # (T,)
    ws: np.ndarray   # (T,) confidence weights in (0, 1]


@dataclass
class Track3D:
    """[PARITY] A triangulated point series. NaN rows are honest absences."""
    t: np.ndarray               # (T,) master-clock grid
    xyz: np.ndarray             # (T,3) metres, world frame
    reproj_rms_px: np.ndarray   # (T,)
    coverage: float             # fraction of grid samples with a 3D answer
    flags: list[str]


def triangulate_point(rays) -> tuple[np.ndarray, float] | None:
    """[PARITY] Weighted DLT for one instant: rays = [(P, u, v, w), ...].

    Each view contributes two homogeneous constraints; rows are normalized
    to unit length BEFORE the confidence weight is applied, because raw DLT
    rows carry focal-length-sized magnitudes and the unnormalized normal
    matrix is conditioned like its square. The solution is the smallest
    eigenvector of the 4x4 normal matrix — chosen over an SVD of the tall
    system because a fixed-sweep 4x4 symmetric eigensolver ports to Swift
    without LAPACK, and determinism across the port matters more than
    elegance. Returns None for <2 rays, a degenerate solve, or a solution
    behind any contributing camera.
    """
    if len(rays) < MIN_VIEWS:
        return None
    rows = []
    for p, u, v, w in rays:
        for r in (u * p[2] - p[0], v * p[2] - p[1]):
            nrm = np.linalg.norm(r)
            if nrm <= 0.0 or not np.isfinite(nrm):
                return None
            rows.append((w / nrm) * r)
    a = np.vstack(rows)
    m = a.T @ a
    _vals, vecs = np.linalg.eigh(m)
    x = vecs[:, 0]
    if abs(x[3]) < 1e-12:
        return None
    xyz = x[:3] / x[3]
    errs = []
    for p, u, v, _w in rays:
        uv = project_point(p, xyz)
        if uv is None:
            return None
        errs.append((uv[0] - u) ** 2 + (uv[1] - v) ** 2)
    return xyz, math.sqrt(sum(errs) / len(errs))


def triangulate_series(t_grid, views: list[ViewTrack2D],
                       min_views: int = MIN_VIEWS,
                       had_gap: bool = False) -> Track3D:
    """[PARITY] Triangulate a whole point series on the common grid.

    A grid sample needs min_views usable views or it is NaN — absent, not
    guessed, the same rule the 2D pose pipeline follows for low-confidence
    joints. Flags are appended in the fixed order ONE_VIEW_ONLY,
    LOW_COVERAGE_3D, HIGH_REPROJECTION, RESAMPLE_GAP (order will be pinned
    by fixtures, like SwingFlag's).
    """
    t_grid = np.asarray(t_grid, dtype=float)
    n = t_grid.size
    xyz = np.full((n, 3), np.nan)
    rms = np.full(n, np.nan)

    def usable(view: ViewTrack2D, i: int) -> bool:
        return (np.isfinite(view.us[i]) and np.isfinite(view.vs[i])
                and np.isfinite(view.ws[i]) and view.ws[i] > 0.0)

    live = [v for v in views
            if any(usable(v, i) for i in range(n))]
    if len(live) >= min_views:
        for i in range(n):
            rays = [(v.p, float(v.us[i]), float(v.vs[i]), float(v.ws[i]))
                    for v in views if usable(v, i)]
            if len(rays) >= min_views:
                got = triangulate_point(rays)
                if got is not None:
                    xyz[i], rms[i] = got

    coverage = float(np.mean(np.isfinite(xyz[:, 0]))) if n else 0.0
    flags: list[str] = []
    if len(live) < min_views:
        flags.append(FLAG3D_ONE_VIEW)
    if coverage < COVERAGE_MIN_3D:
        flags.append(FLAG3D_LOW_COVERAGE)
    finite_rms = rms[np.isfinite(rms)]
    if finite_rms.size and float(np.median(finite_rms)) > REPROJ_RMS_MAX_PX:
        flags.append(FLAG3D_HIGH_REPROJECTION)
    if had_gap:
        flags.append(FLAG3D_RESAMPLE_GAP)
    return Track3D(t=t_grid, xyz=xyz, reproj_rms_px=rms,
                   coverage=coverage, flags=flags)


# --- Rotation metrics --------------------------------------------------------

def segment_azimuth_deg(p_left, p_right) -> float | None:
    """[PARITY] Azimuth of a body segment's left-right axis, degrees.

    Direction is right joint -> left joint, projected onto the ground plane.
    None when the segment is near-vertical (its horizontal component under
    SEGMENT_AZIMUTH_MIN_HORIZ of its length): the azimuth of an upright
    line is noise wearing units, and a None here is what keeps a fallen-over
    reading out of the separation curve.
    """
    d = np.asarray(p_left, dtype=float) - np.asarray(p_right, dtype=float)
    total = float(np.linalg.norm(d))
    if total <= 0.0 or not np.isfinite(total):
        return None
    horiz = math.hypot(d[0], d[1])
    if horiz < SEGMENT_AZIMUTH_MIN_HORIZ * total:
        return None
    return math.degrees(math.atan2(d[1], d[0]))


def hip_shoulder_separation_deg(hip_l, hip_r, shoulder_l, shoulder_r) -> float | None:
    """[PARITY] Pelvis azimuth minus thorax azimuth, wrapped to (-180, 180].

    Positive when the pelvis leads the thorax toward the pitcher — the
    coiled state hitters call separation. This is SEGMENT rotation (whole
    pelvis vs whole thorax), the quantity markerless systems measure at
    4-6 deg; JOINT axial rotation is 3-5x worse in every published
    validation and is deliberately not computed anywhere in this module.
    """
    pelvis = segment_azimuth_deg(hip_l, hip_r)
    thorax = segment_azimuth_deg(shoulder_l, shoulder_r)
    if pelvis is None or thorax is None:
        return None
    return wrap180(pelvis - thorax)


def quadratic_peak(ts, vs, t_center: float,
                   half_window_s: float) -> tuple[float, float] | None:
    """[PARITY] Peak of a noisy series: quadratic fit around t_center.

    Reading the raw per-sample maximum of a noisy curve is biased upward by
    exactly the noise being maximized over; a local quadratic vertex is the
    estimator the rest of the codebase already trusts (fit_quadratic). The
    vertex is clamped into the window — an extrapolated peak is a guess.
    None when there are too few samples or the fit is not concave (no local
    peak to report).
    """
    ts = np.asarray(ts, dtype=float)
    vs = np.asarray(vs, dtype=float)
    m = (np.isfinite(ts) & np.isfinite(vs)
         & (np.abs(ts - t_center) <= half_window_s))
    if int(m.sum()) < 5:
        return None
    coeffs, _rms = sla.fit_quadratic(ts[m] - t_center, vs[m])
    a, b, _c = float(coeffs[0]), float(coeffs[1]), float(coeffs[2])
    if a >= 0.0:
        return None
    tv = min(max(-b / (2.0 * a), -half_window_s), half_window_s)
    return t_center + tv, float(np.polyval(coeffs, tv))


# --- Ball flight in 3D -------------------------------------------------------

@dataclass
class LaunchMetrics3D:
    """[PARITY] Launch numbers read from a triangulated ball track."""
    ev_mph: float
    ev_mps: float
    la_deg: float       # up-positive, from the horizontal
    spray_deg: float    # azimuth of the horizontal velocity; 0 = straight out
    n_samples: int
    fit_rms_m: float


def launch_metrics_3d(t, xyz, contact_t: float,
                      window_s: float = sla.VELOCITY_WINDOW_S) -> LaunchMetrics3D | None:
    """[PARITY] EV / LA / spray from 3D positions just after contact.

    Same shape as the 2D pipeline's read — quadratic per axis over the
    velocity window, velocity taken at the window start — but with no scale
    step at all: the positions are already metres, which is the whole point
    of triangulating. Spray direction is the metric a single side-on camera
    could never see.
    """
    t = np.asarray(t, dtype=float)
    xyz = np.asarray(xyz, dtype=float)
    m = (np.isfinite(t) & np.all(np.isfinite(xyz), axis=1)
         & (t >= contact_t) & (t <= contact_t + window_s))
    if int(m.sum()) < LAUNCH3D_MIN_SAMPLES:
        return None
    ts = t[m]
    tau = ts - ts[0]
    v = np.zeros(3)
    rss = 0.0
    for axis in range(3):
        coeffs, rms = sla.fit_quadratic(tau, xyz[m, axis])
        v[axis] = float(coeffs[1])          # linear term = velocity at tau 0
        rss += rms * rms
    speed = float(np.linalg.norm(v))
    la = math.degrees(math.atan2(v[2], math.hypot(v[0], v[1])))
    spray = math.degrees(math.atan2(v[1], v[0]))
    return LaunchMetrics3D(ev_mph=speed * sla.MPH_PER_MPS, ev_mps=speed,
                           la_deg=la, spray_deg=spray,
                           n_samples=int(m.sum()), fit_rms_m=math.sqrt(rss))


def gravity_vector_3d(t, xyz):
    """[PARITY] The gravity VECTOR read from a triangulated free-flight track.

    Direction matters as much as magnitude, and for a different reason. A
    rotation of the whole rig — both tripods rolled the same way, a mis-set
    lens height, a bearing error shared by both cameras — moves every
    reconstructed point but PRESERVES LENGTHS. So |g| is structurally blind
    to it, and a gate built on magnitude alone passes a rig that is rotated
    bodily out of the world frame. The angle between this vector and true
    down is the residual that catches it."""
    return _gravity_vec(t, xyz)


def _gravity_vec(t, xyz):
    """[PARITY] Shared body: drag-aware acceleration fit.

    The 3D drop test: a tracked ball in flight must accelerate at 9.81 m/s^2
    no matter where the cameras stood — with NO scale assumption, because
    the track is already metric. That makes it the whole-rig witness:
    calibration, sync, and triangulation all have to be right at once for
    this number to land.

    Drag is not negligible for a hit softball (at 29 m/s the drag
    deceleration rivals g — the same fact that forced sla_common's
    drag-aware scale solve), so the measured acceleration is corrected by
    the drag model at the window-midpoint velocity before taking the
    magnitude: a_measured = g_vec - (k/m)|v|v, hence
    g_vec = a_measured + (k/m)|v|v. For a gently tossed ball the correction
    is a rounding error and the check is nearly model-free.
    """
    t = np.asarray(t, dtype=float)
    xyz = np.asarray(xyz, dtype=float)
    m = np.isfinite(t) & np.all(np.isfinite(xyz), axis=1)
    if int(m.sum()) < 12:
        return None
    ts = t[m]
    if float(ts.max() - ts.min()) < GRAVITY3D_MIN_SPAN_S:
        return None
    tau = ts - ts[0]
    tau_mid = float(tau[-1]) / 2.0
    accel = np.zeros(3)
    v_mid = np.zeros(3)
    for axis in range(3):
        coeffs, _rms = sla.fit_quadratic(tau, xyz[m, axis])
        accel[axis] = 2.0 * float(coeffs[0])
        v_mid[axis] = 2.0 * float(coeffs[0]) * tau_mid + float(coeffs[1])
    k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD
                * math.pi * (sla.BALL_DIAMETER_M / 2.0) ** 2 / sla.BALL_MASS_KG)
    return accel + k_over_m * float(np.linalg.norm(v_mid)) * v_mid


def gravity_magnitude_3d(t, xyz) -> float | None:
    """[PARITY] |g| from a triangulated free-flight track. The scale witness."""
    g = _gravity_vec(t, xyz)
    return None if g is None else float(np.linalg.norm(g))


def gravity_tilt_deg(t, xyz) -> float | None:
    """[PARITY] Angle between reconstructed gravity and true down, degrees.

    The rotational half of the rig check, and it needs a caveat rather than a
    threshold. Tilt is a transverse acceleration divided by g, and the noise
    on a quadratic acceleration fit falls roughly as the fit window to the
    -2.5 power, so the floor is a strong function of how long the ball was
    tracked. A perfect, unrolled rig with ordinary detection noise reads
    around 2.4 degrees over a 0.30 s fall and well under 1 degree over 0.55 s.

    So this is REPORTED, never gated: a fixed threshold would fail correct
    rigs on short falls, which is the common case and exactly the field
    afternoon a gate is supposed to protect. Compare it against the floor for
    the window you actually got."""
    g = _gravity_vec(t, xyz)
    if g is None:
        return None
    n = float(np.linalg.norm(g))
    if n <= 1e-9:
        return None
    cos = float(np.dot(g / n, np.array([0.0, 0.0, -1.0])))
    return math.degrees(math.acos(min(max(cos, -1.0), 1.0)))


# --- Offline rig description (tape measure instead of a solver) -------------
#
# P2 will solve the rig from a wand pass. Until that exists, a rig can be
# MEASURED, and measuring it first is the right order anyway: it removes the
# calibration solver from the experiment so a bad reconstruction has one
# fewer place to hide. Three ground distances and two lens heights fully
# determine two cameras up to a mirror flip, and all five are things a tape
# measure gives without argument.

@dataclass
class MeasuredRig:
    """[SPIKE] Two cameras pinned by tape measure, in the world frame
    (origin = the marked spot on the ground, +Z up)."""
    pos_a: np.ndarray
    pos_b: np.ndarray
    separation_deg: float


def rig_from_ground_triangle(d_a_m: float, d_b_m: float, d_ab_m: float,
                             h_a_m: float, h_b_m: float,
                             b_toward_plus_x: bool = True) -> MeasuredRig | None:
    """[SPIKE] Two camera positions from five tape measurements.

    d_a, d_b   ground distance from each tripod's base to the marked spot
    d_ab       ground distance between the two tripod bases
    h_a, h_b   lens height of each camera

    All three distances are HORIZONTAL — tape on the ground, base to base —
    because a slant distance to a lens is the one measurement a person cannot
    take accurately alone, and mixing a slant with two horizontals silently
    tilts the whole rig.

    The angle at the origin comes from the law of cosines, which is also the
    separation angle the placement advice is about, so a rig that measures 40
    degrees tells you to move a tripod before it tells you anything else.
    Returns None when the three distances cannot form a triangle — that is a
    mis-measurement, and it must not be rounded into a plausible rig.
    """
    if min(d_a_m, d_b_m, d_ab_m) <= 0.0:
        return None
    cos_sep = (d_a_m * d_a_m + d_b_m * d_b_m - d_ab_m * d_ab_m) / (2.0 * d_a_m * d_b_m)
    if not (-1.0 <= cos_sep <= 1.0):
        return None
    sep = math.acos(cos_sep)
    az_b = sep if b_toward_plus_x else -sep
    # Camera A sits on the -Y side at azimuth 0; positive azimuth walks toward
    # +X. Same convention as the synthetic rig, so the two agree by
    # construction rather than by comment.
    pos_a = np.array([0.0, -d_a_m, h_a_m])
    pos_b = np.array([d_b_m * math.sin(az_b), -d_b_m * math.cos(az_b), h_b_m])
    return MeasuredRig(pos_a=pos_a, pos_b=pos_b, separation_deg=math.degrees(sep))


def solve_aim_from_reference(intr: CameraIntrinsics, cam_pos, world_pt,
                             u: float, v: float,
                             iterations: int = 40) -> CameraExtrinsics | None:
    """[SPIKE] Recover where a camera was AIMED from one known landmark.

    Position comes from the tape measure; aim does not, and assuming a camera
    points exactly at the mark is worth degrees of error. But a stationary
    reference ball at a known world point, seen at a known pixel, supplies
    two constraints — which is exactly the two freedoms a level camera has
    left (pan and tilt) once roll is fixed by the tripod being level.

    That is the constraint count that matters here, and it closes: two
    knowns, two unknowns. Roll is NOT solved and must not be — a third
    unknown against two constraints is the batter-outline mistake in
    CLAUDE.md, and this returns a rig that is honest about needing a level
    tripod instead of a rig that invents one.

    Solved by damped Newton on a numerical 2x2 Jacobian; the map from aim
    angles to pixels is smooth and nearly linear over the arcminutes this
    has to move, so it converges in a handful of steps or not at all.
    """
    cam_pos = np.asarray(cam_pos, dtype=float)
    world_pt = np.asarray(world_pt, dtype=float)
    d = world_pt - cam_pos
    if np.linalg.norm(d) < 1e-9:
        return None

    def extr_for(pan: float, tilt: float) -> CameraExtrinsics | None:
        aim = cam_pos + np.array([math.cos(tilt) * math.cos(pan),
                                  math.cos(tilt) * math.sin(pan),
                                  math.sin(tilt)])
        return look_at_extrinsics(cam_pos, aim)

    def residual(pan: float, tilt: float):
        extr = extr_for(pan, tilt)
        if extr is None:
            return None
        uv = project_point(projection_matrix(intr, extr), world_pt)
        if uv is None:
            return None
        return np.array([uv[0] - u, uv[1] - v])

    pan = math.atan2(d[1], d[0])
    tilt = math.atan2(d[2], math.hypot(d[0], d[1]))
    step = 1e-4
    for _ in range(iterations):
        r0 = residual(pan, tilt)
        if r0 is None:
            return None
        if float(np.linalg.norm(r0)) < 1e-6:
            break
        rp = residual(pan + step, tilt)
        rt = residual(pan, tilt + step)
        if rp is None or rt is None:
            return None
        jac = np.column_stack([(rp - r0) / step, (rt - r0) / step])
        try:
            delta = np.linalg.solve(jac, -r0)
        except np.linalg.LinAlgError:
            return None
        # Damped: a full Newton step can leap past the solution when the
        # landmark sits near the frame edge, where the Jacobian is worst.
        pan += 0.7 * float(delta[0])
        tilt += 0.7 * float(delta[1])
    final = residual(pan, tilt)
    if final is None or float(np.linalg.norm(final)) > 0.5:
        return None
    return extr_for(pan, tilt)


# --- Offline time alignment --------------------------------------------------

def gcc_phat_offset(sig_a, sig_b, sample_rate: float,
                    max_offset_s: float = 5.0) -> tuple[float, float] | None:
    """[PARITY] Time offset between two recordings of the same sound.

    Generalized cross-correlation with phase transform: the cross-power
    spectrum is normalized to unit magnitude before the inverse transform, so
    the result depends on phase alignment alone. That is what makes it work
    on two phones with different microphones, different gain and different
    distances from the crack — plain correlation is dominated by whichever
    recording is louder, PHAT is not.

    Returns (offset_s, confidence) where offset_s is how much LATER the same
    event appears in b than in a, and confidence is the peak height over the
    correlation's own median. It does NOT correct for sound travel time: two
    phones at different distances hear the crack about 2.9 ms apart per metre
    of path difference, and only the caller knows the geometry.
    """
    a = np.asarray(sig_a, dtype=float)
    b = np.asarray(sig_b, dtype=float)
    if a.size < 16 or b.size < 16 or sample_rate <= 0.0:
        return None
    n = 1
    while n < a.size + b.size:
        n *= 2
    fa = np.fft.rfft(a - a.mean(), n)
    fb = np.fft.rfft(b - b.mean(), n)
    cross = fa * np.conj(fb)
    mag = np.abs(cross)
    mag[mag < 1e-12] = 1e-12
    corr = np.fft.irfft(cross / mag, n)
    corr = np.concatenate([corr[-(n // 2):], corr[:n // 2 + 1]])
    zero = n // 2
    max_lag = int(min(max_offset_s * sample_rate, zero - 1))
    window = corr[zero - max_lag:zero + max_lag + 1]
    if window.size == 0:
        return None
    peak = int(np.argmax(window))
    lag = peak - max_lag
    baseline = float(np.median(np.abs(window))) or 1e-12
    conf = float(window[peak]) / baseline
    # Parabolic interpolation for sub-sample resolution: at 48 kHz one sample
    # is 21 us, but the peak's true position sits between samples and the
    # curvature says where.
    if 0 < peak < window.size - 1:
        y0, y1, y2 = window[peak - 1], window[peak], window[peak + 1]
        denom = y0 - 2.0 * y1 + y2
        if abs(denom) > 1e-12:
            lag += float(0.5 * (y0 - y2) / denom)
    return -lag / sample_rate, conf


def solve_time_offset(p_a: np.ndarray, ts_a, us_a, vs_a,
                      p_b: np.ndarray, ts_b, us_b, vs_b,
                      search_s: float = 2.0, coarse_step_s: float = 0.002,
                      refine_passes: int = 3) -> tuple[float, float] | None:
    """[PARITY] Align two views by making the 3D consistent, no audio needed.

    Two cameras watching one moving point disagree about where it is in
    space unless their clocks agree; the offset that minimizes reprojection
    error is the offset that was actually there. This is the sync of last
    resort and the sync of first resort: it needs no network, no clap, and
    survives the slow-motion export path stripping the audio track — which
    audio_lab.py has warned about since before there was anything to sync.

    Coarse scan then successive refinement, because the error surface has a
    sharp global minimum but shallow local structure from pixel noise.
    Returns (offset_s, reproj_rms_px) where offset_s is how much later b's
    clock reads than a's, so t_a = t_b - offset_s.
    """
    ts_a = np.asarray(ts_a, dtype=float)
    ts_b = np.asarray(ts_b, dtype=float)
    if ts_a.size < 4 or ts_b.size < 4:
        return None

    def cost(offset: float) -> float:
        # Put b on a's clock, then ask both views about the instants they
        # BOTH cover — an offset that merely shrinks the overlap must not
        # look better than one that fits it.
        tb = ts_b - offset
        lo, hi = max(ts_a.min(), tb.min()), min(ts_a.max(), tb.max())
        if hi - lo < 0.05:
            return float("inf")
        grid = np.arange(lo, hi, 1.0 / 240.0)
        if grid.size < 6:
            return float("inf")
        ua = pchip_resample(ts_a, us_a, grid)
        va = pchip_resample(ts_a, vs_a, grid)
        ub = pchip_resample(tb, us_b, grid)
        vb = pchip_resample(tb, vs_b, grid)
        errs = []
        for i in range(grid.size):
            if not (np.isfinite(ua[i]) and np.isfinite(va[i])
                    and np.isfinite(ub[i]) and np.isfinite(vb[i])):
                continue
            got = triangulate_point([(p_a, float(ua[i]), float(va[i]), 1.0),
                                     (p_b, float(ub[i]), float(vb[i]), 1.0)])
            if got is not None:
                errs.append(got[1])
        if len(errs) < 5:
            return float("inf")
        return float(np.median(errs))

    best_off, best_cost, step = 0.0, float("inf"), coarse_step_s
    lo, hi = -search_s, search_s
    for _ in range(refine_passes + 1):
        offs = np.arange(lo, hi + step, step)
        for off in offs:
            c = cost(float(off))
            if c < best_cost:
                best_cost, best_off = c, float(off)
        if not np.isfinite(best_cost):
            return None
        lo, hi = best_off - step, best_off + step
        step /= 8.0
    return best_off, best_cost


# --- Using the rig to grade the single-camera scale ---------------------------

@dataclass
class DiameterCheck:
    """[PARITY] How the measured ball diameter compares with the truth the
    geometry implies."""
    n: int
    median_ratio: float          # measured / predicted; 1.0 is correct
    by_size: list                # [(apparent_px_bucket, n, median_ratio)]
    depth_span_m: tuple


def diameter_truth_check(xyz, t_grid, views) -> DiameterCheck | None:
    """[PARITY] Grade `_subpixel_minor_diameter` against triangulated depth.

    docs/VALIDATION.md's G0 runs established that the app under-reads the ball
    — 11% low at 37 px, 43% low at 26 px — and asked the right next question:
    is the bias constant with distance (then it is the diameter measurement)
    or does it change (then it is the optics)? Two drops answered "it
    changes", which is what ruled out any single calibration constant.

    A two-camera rig answers that question continuously, from one clip, with
    no tape measure and no second setup. Triangulation gives the ball's 3D
    position, hence its true distance from each lens, hence the diameter it
    OUGHT to subtend: BALL_DIAMETER_M * fx / depth. Comparing that with what
    the detector actually measured, instant by instant, is the whole error
    curve as a function of apparent size — the measurement
    `_subpixel_minor_diameter` needs in order to be repaired rather than
    scaled.

    This is worth stating plainly because it inverts the usual relationship:
    the two-camera rig is not only a better measurement, it is an
    INSTRUMENT for fixing the one-camera measurement. A tossed ball changes
    depth through the clip, so one toss sweeps a range of apparent sizes.

    THE CAVEAT THAT MAKES IT VALID: this check inherits the rig's scale. If
    the tape measurements are 5% wrong, every depth is 5% wrong and so is
    every predicted diameter. It is therefore only meaningful on a clip whose
    `gravity_magnitude_3d` came back at 9.81 — gravity validates the scale,
    the scale validates the depth, and only then does the depth grade the
    diameter. Read the ratio table only after the gravity line passes.

    Note also that a synthetic rehearsal cannot exercise the real bug: a
    drawn ellipse on a smooth background is measured a percent or two HIGH,
    where real footage reads 11-43% LOW. The compression halo and the optics
    are the mechanism, and neither survives being simulated. This check earns
    its keep on real clips only.

    `views` is a list of (intr, extr, diameters_on_grid). Returns None when
    nothing usable overlaps.
    """
    xyz = np.asarray(xyz, dtype=float)
    ratios, sizes, depths = [], [], []
    for intr, extr, diams in views:
        d = np.asarray(diams, dtype=float)
        for i in range(min(len(d), xyz.shape[0])):
            if not (np.isfinite(d[i]) and d[i] > 0.0 and np.all(np.isfinite(xyz[i]))):
                continue
            depth = float((extr.r @ xyz[i] + extr.t)[2])
            if depth <= 0.1:
                continue
            predicted = sla.BALL_DIAMETER_M * intr.fx / depth
            if predicted <= 0.0:
                continue
            ratios.append(float(d[i]) / predicted)
            sizes.append(float(d[i]))
            depths.append(depth)
    if len(ratios) < 8:
        return None
    ratios = np.array(ratios)
    sizes = np.array(sizes)

    # Bucket by apparent size, because that is the axis the error was found to
    # depend on. Ten-pixel buckets: fine enough to show a trend, coarse enough
    # that each bucket has samples in it.
    by_size = []
    lo = int(np.floor(sizes.min() / 10.0) * 10)
    hi = int(np.ceil(sizes.max() / 10.0) * 10)
    for edge in range(lo, hi, 10):
        m = (sizes >= edge) & (sizes < edge + 10)
        if int(m.sum()) >= 3:
            by_size.append((edge, int(m.sum()), float(np.median(ratios[m]))))
    return DiameterCheck(n=len(ratios), median_ratio=float(np.median(ratios)),
                         by_size=by_size,
                         depth_span_m=(float(min(depths)), float(max(depths))))
