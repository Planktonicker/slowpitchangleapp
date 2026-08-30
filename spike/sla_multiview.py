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
GRAVITY3D_MIN_SPAN_S = 0.15          # [PARITY] curvature needs time; 36 frames @240
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


def gravity_magnitude_3d(t, xyz) -> float | None:
    """[PARITY] |g| read from a triangulated free-flight track, drag-aware.

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
    g_vec = accel + k_over_m * float(np.linalg.norm(v_mid)) * v_mid
    return float(np.linalg.norm(g_vec))
