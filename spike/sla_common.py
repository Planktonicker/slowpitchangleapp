# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
sla_common.py — SwingLab reference implementation.

Single source of truth for the measurement pipeline: ball detection, track
building, trajectory fitting, dual-scale calibration and the flight-physics
model. The Phase 2 Swift port (Geometry.swift / SwingAnalyzer.swift) must
reproduce this file number-for-number; parity tests pin the two together.

Image coordinate convention: x grows right, y grows DOWN (OpenCV standard).
All reported angles are up-positive in real-world terms.

Units: pixels and seconds internally; meters via a scale factor [m/px] that
is estimated two independent ways and cross-checked:
  1. scale_ball    — known ball diameter vs its apparent minor-axis size
  2. scale_gravity — fitted vertical acceleration vs known g
Disagreement between the two beyond tolerance flags a low-confidence reading.
"""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass, field

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# Physical constants
# ---------------------------------------------------------------------------

G = 9.80665                                  # m/s^2
BALL_CIRCUMFERENCE_M = 12.0 * 0.0254         # 12 in slow-pitch softball
BALL_DIAMETER_M = BALL_CIRCUMFERENCE_M / math.pi   # 0.09702 m — 9.7 cm across
BALL_MASS_KG = 0.190                         # 6.25–7.0 oz ball -> ~190 g
AIR_DENSITY = 1.225                          # kg/m^3, sea level
DRAG_CD = 0.47                               # smooth-ish sphere
MPH_PER_MPS = 2.23694

# Optic yellow in OpenCV HSV (H: 0-179). Wide on purpose; tighten per venue.
HSV_LO_DEFAULT = (18, 70, 120)
HSV_HI_DEFAULT = (48, 255, 255)

# Detection geometry defaults (pixels), sane for 1080p at 4.5-6 m.
MIN_RADIUS_PX_DEFAULT = 4.0
MAX_RADIUS_PX_DEFAULT = 60.0

# Diameter measurement: mask contours over-include the compression/edge-blend
# halo around the ball (measured +6% on encoded synthetic video — a direct EV
# bias). The reference measurement is therefore sub-pixel: sample the HSV
# in-range profile along the blur-free MINOR axis and take the half-in/half-out
# crossings. The gravity-vs-diameter scale disagreement (G2) is immune to this
# and cross-checks it on real footage.
DIAMETER_PROFILE_STEP_PX = 0.25

# Analysis defaults
VELOCITY_WINDOW_S = 0.12      # fit window for LA/EV at contact (~29 frames @240)
GRAVITY_WINDOW_S = 0.35       # longer window: curvature needs time to accumulate
MIN_TRACK_FRAMES = 8
MIN_GRAVITY_TRACK_S = 0.20    # below this the gravity scale is unreliable
SCALE_DISAGREE_TOL = 0.08     # G2 tolerance
DIAMETER_DRIFT_TOL = 0.10     # depth-motion (cosine error) flag threshold
RESIDUAL_TOL_PX = 3.0

# Confidence flags (string constants shared with the Swift port)
FLAG_SHORT_TRACK = "SHORT_TRACK"
FLAG_NO_GRAVITY_CHECK = "NO_GRAVITY_CHECK"
FLAG_SCALE_DISAGREE = "SCALE_DISAGREE"
FLAG_DEPTH_MOTION = "DEPTH_MOTION"
FLAG_HIGH_RESIDUAL = "HIGH_RESIDUAL"


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

@dataclass
class BallObservation:
    frame: int
    t: float              # seconds from clip start
    x: float              # px
    y: float              # px (down-positive)
    diameter_px: float    # minor-axis diameter (blur-resistant, see detect)
    area_px: float


@dataclass
class SwingMetrics:
    launch_angle_deg: float
    exit_velo_mph: float
    exit_velo_mps: float
    scale_ball_m_per_px: float
    scale_gravity_m_per_px: float | None
    scale_disagreement: float | None       # |sg-sb|/sb
    diameter_drift: float                  # signed fractional change over track
    n_frames: int
    track_duration_s: float
    fit_rms_px: float
    t0: float                              # contact time used (s)
    vx_px_s: float
    vy_px_s: float                         # down-positive (image coords)
    # Ball centre at t0 from the velocity fit (px, raw image coords — the roll
    # correction rotates velocities only). Extrapolated when the batter hides
    # the first frames. Feeds the contact-offset (undercut) measurement.
    x0_px: float = 0.0
    y0_px: float = 0.0
    flags: list[str] = field(default_factory=list)

    @property
    def high_confidence(self) -> bool:
        return not self.flags


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

def make_bg_subtractor() -> cv2.BackgroundSubtractorMOG2:
    return cv2.createBackgroundSubtractorMOG2(
        history=240, varThreshold=25, detectShadows=False
    )


def normalize_brightness(frame_bgr: np.ndarray, target_v: float = 128.0) -> np.ndarray:
    """Per-frame V-channel gain. Counters LED flicker banding at 240fps."""
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    v = hsv[:, :, 2]
    med = float(np.median(v))
    if med > 1.0:
        gain = target_v / med
        hsv[:, :, 2] = np.clip(v.astype(np.float32) * gain, 0, 255).astype(np.uint8)
    return cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)


def yellow_mask(frame_bgr: np.ndarray, hsv_lo=HSV_LO_DEFAULT, hsv_hi=HSV_HI_DEFAULT) -> np.ndarray:
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(hsv, np.array(hsv_lo, np.uint8), np.array(hsv_hi, np.uint8))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    return mask


def _subpixel_minor_diameter(
    frame_bgr: np.ndarray,
    cx: float,
    cy: float,
    minor_axis_deg: float,
    r0_px: float,
) -> float | None:
    """Sub-pixel ball diameter along the minor (blur-free) axis.

    Threshold-free matte-fraction method: sample the image bilinearly along
    the minor-axis line, estimate the ball color from the blob core and the
    background color just outside it (independently per side), project each
    sample onto the core->background color line to get a mixing fraction
    alpha in [0,1], and locate the alpha = 0.5 crossing on each side by
    linear interpolation. The 50% crossing sits at the geometric edge
    regardless of venue colors or how far an HSV threshold reads into the
    blur/compression halo. r0_px is a rough radius from the mask contour,
    used only to place the core/background sampling windows.
    """
    step = DIAMETER_PROFILE_STEP_PX
    reach = r0_px * 1.8 + 4.0
    n = max(8, int(reach / step))
    rs = (np.arange(-n, n + 1) * step).astype(np.float32)
    a = math.radians(minor_axis_deg)
    mapx = (cx + rs * math.cos(a)).reshape(-1, 1)
    mapy = (cy + rs * math.sin(a)).reshape(-1, 1)
    samples = cv2.remap(frame_bgr, mapx, mapy, cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_REPLICATE).reshape(-1, 3).astype(np.float32)
    c = n
    core_sel = np.abs(rs) <= max(0.4 * r0_px, step)
    core = samples[core_sel].mean(axis=0)

    def edge_radius(direction: int) -> float | None:
        bg_sel = (rs * direction >= 1.3 * r0_px) & (rs * direction <= 1.8 * r0_px + 4.0)
        if not bg_sel.any():
            return None
        bg = samples[bg_sel].mean(axis=0)
        diff = core - bg
        denom = float(np.dot(diff, diff))
        if denom < 900.0:                 # <30/255 color contrast: unusable
            return None
        alpha = (samples - bg) @ diff / denom
        prev_i = c
        i = c + direction
        while 0 <= i + direction < len(alpha):
            if alpha[i] < 0.5 and alpha[i + direction] < 0.5:
                a1, a0 = float(alpha[i]), float(alpha[prev_i])
                frac = (a0 - 0.5) / (a0 - a1) if a0 > a1 else 0.5
                return abs(float(rs[prev_i])) + frac * step
            prev_i = i
            i += direction
        return None

    r_pos = edge_radius(+1)
    r_neg = edge_radius(-1)
    if r_pos is None or r_neg is None:
        return None
    return r_pos + r_neg


def detect_ball_candidates(
    frame_bgr: np.ndarray,
    frame_idx: int,
    t: float,
    fg_mask: np.ndarray | None = None,
    hsv_lo=HSV_LO_DEFAULT,
    hsv_hi=HSV_HI_DEFAULT,
    min_radius_px: float = MIN_RADIUS_PX_DEFAULT,
    max_radius_px: float = MAX_RADIUS_PX_DEFAULT,
) -> list[BallObservation]:
    """Find yellow, roughly-ball-sized blobs in one frame.

    Motion blur elongates the ball along its velocity vector, so the blob is
    an ellipse. The MINOR axis is perpendicular to motion and stays equal to
    the true ball diameter — measured sub-pixel via _subpixel_minor_diameter
    (mask contours alone over-read the edge-blend halo).
    """
    hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
    mask = cv2.inRange(hsv, np.array(hsv_lo, np.uint8), np.array(hsv_hi, np.uint8))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    if fg_mask is not None:
        mask = cv2.bitwise_and(mask, fg_mask)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    out: list[BallObservation] = []
    min_area = math.pi * min_radius_px ** 2
    # Elongation allowance: up to ~4x blur smear along the motion axis.
    max_area = math.pi * max_radius_px ** 2 * 4.0

    for c in contours:
        area = cv2.contourArea(c)
        if area < min_area or area > max_area:
            continue
        if len(c) >= 5:
            (cx, cy), (ax1, ax2), ang = cv2.fitEllipse(c)
            minor = min(ax1, ax2)
            major = max(ax1, ax2)
            if major > 0 and major / max(minor, 1e-6) > 6.0:
                continue                      # too elongated even for blur
            # fitEllipse's angle is the major axis of ellipse rotation from
            # vertical of ax1... derive the minor-axis direction explicitly:
            # ang is the rotation of ax1 (width) from horizontal; the minor
            # axis lies along whichever of (ang, ang+90) matches min(ax1,ax2).
            minor_dir = ang + (0.0 if ax1 <= ax2 else 90.0)
        else:
            (cx, cy), r = cv2.minEnclosingCircle(c)
            minor = 2.0 * r
            minor_dir = 90.0
        refined = _subpixel_minor_diameter(frame_bgr, cx, cy, minor_dir, minor / 2.0)
        if refined is not None:
            minor = refined
        if not (2 * min_radius_px <= minor <= 2 * max_radius_px):
            continue
        out.append(BallObservation(frame_idx, t, float(cx), float(cy), float(minor), float(area)))
    return out


# ---------------------------------------------------------------------------
# Track building (greedy nearest-neighbour with constant-velocity prediction)
# ---------------------------------------------------------------------------

def build_tracks(
    per_frame: dict[int, list[BallObservation]],
    fps: float,
    base_gate_px: float = 40.0,
    max_coast_frames: int = 3,
    min_len: int = 4,
) -> list[list[BallObservation]]:
    """Link per-frame candidates into tracks.

    Association gate grows with track speed so a 240fps line drive (~30-40 px
    per frame) still links, while random net/grass false positives don't.
    Tracks may coast (miss detection) for up to max_coast_frames.
    """
    active: list[dict] = []     # {obs: [...], last_frame: int}
    done: list[list[BallObservation]] = []

    for f in sorted(per_frame.keys()):
        cands = list(per_frame[f])
        claimed = [False] * len(cands)

        for tr in active:
            obs = tr["obs"]
            gap = f - obs[-1].frame
            if gap <= 0 or gap > max_coast_frames + 1:
                continue
            # constant-velocity prediction
            if len(obs) >= 2:
                dt = obs[-1].t - obs[-2].t
                vx = (obs[-1].x - obs[-2].x) / dt if dt > 0 else 0.0
                vy = (obs[-1].y - obs[-2].y) / dt if dt > 0 else 0.0
            else:
                vx = vy = 0.0
            pred_x = obs[-1].x + vx * gap / fps
            pred_y = obs[-1].y + vy * gap / fps
            speed_px_fr = math.hypot(vx, vy) / fps
            gate = max(base_gate_px, 2.5 * speed_px_fr) * gap

            best_i, best_d = -1, gate
            for i, c in enumerate(cands):
                if claimed[i]:
                    continue
                d = math.hypot(c.x - pred_x, c.y - pred_y)
                if d < best_d:
                    best_i, best_d = i, d
            if best_i >= 0:
                obs.append(cands[best_i])
                claimed[best_i] = True

        # retire tracks that coasted too long
        still = []
        for tr in active:
            if f - tr["obs"][-1].frame > max_coast_frames:
                if len(tr["obs"]) >= min_len:
                    done.append(tr["obs"])
            else:
                still.append(tr)
        active = still

        # unclaimed candidates seed new tracks
        for i, c in enumerate(cands):
            if not claimed[i]:
                active.append({"obs": [c]})

    for tr in active:
        if len(tr["obs"]) >= min_len:
            done.append(tr["obs"])
    return done


def select_outbound_track(
    tracks: list[list[BallObservation]],
    fps: float,
    direction: str = "auto",     # "left" | "right" | "auto"
    min_len: int = MIN_TRACK_FRAMES,
) -> list[BallObservation] | None:
    """Pick the hit ball: the longest/fastest coherent track moving outbound.

    An inbound pitch also forms a track; it is slower and moves the other way.
    With direction="auto" the fastest track's horizontal direction wins.
    """
    scored = []
    for tr in tracks:
        if len(tr) < min_len:
            continue
        dt = tr[-1].t - tr[0].t
        if dt <= 0:
            continue
        vx = (tr[-1].x - tr[0].x) / dt
        vy = (tr[-1].y - tr[0].y) / dt
        speed = math.hypot(vx, vy)
        scored.append((speed * len(tr), speed, vx, tr))
    if not scored:
        return None
    scored.sort(key=lambda s: -s[0])

    if direction == "auto":
        return scored[0][3]
    want_positive = direction == "right"
    for _score, _speed, vx, tr in scored:
        if (vx > 0) == want_positive:
            return tr
    return None


# ---------------------------------------------------------------------------
# Fitting and metrics
# ---------------------------------------------------------------------------

def fit_quadratic(ts: np.ndarray, vs: np.ndarray) -> tuple[np.ndarray, float]:
    """Least-squares v(t) = a t^2 + b t + c. Returns (coeffs [a,b,c], rms residual)."""
    coeffs = np.polyfit(ts, vs, 2)
    resid = vs - np.polyval(coeffs, ts)
    rms = float(np.sqrt(np.mean(resid ** 2)))
    return coeffs, rms


def solve_gravity_scale(
    ay_px: float,
    vx_px_mid: float,
    vy_px_mid: float,
    scale_hint: float | None = None,
) -> float | None:
    """Drag-aware gravity scale: solve for s [m/px] from the fitted vertical
    acceleration and mid-window velocity.

    A 12 in softball's terminal velocity is ~30 m/s (66 mph), i.e. a batted
    ball flies AT terminal velocity — drag acceleration is comparable to g
    and cannot be ignored. The naive s = G / ay_px would be biased 20-40%.

    Model (image coords, y down-positive):
        ay_m = G - (k/m) * |v_m| * vy_m          with v_m = s * v_px
        s * ay_px = G - (k/m) * s^2 * |v_px| * vy_px
    ->  A s^2 + B s + C = 0,  A = (k/m)|v_px|vy_px,  B = ay_px,  C = -G

    While the ball rises (vy_px < 0) the quadratic has two positive roots;
    the physical one is the root nearest the independent ball-diameter scale
    (scale_hint). Descending or near-apex cases are single-rooted/naive.
    """
    if ay_px <= 1e-6:
        return None
    k_over_m = 0.5 * AIR_DENSITY * DRAG_CD * math.pi * (BALL_DIAMETER_M / 2) ** 2 / BALL_MASS_KG
    speed_px = math.hypot(vx_px_mid, vy_px_mid)
    A = k_over_m * speed_px * vy_px_mid
    B = ay_px
    C = -G
    if abs(A) < 1e-9:
        return G / ay_px
    disc = B * B - 4 * A * C
    if disc < 0:
        return None
    sq = math.sqrt(disc)
    roots = [r for r in ((-B + sq) / (2 * A), (-B - sq) / (2 * A)) if r > 0]
    if not roots:
        return None
    if scale_hint and scale_hint > 0:
        return min(roots, key=lambda r: abs(r - scale_hint))
    return min(roots)


# ---------------------------------------------------------------------------
# Camera tilt rectification
# ---------------------------------------------------------------------------
#
# Every number here assumes the sensor plane is parallel to the plane the ball
# flies in. Only then does one vertical pixel mean the same number of vertical
# metres everywhere in frame.
#
# A camera that sits *below* contact height does not break that assumption.
# Sliding a level camera down a tripod leg is a pure translation of the
# viewpoint: the ball simply lands higher in the frame, at the same scale, with
# the same vertical mapping. Nothing needs correcting.
#
# Aiming the camera *up* to compensate for the low mount is what breaks it. Now
# the sensor is oblique to the flight plane, vertical pixels stop mapping
# linearly to vertical metres, the horizontal scale stretches with height, and
# the launch angle is biased.
#
# That part is recoverable, because pitching a pinhole camera is a pure
# rotation about its own optical centre: the tilted and level views of the same
# world are related by a homography that depends on nothing but the tilt angle
# and the focal length — the IMU measures the first, the capture format's field
# of view gives the second. Rectifying each observation into the virtual level
# camera reproduces what a level camera at the same point would have recorded,
# after which everything downstream holds exactly as written.
#
# Derivation. Camera axes x right, y down, z along the optical axis; focal
# length f in pixels; image coordinates measured from the principal point. A
# camera pitched *down* by t has its basis, expressed in the level camera's
# frame,
#
#     x_t = (1, 0, 0)    y_t = (0, cos t, -sin t)    z_t = (0, sin t, cos t)
#
# so a ray the tilted camera reports as (u, v, f) is, in level coordinates,
# (u, v cos t + f sin t, f cos t - v sin t). Re-projecting through the same
# pinhole, with D = f cos t - v sin t:
#
#     u' = f u / D
#     v' = f (v cos t + f sin t) / D
#
# A sphere's projected diameter follows the transverse magnification du'/du,
# so the measured diameter rectifies the same way:
#
#     d' = d f / D
#
# which matters: the diameter is what sets the metres-per-pixel scale, so
# leaving it alone would correct the geometry and then apply the wrong ruler
# to it.
#
# This is exact for a pinhole. What it does not undo is lens distortion, which
# grows toward the frame edge and is where a large tilt pushes the flight —
# hence TILT_CORRECTABLE_MAX_DEG, past which the app keeps flagging the reading
# rather than claiming the correction rescued it.

TILT_CORRECTABLE_MAX_DEG = 20.0


def focal_px_from_fov(width_px: float, fov_deg: float) -> float:
    """Pinhole focal length in pixels, from the capture format's horizontal FOV.

    Returns 0.0 for unusable inputs, which callers treat as "no rectification".
    """
    if width_px <= 0 or not 0 < fov_deg < 180:
        return 0.0
    return (width_px / 2.0) / math.tan(math.radians(fov_deg) / 2.0)


def rectify_tilt_point(
    x: float, y: float, tilt_deg: float, focal_px: float, cx: float, cy: float
) -> tuple[float, float, float]:
    """Map one image point into the virtual level camera.

    Returns (x', y', magnification). The magnification is du'/du at that point:
    multiply any length measured there — a ball diameter — by it.

    tilt_deg is positive when the camera aims *down*, matching the IMU
    convention the app publishes.
    """
    if tilt_deg == 0.0 or focal_px <= 0:
        return x, y, 1.0
    t = math.radians(tilt_deg)
    u = x - cx
    v = y - cy
    d = focal_px * math.cos(t) - v * math.sin(t)
    if d <= 0:
        # The point is at or past the horizon of the rectified view. Only
        # reachable at tilts far beyond anything a tripod produces, and there
        # is nothing sensible to map it to, so leave it alone.
        return x, y, 1.0
    mag = focal_px / d
    return (cx + u * mag,
            cy + (v * math.cos(t) + focal_px * math.sin(t)) * mag,
            mag)


def rectify_tilt(
    track: list[BallObservation],
    tilt_deg: float,
    focal_px: float,
    cx: float,
    cy: float,
) -> list[BallObservation]:
    """Rectify a whole ball track into the virtual level camera.

    Frame index, time and area are carried through untouched — area is not used
    for measurement, only for candidate ranking, which happened before this.
    """
    if tilt_deg == 0.0 or focal_px <= 0:
        return list(track)
    out = []
    for o in track:
        x, y, mag = rectify_tilt_point(o.x, o.y, tilt_deg, focal_px, cx, cy)
        out.append(BallObservation(frame=o.frame, t=o.t, x=x, y=y,
                                   diameter_px=o.diameter_px * mag,
                                   area_px=o.area_px))
    return out


def analyze_track(
    track: list[BallObservation],
    contact_time: float | None = None,
    velocity_window_s: float = VELOCITY_WINDOW_S,
    gravity_window_s: float = GRAVITY_WINDOW_S,
    roll_deg: float = 0.0,
) -> SwingMetrics:
    """Turn a ball track into launch angle + exit velocity with confidence flags.

    contact_time: seconds; if None, the first tracked point is used (the ball
    may be occluded by the batter for the first frames — the quadratic fit
    extrapolates back to contact_time when it is earlier than the track start).

    Two fit windows:
      * velocity window (short): LA/EV evaluated at t0 — short keeps the
        constant-acceleration model honest against drag.
      * gravity window (long): the y(t) curvature needs time to accumulate
        (~1/2 g t^2); short line-drive windows have too little sag for a
        reliable per-swing gravity scale.
    """
    flags: list[str] = []
    n = len(track)
    t0 = contact_time if contact_time is not None else track[0].t
    ts = np.array([o.t for o in track]) - t0
    xs = np.array([o.x for o in track])
    ys = np.array([o.y for o in track])
    ds = np.array([o.diameter_px for o in track])
    duration = float(ts[-1] - ts[0])

    if n < MIN_TRACK_FRAMES:
        flags.append(FLAG_SHORT_TRACK)

    # --- velocity fit (windowed from t0) ---
    vel_sel = ts <= (ts[0] + velocity_window_s) if duration > velocity_window_s else np.ones_like(ts, bool)
    if int(vel_sel.sum()) < 3:
        vel_sel = np.ones_like(ts, bool)
    cx, rms_x = fit_quadratic(ts[vel_sel], xs[vel_sel])
    cy, rms_y = fit_quadratic(ts[vel_sel], ys[vel_sel])
    fit_rms = math.hypot(rms_x, rms_y)
    if fit_rms > RESIDUAL_TOL_PX:
        flags.append(FLAG_HIGH_RESIDUAL)

    # derivative of a t^2 + b t + c at t=0 (t0) is b
    vx = float(cx[1])
    vy = float(cy[1])          # down-positive

    # camera roll correction: rotate the velocity vector by +roll
    if roll_deg:
        r = math.radians(roll_deg)
        vx, vy = vx * math.cos(r) - vy * math.sin(r), vx * math.sin(r) + vy * math.cos(r)

    # --- diameter scale + depth drift ---
    q = max(2, n // 4)
    d_first = float(np.median(ds[:q]))
    d_last = float(np.median(ds[-q:]))
    diameter_drift = (d_last - d_first) / d_first if d_first > 0 else 0.0
    if abs(diameter_drift) > DIAMETER_DRIFT_TOL:
        flags.append(FLAG_DEPTH_MOTION)
    scale_ball = BALL_DIAMETER_M / d_first if d_first > 0 else float("nan")

    # --- gravity fit (longer window, drag-aware) ---
    grav_sel = ts <= (ts[0] + gravity_window_s)
    scale_gravity = None
    if duration >= MIN_GRAVITY_TRACK_S and int(grav_sel.sum()) >= 6:
        tg = ts[grav_sel]
        cyg, _ = fit_quadratic(tg, ys[grav_sel])
        cxg, _ = fit_quadratic(tg, xs[grav_sel])
        ay = 2.0 * float(cyg[0])            # px/s^2, down-positive
        # velocities at the window midpoint (where a quadratic's mean slope lives)
        tm = float((tg[0] + tg[-1]) / 2.0)
        vx_mid = 2.0 * float(cxg[0]) * tm + float(cxg[1])
        vy_mid = 2.0 * float(cyg[0]) * tm + float(cyg[1])
        scale_gravity = solve_gravity_scale(ay, vx_mid, vy_mid, scale_hint=scale_ball)
    if scale_gravity is None:
        flags.append(FLAG_NO_GRAVITY_CHECK)

    disagreement = None
    if scale_gravity is not None and scale_ball > 0:
        disagreement = abs(scale_gravity - scale_ball) / scale_ball
        if disagreement > SCALE_DISAGREE_TOL:
            flags.append(FLAG_SCALE_DISAGREE)

    # --- metrics (up-positive LA regardless of hit direction) ---
    la = math.degrees(math.atan2(-vy, abs(vx)))
    speed_mps = math.hypot(vx, vy) * scale_ball
    return SwingMetrics(
        launch_angle_deg=la,
        exit_velo_mph=speed_mps * MPH_PER_MPS,
        exit_velo_mps=speed_mps,
        scale_ball_m_per_px=scale_ball,
        scale_gravity_m_per_px=scale_gravity,
        scale_disagreement=disagreement,
        diameter_drift=diameter_drift,
        n_frames=n,
        track_duration_s=duration,
        fit_rms_px=fit_rms,
        t0=t0,
        vx_px_s=vx,
        vy_px_s=vy,
        x0_px=float(cx[2]),
        y0_px=float(cy[2]),
        flags=flags,
    )


# ---------------------------------------------------------------------------
# Flight physics (validation without a radar gun)
# ---------------------------------------------------------------------------

def simulate_flight(
    ev_mps: float,
    la_deg: float,
    contact_height_m: float = 0.9,
    dt: float = 0.002,
) -> tuple[float, float, float]:
    """Point-mass flight with quadratic drag (no spin/Magnus).

    Returns (carry_m, hang_s, apex_m). Used to sanity-check measured LA/EV
    against a paced-off landing distance and stopwatch hang time.
    """
    k = 0.5 * AIR_DENSITY * DRAG_CD * math.pi * (BALL_DIAMETER_M / 2) ** 2
    la = math.radians(la_deg)
    vx, vy = ev_mps * math.cos(la), ev_mps * math.sin(la)
    x, y, t, apex = 0.0, contact_height_m, 0.0, contact_height_m
    while y > 0.0 and t < 20.0:
        v = math.hypot(vx, vy)
        ax = -k / BALL_MASS_KG * v * vx
        ay = -G - k / BALL_MASS_KG * v * vy
        vx += ax * dt
        vy += ay * dt
        x += vx * dt
        y += vy * dt
        t += dt
        apex = max(apex, y)
    return x, t, apex


def vy0_from_hang_time(hang_s: float) -> float:
    """Vacuum estimate of initial vertical speed from hang time (vy0 = gT/2).

    Drag makes the true vy0 a bit larger than this; the +/-15% G3 tolerance
    absorbs that. Good enough as an independent cross-check, not calibration.
    """
    return G * hang_s / 2.0


# ---------------------------------------------------------------------------
# Bat / contact quality (Phase 3+)
# ---------------------------------------------------------------------------
#
# These turn the barrel-tape path (already tracked for attack angle) plus the
# ball exit velocity into the two metrics hitters actually chase: bat speed and
# contact quality. This is the b4-app / Blast / Statcast headline pairing, and
# SwingLab is unusual in measuring BOTH the bat and the ball from one phone, so
# it can report them together with no extra hardware.
#
# Honesty boundaries (see docs/BIOMECHANICS.md):
#  - Bat speed is the speed of the TAPE MARKER on the barrel, not a modelled
#    sweet-spot 6 in from the tip. Report it "at the tape", the same way
#    Statcast reports "at the sweet spot" — a defined, disclosed bat point.
#  - Smash factor here is the simple EV / bat-speed ratio (Driveline's hit-tool
#    form). It ignores pitch speed, so it is exact off a tee and only
#    approximate off live pitching, where the ball carries its own inbound
#    speed into the collision. Flagged, not hidden.

# Collision efficiency (smash factor) reference band. Driveline treats ~1.35-1.40
# as good bat-to-ball contact and < ~1.20 as poor; the rigid-bat physical
# ceiling sits around 1.4-1.5. These are coaching references, NOT slow-pitch
# population norms (none are published) — used only to colour a reading.
SMASH_POOR_BELOW = 1.20
SMASH_GOOD_LO = 1.35
SMASH_GOOD_HI = 1.45

# Slow-pitch line-drive launch window (degrees). A heavier ball at low bat
# speed makes MLB's 25-35 deg guidance misleading: fly balls die. Physics and
# coaching consensus put the productive slow-pitch window near 10-25 deg, with
# ~15-20 for max carry. Guidance for display colouring, not a validated norm.
SLOWPITCH_LAUNCH_LO = 10.0
SLOWPITCH_LAUNCH_HI = 25.0


def bat_speed_mps(vx_px_s: float, vy_px_s: float, scale_m_per_px: float) -> float:
    """Barrel-tape speed at contact, converted to m/s with the ball-size scale.

    vx/vy are the tape path's velocity components at t=0 (contact), in px/s,
    as fitted by BatTracker/analyze. The scale is the same [m/px] the ball
    pipeline already trusts, so no new calibration is introduced.
    """
    return math.hypot(vx_px_s, vy_px_s) * scale_m_per_px


def smash_factor(exit_velo_mps: float, bat_speed_mps_val: float) -> float | None:
    """Exit velocity divided by bat speed — collision efficiency (hit tool).

    Returns None when bat speed is non-positive (bat not tracked / bad fit),
    so callers show "—" rather than a divide-by-zero artefact.
    """
    if bat_speed_mps_val <= 0:
        return None
    return exit_velo_mps / bat_speed_mps_val


def smash_quality(smash: float | None) -> str:
    """Coarse label for a smash-factor reading: poor / fair / flush.

    "flush" borrows the b4-app framing for a well-struck ball. Boundaries are
    the coaching references above, not slow-pitch norms.
    """
    if smash is None:
        return "unknown"
    if smash < SMASH_POOR_BELOW:
        return "poor"
    if smash < SMASH_GOOD_LO:
        return "fair"
    return "flush"


def in_slowpitch_launch_window(launch_angle_deg: float) -> bool:
    """True when a launch angle sits in the slow-pitch line-drive band."""
    return SLOWPITCH_LAUNCH_LO <= launch_angle_deg <= SLOWPITCH_LAUNCH_HI


# ---------------------------------------------------------------------------
# Contact offset ("undercut") — the side-view-honest half of b4-app's
# Bat Contact Point
# ---------------------------------------------------------------------------
#
# b4-app reports WHERE on the bat the ball struck (knob-to-tip ratio). From a
# side-on camera the bat points nearly along the optical axis at contact, so
# the knob-to-tip axis is foreshortened and that ratio is not honestly
# measurable here. What the side view measures WELL is the VERTICAL offset
# between the barrel centre and the ball centre at contact — Alan Nathan's
# "undercut distance", the quantity that decides topped vs flush vs popup and
# sets backspin. Sign: positive = barrel centre passed BELOW the ball centre.
#
# The barrel position at contact comes from the tape-path fit evaluated at t0,
# the ball position from the velocity fit at t0 (x0_px/y0_px). Caveat, stated
# in the UI: the tape centroid stands in for the barrel at the contact point,
# so the reading is accurate when contact happens near the tape — which is why
# CAPTURE_PROTOCOL.md puts the tape at the sweet spot. Bat droop between tape
# and true contact point adds bias when contact is far from the tape; the
# plausibility gate below catches the gross cases.

BAT_BARREL_DIAMETER_M = 2.25 * 0.0254   # max legal slow-pitch barrel (57 mm)

# Centres farther apart than the two radii cannot have touched: the tape was
# not at the contact point (or a fit went wrong). Reading is discarded.
CONTACT_PLAUSIBLE_M = (BALL_DIAMETER_M + BAT_BARREL_DIAMETER_M) / 2

# Undercut bands (metres). Nathan's collision model puts max-carry undercut
# around 13-30 mm for typical bat/ball speeds; near-centred contact makes
# line drives; hitting the top half tops the ball into the ground. Coaching
# guidance for labels, NOT validated slow-pitch norms.
UNDERCUT_TOPPED_BELOW_M = -0.006    # barrel > 6 mm above centre -> topped
UNDERCUT_CENTERED_MAX_M = 0.010     # -6..+10 mm -> centred, line-drive zone
UNDERCUT_CARRY_MAX_M = 0.030        # 10-30 mm -> backspin carry zone
                                    # beyond -> under the ball, popup territory

CONTACT_UNKNOWN = "unknown"
CONTACT_IMPLAUSIBLE = "implausible"
CONTACT_TOPPED = "topped"
CONTACT_CENTERED = "centered"
CONTACT_UNDER_CARRY = "under_carry"
CONTACT_UNDER_POPUP = "under_popup"


def undercut_m(ball_y0_px: float, bat_y0_px: float, scale_m_per_px: float) -> float:
    """Vertical offset of barrel centre below ball centre at contact (metres).

    Image y grows DOWN, so bat_y0 > ball_y0 means the barrel was below the
    ball centre -> positive undercut -> backspin/loft.
    """
    return (bat_y0_px - ball_y0_px) * scale_m_per_px


def contact_quality(u_m: float | None) -> str:
    """Label an undercut reading. None -> unknown; beyond the geometric
    plausibility limit -> implausible (discard, don't display)."""
    if u_m is None:
        return CONTACT_UNKNOWN
    if abs(u_m) > CONTACT_PLAUSIBLE_M:
        return CONTACT_IMPLAUSIBLE
    if u_m < UNDERCUT_TOPPED_BELOW_M:
        return CONTACT_TOPPED
    if u_m <= UNDERCUT_CENTERED_MAX_M:
        return CONTACT_CENTERED
    if u_m <= UNDERCUT_CARRY_MAX_M:
        return CONTACT_UNDER_CARRY
    return CONTACT_UNDER_POPUP


# ---------------------------------------------------------------------------
# Video + CSV I/O
# ---------------------------------------------------------------------------

def open_video(path: str, fps_override: float | None = None):
    """Open a clip and return (cap, fps, n_frames, width, height).

    iPhone slo-mo metadata sometimes reports 30/60 fps even though every
    240fps frame is present (depends on how the clip was exported). AirDrop
    the ORIGINAL file; if the detected fps looks wrong, pass --fps 240.
    """
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise IOError(f"cannot open video: {path}")
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    if fps_override:
        fps = float(fps_override)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    return cap, fps, n, w, h


def write_track_csv(path: str, track: list[BallObservation], fps: float, meta: dict | None = None):
    with open(path, "w", newline="") as f:
        for k, v in (meta or {}).items():
            f.write(f"# {k}={v}\n")
        f.write(f"# fps={fps}\n")
        w = csv.writer(f)
        w.writerow(["frame", "t", "x_px", "y_px", "diameter_px", "area_px"])
        for o in track:
            w.writerow([o.frame, f"{o.t:.6f}", f"{o.x:.2f}", f"{o.y:.2f}",
                        f"{o.diameter_px:.2f}", f"{o.area_px:.1f}"])


def read_track_csv(path: str) -> tuple[list[BallObservation], dict]:
    meta: dict = {}
    track: list[BallObservation] = []
    with open(path) as f:
        rows = []
        for line in f:
            if line.startswith("#"):
                if "=" in line:
                    k, v = line[1:].strip().split("=", 1)
                    meta[k.strip()] = v.strip()
                continue
            rows.append(line)
    reader = csv.DictReader(rows)
    for r in reader:
        track.append(BallObservation(
            int(r["frame"]), float(r["t"]), float(r["x_px"]), float(r["y_px"]),
            float(r["diameter_px"]), float(r["area_px"]),
        ))
    return track, meta
