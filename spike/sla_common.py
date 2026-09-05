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

# Optic yellow in OpenCV HSV (H: 0-179). Still generous — tighten per venue —
# but no longer wide enough to swallow grass, which the first window did:
# measured on real field footage, sunlit grass sits at ~H36 S89 V133 and the
# old ceiling (H<=48, S>=70, V>=120) admitted it wholesale. 18% of the frame
# lit up and the largest "ball-coloured" blob was the lawn. The ball itself
# measured H29-34, S~170, V~240: fluorescent yellow is far more SATURATED than
# any vegetation, so S>=100 is the separator that costs nothing, and H<=40
# still clears real optic yellow (~22-35) with margin.
HSV_LO_DEFAULT = (18, 100, 120)
HSV_HI_DEFAULT = (40, 255, 255)

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
FLAG_CONTACT_TIME_REJECTED = "CONTACT_TIME_REJECTED"

# How far before the track's first sighting a supplied contact time may sit
# before it stops being believable.
#
# The reason to extrapolate backwards at all is occlusion: the ball leaves the
# bat behind the hitter's body and the first frames of the flight are hidden,
# so the fit is evaluated at contact rather than at the first sighting. That is
# a handful of frames. 60 ms is fourteen at 240fps — a ball leaving at 25 px a
# frame stays hidden for 350 px of travel, which is wider than a hitter is in a
# 1280-wide frame.
#
# Beyond that the number is not an occlusion correction, it is a false trigger.
# Measured on IMG_6703: a 17 dB noise 0.5 s before contact fires the trigger at
# the default threshold, the refractory window then covers the real 37 dB crack,
# and the clip is saved with a contact time half a second early. Handed to the
# fit, that same 30-frame track reported +4.25 deg and 105.26 mph instead of
# -5.83 deg and 70.96 mph — a 48% exit-velocity inflation — WITH THE SAME FLAGS
# as the correct answer. Nothing in the output told the two apart.
CONTACT_MAX_BACK_EXTRAPOLATION_S = 0.06


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

# Motion gating: keep only pixels that MOVED.
#
# The single largest source of false candidates on real footage, measured on
# two field clips: sunlit grass and sunlit foliage are the ball's colour, and
# they are everywhere. Without a motion gate those clips yielded 129 and 131
# candidates PER FRAME and roughly a thousand candidate tracks, among which
# choosing the ball is guesswork — the tree canopy alone produced round,
# ball-sized blobs sitting at the same pixel for the entire clip.
#
# A ball is the one ball-coloured thing in the frame that MOVES. Differencing
# consecutive frames removes everything that does not, and on those same clips
# it cut a thousand candidate tracks to three and six, with the survivor
# tracking the ball at straightness 1.00.
#
# Frame differencing rather than MOG2 on purpose: it needs one previous frame
# instead of a learned model, it cannot drift or need warm-up, it costs one
# subtract per pixel, and it ports to Swift without a computer-vision library.
# What it gives up — segmenting slow-moving objects — does not matter here,
# because the thing being found is the fastest object in the picture.
MOTION_DIFF_THRESHOLD = 18      # 8-bit luma change that counts as movement
MOTION_DILATE_PX = 3            # grow the moving region to cover the whole ball


def motion_mask(
    gray: np.ndarray,
    prev_gray: np.ndarray | None,
    threshold: int = MOTION_DIFF_THRESHOLD,
    dilate_px: int = MOTION_DILATE_PX,
) -> np.ndarray | None:
    """Pixels that changed since the previous frame, dilated.

    `None` for the first frame, which has nothing to difference against — the
    caller should detect without a gate rather than skip the frame.

    The dilation matters more than it looks: differencing marks the ball's
    LEADING and TRAILING edges, and the middle of a smoothly-coloured ball
    barely changes between frames. Growing the mask closes it back into one
    blob, so the colour stage sees a whole ball rather than two crescents that
    fail the roundness gate.

    `dilate_px` must be odd. An even kernel has no centre pixel, so OpenCV
    anchors it at ``(k//2, k//2)`` and grows the mask ONE-SIDEDLY — 2 gives a
    3x3 block offset down and right of the moved pixel, not a centred one. The
    Swift port (`MotionMask.mask`) dilates with a symmetric radius, which is
    exact for odd kernels and wrong for even ones, and the difference is not
    cosmetic: the gate decides which blobs survive, and a differently-cut blob
    has a different minor axis, which is the ball diameter, which is the scale
    behind every number the app reports. Refused rather than silently
    diverging, because the only thing that would notice is a field trip.
    """
    if prev_gray is None:
        return None
    if dilate_px > 0 and dilate_px % 2 == 0:
        raise ValueError(
            f"dilate_px must be odd (got {dilate_px}); "
            "even kernels dilate one-sidedly in OpenCV and the Swift port "
            "cannot reproduce that with a symmetric radius"
        )
    diff = cv2.absdiff(gray, prev_gray)
    mask = (diff > threshold).astype(np.uint8) * 255
    if dilate_px > 0:
        k = np.ones((dilate_px, dilate_px), np.uint8)
        mask = cv2.dilate(mask, k, iterations=2)
    return mask


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

# A moving track may not be extended by a candidate that lies behind it.
#
# This is the guard that keeps the PITCH out of the HIT. At contact the ball is
# spatially continuous — it is in very nearly the same place on both sides of
# the collision — and only its direction reverses. Nearest-neighbour
# association does not look at direction, so it walked the incoming pitch
# straight through contact and out the other side, producing one "track" whose
# first half travels left at 2,700 px/s and whose second half travels right at
# 6,300 px/s. Everything downstream then fits a single flight to two different
# flights: a bogus launch angle, a bogus speed, and a track long enough to win
# selection against the clean one.
#
# `stitch_tracks` already refuses exactly this join (STITCH_MAX_ANGLE_DEG), but
# it only ever saw separate fragments. Contact never produced two fragments, so
# that guard never got a vote.
#
# Deliberately loose. It exists to refuse a REVERSAL, not to enforce smoothness:
# a real flight at 240fps turns a fraction of a degree per frame (gravity moves
# 30 m/s by 0.04), so 60 deg is roughly a hundred times more turn than any ball
# in flight needs, and a bounce off the ground or a bat is well past it. A
# tighter cone would start rejecting the noisy first step of a young track for
# no gain.
BUILD_MAX_TURN_DEG = 60.0
# ...and below this step the direction of travel is noise, not a heading.
#
# Per FRAME, not per second, and that is the whole point: a blob's apparent
# heading comes from centroid noise of a pixel or two between frames, which is
# a fixed number of pixels however fast the camera runs. Expressed per second
# the same jitter reads 400 px/s at 199fps and 5,000 px/s at 240fps on a wider
# lens, and any threshold picked for one clip is wrong for the next. Five
# pixels a frame is a few times the centroid noise and well under the incoming
# pitch, which runs 11.
BUILD_TURN_MIN_STEP_PX = 5.0

# Observations the heading is fitted over.
#
# NOT the last pair, and this is the whole of a real failure. On a field clip
# the ball arrived down-left at 10 px a frame, and on the very last step before
# contact it moved 4.98 — because the last step before contact is exactly when
# the ball is slowest. Read from that one pair the heading fell 0.02 px under
# the floor, the guard switched itself off for that frame, and association
# walked straight through the reversal: one 59-frame "track", half of it the
# incoming ball and half the struck one, straightness 0.33, reported as a swing
# at -37.9 degrees.
#
# A heading is a property of where a track has been going, not of its last two
# points, and the noisiest single step is the one that matters most. Fitted
# over five the same moment reads 8.98 px a frame and the reversal is refused
# at 151 degrees. This also makes the floor stricter against clutter rather
# than looser: jitter that alternates direction averages toward zero over a
# window, where a single lucky pair can look like travel.
BUILD_HEADING_WINDOW = 5


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

    A track that is moving will not accept a candidate behind it — see
    BUILD_MAX_TURN_DEG.
    """
    active: list[dict] = []     # {obs: [...], last_frame: int}
    done: list[list[BallObservation]] = []

    for f in sorted(per_frame.keys()):
        cands = list(per_frame[f])
        claimed = [False] * len(cands)

        # Every (track, candidate) pair inside its gate, then assign the
        # CLOSEST pairs first — not the first track's best, then the second
        # track's best, and so on.
        #
        # Track order used to decide it, and on a cluttered frame that hands
        # the ball to the grass. A stationary false positive predicts its own
        # last position and carries the 40 px base gate; a ball crossing at 30+
        # px per frame passes within that of dozens of them. Whichever clutter
        # track happened to be seeded first would claim the ball, the real
        # track would coast and die, and the ball would end up as a couple of
        # stolen points inside a blob that never moved. It only became fatal
        # when the search went full-frame and candidate counts went from a
        # handful to seventy-odd per frame, which is exactly when a ball in
        # plain sight started reading as "found here, none used".
        #
        # Sorting by distance fixes it without any new threshold: the ball
        # matches its own prediction within a few pixels, and no clutter track
        # gets to bid before that pair is settled. Ties break on track index
        # then candidate index, so this stays deterministic and the Swift port
        # can reproduce it exactly.
        pairs: list[tuple[float, int, int]] = []
        for ti, tr in enumerate(active):
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
            speed = math.hypot(vx, vy)
            speed_px_fr = speed / fps
            gate = max(base_gate_px, 2.5 * speed_px_fr) * gap

            # The GATE keeps the last-pair velocity: it is a prediction of
            # where the object will be next, and the freshest estimate is the
            # right one for that. The HEADING is fitted over a window, because
            # it answers a different question — which way has this been going —
            # and the last pair is the worst possible evidence for it right at
            # a reversal. See BUILD_HEADING_WINDOW.
            hvx, hvy = _segment_velocity(obs[-BUILD_HEADING_WINDOW:])
            heading_speed = math.hypot(hvx, hvy)
            heading = heading_speed / fps >= BUILD_TURN_MIN_STEP_PX
            cos_max = math.cos(math.radians(BUILD_MAX_TURN_DEG))

            in_gate: list[tuple[float, int]] = []
            for ci, c in enumerate(cands):
                d = math.hypot(c.x - pred_x, c.y - pred_y)
                if d < gate:
                    in_gate.append((d, ci))
            in_gate.sort()

            if heading and in_gate:
                # A track that cannot be extended forwards COASTS. It does not
                # swerve onto the next candidate along.
                #
                # Rejecting the nearest candidate and letting the track take
                # the runner-up is worse than not filtering at all: on a lawn
                # of jittering blobs it walked tracks from one clutter blob to
                # the NEXT ONE 90 px away, every frame, in a straight line —
                # manufacturing a fast, perfectly straight 16,000 px/s track
                # out of stationary grass, which then won selection against the
                # real ball. Refusing the whole frame is the rule that matches
                # the intent: the track lost sight of its object.
                d0, ci0 = in_gate[0]
                c0 = cands[ci0]
                sx, sy = c0.x - obs[-1].x, c0.y - obs[-1].y
                step = math.hypot(sx, sy)
                if step > 1e-9 and (sx * hvx + sy * hvy) / (step * heading_speed) < cos_max:
                    continue

            for d, ci in in_gate:
                pairs.append((d, ti, ci))

        pairs.sort()
        matched_tracks: set[int] = set()
        for _d, ti, ci in pairs:
            if ti in matched_tracks or claimed[ci]:
                continue
            active[ti]["obs"].append(cands[ci])
            claimed[ci] = True
            matched_tracks.add(ti)

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


# Stitching: re-joining fragments of one flight that detection gaps broke apart.
#
# A ball crossing a busy background — trees, buildings, its own motion blur —
# drops out of detection for a few frames at a time. The builder only coasts
# MAX_COAST_FRAMES, so each detected burst becomes its own short track, and on
# real footage the hit arrived as 5-9 frame pieces that all died on the
# MIN_TRACK_FRAMES gate while a slow landing bounce won selection. The pieces
# individually said everything needed to join them: a fragment ending at
# 7,200 px/s rightward, and another starting a few frames later on the same
# line at the same speed, are one object.
#
# The gates are deliberately about KINEMATIC CONSISTENCY, not proximity alone:
#   - the gap must be short (a flight that vanishes for half a second is two
#     events, not one);
#   - extrapolating the earlier fragment's velocity across the gap must land
#     near where the later one starts (constant velocity is accurate here —
#     gravity bends the path by ~1 px over the gaps involved);
#   - the two velocities must agree to within what gravity could have changed
#     them by over the gap. A pitch-into-hit reverses direction at contact and
#     fails outright. A bounce is NOT as safe as this comment once claimed: a
#     shallow 10-degree descent rebounding 7 degrees up is only a 17-degree
#     turn, which the old 40-degree gate waved through — the physics bound is
#     what actually refuses it, because bouncing changes velocity by far more
#     than gravity can in 0.1 s.
STITCH_MAX_GAP_S = 0.10          # longest detection dropout worth bridging
STITCH_BASE_TOL_PX = 30.0        # position slack at zero gap
STITCH_TOL_PX_PER_S = 0.35       # extra slack per px/s of speed, times gap
STITCH_MAX_ANGLE_DEG = 40.0      # cone the hop between fragments must lie in

# Velocity agreement, bounded by PHYSICS rather than by taste.
#
# Adversarial testing found the old ratio-and-angle pair (2x, 40 deg) to be
# about two orders of magnitude looser than the thing it claimed to model. Over
# a 0.10 s gap gravity can change a real flight's velocity by g*gap and no
# more — a percent or two in speed, a couple of degrees in direction — so a
# gate admitting a doubling and a 40-degree turn admits almost anything moving.
# What it actually admitted, with runnable repros: an ordinary pigeon crossing
# 35 ms after the ball (blended track, launch angle 39 deg against a truth of
# 28, and no flag raised because the fit residual stayed under threshold); a
# shallow landing bounce, falsifying this file's own claim that the flight
# "correctly ENDS at the landing"; and eight bursts strung along a 160-degree
# arc, because a 40-degree limit per join composes without limit over a chain.
#
# The bound is |v_b - v_a| <= K * g_px * gap + noise floor, with g in pixels
# recovered from the ball's own measured diameter — the same trick the scale
# estimate uses. K carries drag and the noise floor carries the residual
# velocity error of a short fragment, which is the honest reason a real join
# is never exactly zero.
STITCH_ACCEL_K = 3.0
STITCH_VELOCITY_NOISE_PX_S = 400.0


def _segment_velocity(seg: list[BallObservation]) -> tuple[float, float]:
    """Least-squares linear velocity over a run of points, px/s.

    A least-squares slope, not an endpoint difference, because fragments are
    exactly where endpoint differences fail. A 5-frame burst with a few pixels
    of detection noise on each end carries velocity noise of hundreds of px/s
    when read from two points — enough to swing the stitch gates at random —
    while the same noise averaged over every point in the fit barely moves the
    slope. On clean tracks the two are identical, which is what keeps the
    noise-free parity fixtures unchanged.
    """
    n = len(seg)
    if n < 2:
        return (0.0, 0.0)
    # Explicit left-to-right accumulation, NOT sum(). CPython 3.12 gave sum()
    # Neumaier compensated summation for floats; the Swift port uses a naive
    # reduce. They agree today only because the fixtures were generated on
    # 3.11 — regenerating them on a newer interpreter would silently introduce
    # a parity drift that no test names. Spelling the loop out costs nothing
    # and makes the two bit-identical by construction.
    acc = 0.0
    for o in seg:
        acc += o.t
    mean_t = acc / n
    acc = 0.0
    for o in seg:
        acc += (o.t - mean_t) ** 2
    var_t = acc
    if var_t <= 1e-12:
        return (0.0, 0.0)
    ax = 0.0
    ay = 0.0
    for o in seg:
        ax += (o.t - mean_t) * o.x
        ay += (o.t - mean_t) * o.y
    return (ax / var_t, ay / var_t)


# Endpoint window: enough points to average the noise down, few enough to stay
# LOCAL — a long curving track's end velocity must not be polluted by its
# middle.
STITCH_VELOCITY_WINDOW = 6


def _track_end_velocity(tr: list[BallObservation]) -> tuple[float, float]:
    return _segment_velocity(tr[-STITCH_VELOCITY_WINDOW:])


def _track_start_velocity(tr: list[BallObservation]) -> tuple[float, float]:
    return _segment_velocity(tr[:STITCH_VELOCITY_WINDOW])


def _stitch_error(a: list[BallObservation], b: list[BallObservation]) -> float | None:
    """Extrapolation error of joining b onto a, in px — or None if the gates
    refuse the join outright.

    Returns the error rather than a bool so the CHOICE between competing
    chains can be made on fit quality. An adversarial test built two
    interleaved flights sharing a detection dropout and showed the old
    yes/no answer let recency decide instead: each flight's continuation was
    stitched onto the OTHER flight — a chimera with a plausible speed, a
    plausible straightness and a launch angle 19 degrees wrong, unflagged —
    even though the true joins measured ~0 px of error against 26-40 px for
    the steals. The number that settles it was already computed and then
    thrown away.
    """
    gap = b[0].t - a[-1].t
    if gap <= 0 or gap > STITCH_MAX_GAP_S:
        return None
    vax, vay = _track_end_velocity(a)
    vbx, vby = _track_start_velocity(b)
    speed_a = math.hypot(vax, vay)
    speed_b = math.hypot(vbx, vby)
    if speed_a <= 1e-9 or speed_b <= 1e-9:
        return None
    # Gravity, in pixels, from the ball's own apparent size.
    diameters = sorted([o.diameter_px for o in a] + [o.diameter_px for o in b])
    median_d = diameters[len(diameters) // 2]
    if median_d <= 1e-9:
        return None
    g_px = G * median_d / BALL_DIAMETER_M

    # Velocity agreement, bounded by what gravity can actually do in `gap`.
    jump = math.hypot(vbx - vax, vby - vay)
    if jump > STITCH_ACCEL_K * g_px * gap + STITCH_VELOCITY_NOISE_PX_S:
        return None

    # The hop itself must go the way the ball was going. Without this the
    # position tolerance is direction-blind, and a run of clutter bursts each
    # sitting 29 px "ahead" of a leftward prediction stitches into a chain with
    # a manufactured rightward net velocity — one that then wins selection as
    # the hit, on a clip where the pre-stitch answer was correctly nothing.
    hop_x = b[0].x - a[-1].x
    hop_y = b[0].y - a[-1].y
    hop = math.hypot(hop_x, hop_y)
    if hop > 4.0:
        coshop = (vax * hop_x + vay * hop_y) / (speed_a * hop)
        if coshop < math.cos(math.radians(STITCH_MAX_ANGLE_DEG)):
            return None

    # Predict WITH gravity: over 0.1 s at these scales it is a real number of
    # pixels, and leaving it out biases every join in the same direction.
    pred_x = a[-1].x + vax * gap
    pred_y = a[-1].y + vay * gap + 0.5 * g_px * gap * gap
    tol = STITCH_BASE_TOL_PX + STITCH_TOL_PX_PER_S * speed_a * gap
    err = math.hypot(b[0].x - pred_x, b[0].y - pred_y)
    return err if err <= tol else None


def stitch_tracks(tracks: list[list[BallObservation]]) -> list[list[BallObservation]]:
    """Join fragments of one flight: repeatedly make the best-fitting join
    anywhere, until no join fits.

    Globally greedy on the extrapolation error, NOT a per-fragment sweep, and
    adversarial testing is why. A sweep in start-time order answers "which
    chain should this fragment join?" — but the symmetric question, "which of
    two competing fragments is this chain's true continuation?", was then
    settled by processing order, which traced back to a raw y coordinate in
    the sort key. A 40 px join could beat a 0 px join by sorting first. Making
    the globally smallest-error join first answers both questions with the
    same number.

    Deterministic for the Swift port: chains keep a stable order (a merged
    chain replaces its earlier member; the later member is removed), and ties
    on error break by lower chain-pair indices.
    """
    chains = [list(tr) for tr in
              sorted(tracks, key=lambda tr: (tr[0].t, tr[0].x, tr[0].y))]
    while True:
        best_err = math.inf
        best_i = -1
        best_j = -1
        for i, a in enumerate(chains):
            # Each chain bids for its EARLIEST-STARTING stitchable successor
            # only. Without this the globally smallest error could pick the
            # skip-join A->C over the adjacent A->B when a couple of pixels of
            # jitter made it marginally tighter — after which B lies inside the
            # merged chain's span, can never join anything, and its
            # observations are silently lost. Measured at 6.9% of trials on
            # this file's own fixture layout.
            cand_j = -1
            cand_key = None
            for j, b in enumerate(chains):
                if i == j:
                    continue
                err = _stitch_error(a, b)
                if err is None:
                    continue
                key = (b[0].t, err, j)
                if cand_key is None or key < cand_key:
                    cand_key, cand_j = key, j
            if cand_j < 0:
                continue
            err = cand_key[1]
            if err < best_err or (err == best_err and (i, cand_j) < (best_i, best_j)):
                best_err = err
                best_i, best_j = i, cand_j
        if best_i < 0:
            return chains
        chains[best_i] = chains[best_i] + chains[best_j]
        del chains[best_j]


# Seeded tracking: building the ball's track outward from a point a human
# pointed at.
#
# This exists because automatic SELECTION is the part that cannot be made
# reliable on cluttered footage, and it is the part a human can settle in one
# tap. On a phone lying in the grass, a frame yields ~70 ball-coloured blobs;
# the flight is detected but arrives as short bursts among them, and every
# scoring rule tried — longest, speed*length, speed with straightness and
# direction gates — is a heuristic guess at which of hundreds of tracks is the
# ball. A tap is not a guess. It is a measurement of the one thing the
# pipeline genuinely cannot infer.
#
# So the gates here are deliberately LOOSE compared to build_tracks. The
# expensive ambiguity is already resolved: we know which object we are
# following. What remains is only to follow it, and being timid about that
# would throw away the certainty the tap just bought.
# How near the tap a candidate must be to BE the ball.
#
# Frame-relative, because the fixed 45 px this started as was a target 14
# POINTS wide on a phone — a clip 1280 px across is shown about 390 pt wide, so
# one clip pixel is a third of a point, and the ball itself is 8 pt. A fingertip
# is around 44 pt. Tapping the ball dead-centre by eye still landed outside the
# radius, found nothing, and fell back to the automatic pick, which was the
# grass the tap existed to overrule. The floor stays for tiny frames; the
# fraction is what makes it reachable.
SEED_SEARCH_RADIUS_PX = 45.0
SEED_SEARCH_RADIUS_FRAC = 0.06   # of frame width — about 22 pt on screen
SEED_GATE_BASE_PX = 70.0        # association gate before any velocity is known
# ...and a far tighter one once it IS known. A constant-velocity prediction for
# a ball is accurate to a few pixels per frame — gravity bends it by ~0.02
# px/frame^2 at these scales, so the residual is detection noise, not physics.
# Keeping the loose 70 px gate after the velocity was known let a blob 50 px
# off the prediction win, and one such blob poisons the velocity estimate for
# every step after it.
SEED_GATE_PREDICTED_PX = 22.0
SEED_GATE_SPEED_MULT = 0.6      # ...growing gently with the ball's own speed
SEED_MAX_COAST_FRAMES = 8       # a ball may vanish this long and still be followed

# Once the ball's velocity IS known, a candidate must be consistent with it —
# proximity alone is not enough. Adversarial testing found the reason: walking
# BACKWARD from a tap, the flight ends at contact, and the walk then latched
# onto whatever grass sat near its next prediction, recomputed a near-zero
# velocity from that, and strolled through clutter across the entire clip —
# 459 frames for a 20-frame flight. Requiring the implied step velocity to
# stay within a band of the current one terminates the walk exactly where the
# ball stops existing, which is the correct answer at both ends: at contact
# going back, and at the frame edge going forward.
SEED_SPEED_RATIO_MAX = 1.8
SEED_MAX_TURN_DEG = 25.0


def seed_search_radius_px(frame_width_px: float) -> float:
    """Tap tolerance for this frame size."""
    return max(SEED_SEARCH_RADIUS_PX, frame_width_px * SEED_SEARCH_RADIUS_FRAC)


def _seed_observation(
    per_frame: dict[int, list[BallObservation]],
    seed_t: float,
    seed_x: float,
    seed_y: float,
    radius_px: float = SEED_SEARCH_RADIUS_PX,
) -> BallObservation | None:
    """The detected candidate a tap refers to.

    Searches the nearest frames outward in time, not just the exact one: a tap
    lands on a playhead that may sit between decoded frames, and the ball is
    only detected in some of them.
    """
    if not per_frame:
        return None
    frames = sorted(per_frame.keys())
    times = {f: (per_frame[f][0].t if per_frame[f] else 0.0) for f in frames}
    # Frames ordered by |t - seed_t|, then by frame number for determinism.
    ordered = sorted(frames, key=lambda f: (abs(times[f] - seed_t), f))
    for f in ordered[:12]:
        best = None
        best_d = radius_px
        for c in per_frame[f]:
            d = math.hypot(c.x - seed_x, c.y - seed_y)
            if d < best_d:
                best, best_d = c, d
        if best is not None:
            return best
    return None


def _follow(
    per_frame: dict[int, list[BallObservation]],
    start: BallObservation,
    fps: float,
    forward: bool,
) -> list[BallObservation]:
    """Walk one direction in time from a known observation, greedily."""
    chain = [start]
    frames = sorted(per_frame.keys())
    if not forward:
        frames = list(reversed(frames))
    step = 1 if forward else -1

    for f in frames:
        if (f - chain[-1].frame) * step <= 0:
            continue
        gap = abs(f - chain[-1].frame)
        if gap > SEED_MAX_COAST_FRAMES:
            break
        last = chain[-1]
        if len(chain) >= 2:
            prev = chain[-2]
            dt = last.t - prev.t
            vx = (last.x - prev.x) / dt if dt != 0 else 0.0
            vy = (last.y - prev.y) / dt if dt != 0 else 0.0
        else:
            vx = vy = 0.0
        dt_pred = gap * step / fps
        pred_x = last.x + vx * dt_pred
        pred_y = last.y + vy * dt_pred
        speed_px_fr = math.hypot(vx, vy) / fps
        if len(chain) >= 2:
            gate = max(SEED_GATE_PREDICTED_PX, SEED_GATE_SPEED_MULT * speed_px_fr) * gap
        else:
            # Nothing known yet but the tap itself — reach further to find the
            # ball's next sighting, then tighten immediately.
            gate = SEED_GATE_BASE_PX * gap

        speed_now = math.hypot(vx, vy)
        best = None
        best_d = gate
        for c in per_frame[f]:
            d = math.hypot(c.x - pred_x, c.y - pred_y)
            if d >= best_d:
                continue
            if speed_now > 1e-9:
                # The step this candidate implies, in the direction of travel.
                cvx = (c.x - last.x) / dt_pred
                cvy = (c.y - last.y) / dt_pred
                speed_c = math.hypot(cvx, cvy)
                if speed_c <= 1e-9:
                    continue
                ratio = speed_c / speed_now
                if not (1.0 / SEED_SPEED_RATIO_MAX <= ratio <= SEED_SPEED_RATIO_MAX):
                    continue
                cosang = (vx * cvx + vy * cvy) / (speed_now * speed_c)
                if cosang < math.cos(math.radians(SEED_MAX_TURN_DEG)):
                    continue
            best, best_d = c, d
        if best is not None:
            chain.append(best)
    return chain


# A seeded track is known to be ONE object in ballistic flight — the tap said
# so. That justifies a check the generic pipeline cannot make: fit the physical
# model (x linear in t, y quadratic in t) and drop points that do not lie on
# it. Without this the walk keeps the few clutter blobs it grabbed at each end,
# where the ball stops existing, and they drag the launch angle by degrees.
SEED_OUTLIER_MIN_PX = 4.0       # never prune tighter than detection noise
SEED_OUTLIER_SIGMA = 3.0        # ...or looser than this many typical residuals


def _prune_to_ballistic(track: list[BallObservation], passes: int = 2) -> list[BallObservation]:
    """Drop observations that do not lie on the track's own ballistic fit."""
    out = list(track)
    for _ in range(passes):
        if len(out) < 5:
            return out
        ts = [o.t for o in out]
        t0 = ts[0]
        rel = [t - t0 for t in ts]
        # x is linear in t, y is quadratic — the physical model, not a
        # y-versus-x curve, which is ill-conditioned for a steep flight.
        #
        # Every accumulation below is spelled out left-to-right rather than
        # handed to sum(), for the reason `_segment_velocity` gives: CPython
        # 3.12 gave sum() Neumaier compensated summation for floats and the
        # Swift port (`TrackBuilder.pruneToBallistic`) uses a naive reduce.
        # This function is where that matters MOST, not least: the seed_track
        # fixtures pin discrete outputs — expected_len, expected_first_frame,
        # expected_last_frame — so a last-ulp difference in a residual that
        # happens to land on `limit` keeps an observation on one side and drops
        # it on the other, and the parity failure is an integer mismatch with
        # nothing anywhere naming the cause.
        n = len(out)
        acc = 0.0
        for t in rel:
            acc += t
        mean_t = acc / n
        var_t = 0.0
        for t in rel:
            var_t += (t - mean_t) ** 2
        if var_t <= 1e-12:
            return out
        num = 0.0
        for i in range(n):
            num += (rel[i] - mean_t) * out[i].x
        vx = num / var_t
        sum_x = 0.0
        for o in out:
            sum_x += o.x
        x0 = sum_x / n - vx * mean_t
        coeffs, _rms = fit_quadratic(np.asarray(rel), np.asarray([o.y for o in out]))
        res = []
        for i, o in enumerate(out):
            px = x0 + vx * rel[i]
            py = float(np.polyval(coeffs, rel[i]))
            res.append(math.hypot(o.x - px, o.y - py))
        ordered = sorted(res)
        median = ordered[len(ordered) // 2]
        # Capped by the ball's own size: a detection more than one diameter off
        # the flight it supposedly belongs to is a different object, however
        # noisy the rest of the track happens to be.
        diameters = sorted(o.diameter_px for o in out)
        cap = max(SEED_OUTLIER_MIN_PX, diameters[len(diameters) // 2])
        limit = max(SEED_OUTLIER_MIN_PX, min(SEED_OUTLIER_SIGMA * median, cap))
        kept = [o for o, r in zip(out, res) if r <= limit]
        if len(kept) == len(out) or len(kept) < 5:
            return out if len(kept) < 5 else kept
        out = kept
    return out


def track_from_seed(
    per_frame: dict[int, list[BallObservation]],
    fps: float,
    seed_t: float,
    seed_x: float,
    seed_y: float,
    frame_width_px: float = 1920.0,
) -> list[BallObservation] | None:
    """The ball's track, followed both ways from a point a human pointed at.

    Returns None only when nothing was DETECTED near the tap — which is a
    genuine detection failure and says so, as distinct from the detector
    having found the ball and the pipeline having chosen something else.
    """
    seed = _seed_observation(per_frame, seed_t, seed_x, seed_y,
                             seed_search_radius_px(frame_width_px))
    if seed is None:
        return None
    back = _follow(per_frame, seed, fps, forward=False)
    fwd = _follow(per_frame, seed, fps, forward=True)
    # back is newest-first from the seed; drop its duplicate seed and reverse.
    track = list(reversed(back[1:])) + fwd
    return _prune_to_ballistic(track)


# How directed a track has to be before it is treated as a flight: the straight
# line from first sighting to last, over the distance actually walked. A ball
# in flight is essentially 1.0 — it curves, but it never turns back. Clutter
# that is merely being re-detected in place scores near 0.
#
# 0.55 is deliberately loose. It has to survive a genuine flight that is partly
# occluded, detected raggedly, or caught near its apex where the horizontal
# motion is smallest, and the cost of being loose is only that a wandering
# track has to wander a bit more obviously before it is thrown out.
TRACK_STRAIGHTNESS_MIN = 0.55


def track_straightness(track: list[BallObservation]) -> float:
    """Net displacement over path length, in [0, 1].

    1.0 is a straight line. A ball flight sits just under it. A blob detected
    over and over in the same place, jittering, sits near 0 however many frames
    it survives for.
    """
    if len(track) < 2:
        return 0.0
    walked = 0.0
    for a, b in zip(track, track[1:]):
        walked += math.hypot(b.x - a.x, b.y - a.y)
    if walked <= 1e-9:
        return 0.0
    net = math.hypot(track[-1].x - track[0].x, track[-1].y - track[0].y)
    return net / walked


# A hit ball did not exist before the bat met it. Anything already in flight at
# contact is something else — the pitch, most obviously, which is the one piece
# of clutter that survives every other filter: it is a ball, it is genuinely
# moving, it is straight, and it is fast.
#
# Tolerance because the two clocks are not the same clock. The audio trigger
# fires a sound-travel-time after contact (corrected for, but not perfectly),
# and the detector's first sighting of the hit can land a frame or two either
# side of it. 50 ms is twelve frames at 240fps — far wider than that error, and
# far narrower than the several hundred milliseconds a pitch spends in frame
# before contact, which is the gap this actually has to resolve.
SELECT_CONTACT_TOL_S = 0.05
# How late after contact a track may still be the hit.
#
# There was no upper bound at all. "At or after contact" admitted anything for
# the rest of the clip, and selection then scored on speed alone — so on three
# real clips a fast object 0.61, 0.74 and 0.31 s after contact outranked the
# ball at the bat, and the verdict blamed the microphone for a gap the selector
# had chosen.
#
# 0.25 s is set from those clips: the latest real flight began 114 ms after the
# audio trigger, and the impostors began at 0.31 s and beyond. It is also all
# the room the physics needs — a hit ball is at the bat when the bat meets it,
# and a quarter of a second later it has crossed most of the frame.
SELECT_CONTACT_LATE_S = 0.25
# Frames a track needs when it starts at contact.
#
# MIN_TRACK_FRAMES exists to keep fragments out of a field of clutter. At
# contact that job is already done by the contact window, and the cost of the
# stricter rule was the measurement itself: on live_42 the ball was detected in
# four frames and dropped, and a blob three metres away was measured instead.
# Four is the fewest a quadratic fit can use with anything left over, and
# analyze_track already raises SHORT_TRACK below MIN_TRACK_FRAMES, so a track
# admitted by this rule arrives flagged rather than quietly.
NEAR_CONTACT_MIN_FRAMES = 4


def median_step_speed(track: list[BallObservation]) -> float | None:
    """Median frame-to-frame speed, px/s. None when nothing can be measured.

    The score selection uses, and NOT net displacement over elapsed time, which
    is what it used to be. That measures how far apart the two ends are, which
    is only the object's speed if the object moved coherently in between — and
    a track is exactly the thing that might not have.

    The case that forced this: a stationary blob in the corner of the frame,
    linked by the builder to something fast crossing later, giving one "track"
    whose steps ran 20, 305, 107, 162, 5390, 11141, 13917 px/s. Its ends are
    far apart, so net-over-elapsed rated it 4948 px/s — faster than the real
    ball's 4496 in the same clip, which then lost. Straightness does not catch
    it either: a stationary head contributes almost no path length, so the
    ratio of net displacement to distance walked stayed at 0.96.

    The median of the steps is 305 px/s for that track and 4635 for the ball.
    It is also simply the more honest reading of the docstring below, which has
    always said the discriminator is that a hit is several times faster than
    anything else in the clip — the median is that speed, where the endpoints
    are a proxy for it that fails on precisely the tracks worth rejecting.

    Upper median on an even count, matching the convention used elsewhere here,
    so the Swift port reproduces it exactly.
    """
    steps = []
    for a, b in zip(track, track[1:]):
        dt = b.t - a.t
        if dt > 0:
            steps.append(math.hypot(b.x - a.x, b.y - a.y) / dt)
    if not steps:
        return None
    steps.sort()
    return steps[len(steps) // 2]


def select_outbound_track(
    tracks: list[list[BallObservation]],
    fps: float,
    direction: str = "auto",     # "left" | "right" | "auto"
    min_len: int = MIN_TRACK_FRAMES,
    contact_time: float | None = None,
) -> list[BallObservation] | None:
    """Pick the hit ball: the FASTEST coherent track going the right way.

    Scored on speed alone — the MEDIAN STEP speed, see `median_step_speed`,
    not how far apart the ends are. Length used to multiply it, and in
    slow-pitch that is exactly backwards, because the two things in frame
    differ in opposite directions:

        inbound pitch   ~470 px/s over ~430 frames   ->  speed*len ~200,000
        hit ball       ~3300 px/s over ~60 frames    ->  speed*len ~200,000

    A lobbed pitch is slow and hangs in frame for two seconds; a hit is three
    to seven times faster and gone in a fraction of one. Multiplying by length
    cancels the very difference that tells them apart, and leaves the choice to
    be decided by noise. Speed alone separates them seven to one, and the hit
    ball is the fastest thing in a swing clip by a wide margin.

    Two filters sit in front of the score. `min_len` keeps out fragments.
    STRAIGHTNESS keeps out clutter that never travels — a patch of sunlit
    grass, a bag, a shoe, which a track builder will happily link across an
    entire clip while it sits there being re-detected. It is a preference
    rather than a hard gate: if nothing clears it, the whole field is scored
    anyway, because returning nothing is worse than returning something
    doubtful and flagged.

    An inbound pitch also travels, straight and fast enough to survive both
    filters. Two things exclude it.

    `contact_time`, when the caller knows it, is the reliable one: a hit ball
    did not exist before the bat met it, so any track already in flight at
    contact is something else. This is a preference like straightness — if
    nothing starts near contact the whole field is scored anyway.

    It is a WINDOW, not a floor. "At or after contact" put no upper bound on
    lateness, and speed-alone scoring then handed three real clips an object
    that appeared a third to three quarters of a second after the bat: the
    reading was of something else entirely, and the report blamed the trigger
    for the gap. Inside that window the length gate relaxes to
    NEAR_CONTACT_MIN_FRAMES, because a real flight is often detected in only a
    handful of frames and MIN_TRACK_FRAMES was written to keep fragments out of
    clutter — a job the window now does.

    `direction` is the fallback, and only when the caller states it. "auto"
    does NOT infer a direction; it cannot, from one track. It means "no
    direction constraint", so on a clip with no contact time the pitch is
    excluded by being slower than the hit and by nothing else. That is usually
    enough — a hit is three to seven times faster — and it is not always
    enough, which is why the ball can be pointed at by hand.
    """
    scored = []
    for tr in tracks:
        near = contact_time is not None and (
            contact_time - SELECT_CONTACT_TOL_S
            <= tr[0].t
            <= contact_time + SELECT_CONTACT_LATE_S
        )
        # The length gate runs HERE, before scoring, which is why an upper
        # bound on lateness cannot fix this on its own: a four-frame flight at
        # contact never reaches the pool to be preferred.
        if len(tr) < (NEAR_CONTACT_MIN_FRAMES if near else min_len):
            continue
        dt = tr[-1].t - tr[0].t
        if dt <= 0:
            continue
        # Direction is net travel; SPEED is the median step. They answer
        # different questions and one of them was answering both.
        vx = (tr[-1].x - tr[0].x) / dt
        vy = (tr[-1].y - tr[0].y) / dt
        speed = median_step_speed(tr)
        if speed is None:
            continue
        scored.append((speed, track_straightness(tr), vx, tr, near))
    if not scored:
        return None

    # Straightness is a PREFERENCE, not a hard gate. A gate that rejects every
    # track returns nothing at all, which is a worse answer than a doubtful
    # one — and on real footage the hit is sometimes detected raggedly enough
    # to fail it. Prefer directed tracks; fall back to the whole field rather
    # than reporting no ball.
    straight = [s for s in scored if s[1] >= TRACK_STRAIGHTNESS_MIN]
    pool = straight if straight else scored

    # Then, when contact is known, prefer what began AT it — within a window,
    # not merely after it. Same fall-back rule throughout: a filter that empties
    # the pool has told us nothing, and returning nothing is worse than
    # returning something doubtful and flagged.
    #
    # Two tiers inside the window, and the order matters. A track that clears
    # the full length gate always beats one admitted by the relaxed rule, so
    # the relaxation can only ever fire when there is no ordinary flight at
    # contact — which is exactly the case it was written for. A four-frame
    # fragment can never outrank a real flight that starts alongside it.
    if contact_time is not None:
        near = [s for s in pool if s[4]]
        if near:
            full = [s for s in near if len(s[3]) >= min_len]
            pool = full if full else near
        else:
            after = [s for s in pool if s[3][0].t >= contact_time - SELECT_CONTACT_TOL_S]
            if after:
                pool = after

    pool.sort(key=lambda s: -s[0])
    scored = pool

    if direction == "auto":
        return scored[0][3]
    want_positive = direction == "right"
    for _speed, _straightness, vx, tr, _near in scored:
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
    # A contact time far earlier than the flight is not a contact time.
    #
    # The fit is a quadratic in t evaluated at t0, so a t0 half a second before
    # the first sighting does not merely shift the answer, it EXTRAPOLATES the
    # curve back over ten times the span it was fitted on, and reports the
    # velocity of a moment the camera never saw. There was no guard: whatever
    # the caller passed was used, however far away, and the result carried the
    # same flags as a clean reading. See CONTACT_MAX_BACK_EXTRAPOLATION_S for
    # the field measurement that produced this.
    #
    # Falling back to the first sighting rather than refusing the swing: that
    # is what the analyzer does when it is given no contact time at all, it is
    # the best defensible number available from this track, and on the clip
    # above it recovers the correct reading to a tenth of a degree. The flag is
    # what stops it being reported as if the trigger had been right.
    if contact_time is not None and track[0].t - t0 > CONTACT_MAX_BACK_EXTRAPOLATION_S:
        flags.append(FLAG_CONTACT_TIME_REJECTED)
        t0 = track[0].t
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
# Contact-trigger calibration
# ---------------------------------------------------------------------------
#
# The trigger fires when a 5 ms RMS impulse stands TRIGGER_DB above the rolling
# noise floor. PASS_DB = 15 is the validation gate: a venue where real contact
# does not clear 15 dB is a venue where the auto-trigger cannot work.
#
# 15 is a gate, not a good working threshold. It is a single number chosen to
# decide go/no-go, and it is simultaneously too high for a quiet garden — where
# a solid hit might peak at 12 dB over near-silence and never fire — and too low
# for a batting cage, where the floor is high, ricochets are constant and 15 dB
# fires on everything that is not the ball.
#
# So: measure both ends at the venue and put the threshold between them. Record
# the background for a few seconds, then hit a few times, and the separation
# between the two decides both the number and whether a number is worth having
# at all. A venue where the loudest background overlaps the quietest hit cannot
# be fixed by choosing a cleverer threshold, and saying so is more useful than
# picking one anyway.

# Where between floor and hit to sit. Below the midpoint on purpose: a missed
# swing is lost data, while a false trigger is a clip that gets discarded in
# review — so the asymmetry favours firing. Not so low that ordinary background
# variance reaches it.
TRIGGER_MARGIN_FRACTION = 0.35

# Separation below which no threshold is trustworthy: the loudest background
# and the quietest hit are close enough that any line drawn between them will
# both miss swings and fire on noise.
TRIGGER_MIN_SEPARATION_DB = 6.0

TRIGGER_CAL_GOOD = "good"
TRIGGER_CAL_MARGINAL = "marginal"
TRIGGER_CAL_UNUSABLE = "unusable"


def suggest_trigger_db(background_peak_db: float,
                       quietest_hit_db: float) -> tuple[float, float, str]:
    """Pick a contact threshold from a venue measurement.

    Args:
        background_peak_db: the LOUDEST the background reached while listening,
            not its average. The threshold has to clear the worst moment, not
            the typical one — a single passing car is what produces a false
            trigger, and averages hide it.
        quietest_hit_db: the WEAKEST of the recorded hits. Same reasoning
            inverted: the threshold has to catch the softest swing, not the
            best one.

    Returns (threshold_db, separation_db, verdict).

    The threshold is returned even when the verdict is "unusable", because the
    caller still has to put something in the field; what changes is what the
    app tells the user about trusting it.
    """
    separation = quietest_hit_db - background_peak_db
    threshold = background_peak_db + TRIGGER_MARGIN_FRACTION * separation
    # Never below the floor it is meant to sit above, however the inputs came
    # out — a negative separation would otherwise produce a threshold under the
    # background and fire continuously.
    threshold = max(threshold, background_peak_db + 1.0)

    if separation < TRIGGER_MIN_SEPARATION_DB:
        verdict = TRIGGER_CAL_UNUSABLE
    elif separation < 2 * TRIGGER_MIN_SEPARATION_DB:
        verdict = TRIGGER_CAL_MARGINAL
    else:
        verdict = TRIGGER_CAL_GOOD
    return threshold, separation, verdict


# ---------------------------------------------------------------------------
# Body metrics (sagittal plane only)
# ---------------------------------------------------------------------------
#
# What a single side-on camera may and may not say about the hitter's body.
# docs/BIOMECHANICS.md is the long argument; this is the rule it produces.
#
# A side-on camera looks at the SAGITTAL plane. Angles and displacements that
# live in that plane — stride, head movement, weight shift, knee flexion, spine
# tilt — land within a few degrees of marker-based motion capture, so they are
# honest. Rotation ABOUT the vertical axis — hip-shoulder separation, X-factor,
# the kinematic sequence — is viewed nearly edge-on from the side, is the
# worst-measured quantity in every markerless system (hip RMSD ~21 deg,
# off-axis errors 15-37 deg), and is NOT computed here at any confidence.
#
# Neither is torque. Joint torque comes from inverse dynamics: segment masses,
# segment inertias and ground reaction forces. A camera measures none of those.
# No amount of pose quality turns a video into a torque measurement, and a
# number presented as one would be invented.
#
# There are also no published slow-pitch adult swing-kinematics norms, so
# nothing here is scored against a population band the way smash factor is.
# These functions return metres and degrees; comparison is against the hitter's
# OWN baseline over time, which is the only reference that exists.

# ---------------------------------------------------------------------------
# Contact time from the audio trigger
# ---------------------------------------------------------------------------
#
# The trigger fires when the crack of the bat REACHES THE PHONE, which is one
# sound-travel-time after it happened. Measured on a field clip whose contact
# instant is bracketed to 4 ms by the pitch and hit paths crossing: the audio
# impulse landed 10-14 ms after contact, and the ball-diameter scale put the
# camera about 4.6 m away, which is 13.4 ms of travel. That is not a tuning
# coincidence, it is the speed of sound, and the distance is already known
# because the scale depends on it.
#
# 13 ms is three frames at 240fps. It matters twice: the barrel window is only
# ~60 ms wide, so a three-frame shift moves a fifth of it, and the contact
# instant is where the undercut reading compares barrel to ball.
#
# 343 m/s is dry air at 20 C. Temperature moves it by 0.6 m/s per degree, so a
# 10-degree error is 1.7% of a 13 ms correction — 0.2 ms, a twentieth of a
# frame. Not worth asking anybody for the temperature.
SPEED_OF_SOUND_MPS = 343.0

# Beyond this the "distance" is not a camera placement, it is a bad reading,
# and subtracting it would move contact somewhere the clip never covered.
CONTACT_AUDIO_MAX_DISTANCE_M = 60.0


def contact_time_from_audio(
    audio_t: float,
    distance_m: float | None,
    speed_of_sound_mps: float = SPEED_OF_SOUND_MPS,
) -> float:
    """When contact actually happened, given when the phone heard it.

    Returns audio_t unchanged when the distance is unknown or implausible:
    guessing a distance would trade a known small bias for an unknown one.
    """
    if distance_m is None or not (0.0 < distance_m <= CONTACT_AUDIO_MAX_DISTANCE_M):
        return audio_t
    if speed_of_sound_mps <= 0:
        return audio_t
    # Never before the clip starts. A pre-roll shorter than the flight time of
    # the sound would otherwise point at a frame that was never recorded.
    return max(0.0, audio_t - distance_m / speed_of_sound_mps)


# Joint names, matching Apple's VNHumanBodyPoseObservation.JointName raw values
# so the Swift side needs no translation table.
JOINT_NOSE = "nose"
JOINT_NECK = "neck"
JOINT_LEFT_SHOULDER = "left_shoulder"
JOINT_RIGHT_SHOULDER = "right_shoulder"
JOINT_LEFT_HIP = "left_hip"
JOINT_RIGHT_HIP = "right_hip"
JOINT_LEFT_KNEE = "left_knee"
JOINT_RIGHT_KNEE = "right_knee"
JOINT_LEFT_ANKLE = "left_ankle"
JOINT_RIGHT_ANKLE = "right_ankle"
# Arms. These feed NO metric and are not meant to: side-on, the arms swing
# across the optical axis, so elbow angle and hand path are foreshortened
# exactly the way hip-shoulder separation is, and BIOMECHANICS.md refuses to
# report any of them. They exist to be DRAWN. A hitter reviewing their own swing
# looks at their hands first, and a skeleton with no arms reads as a broken
# tracker rather than as a deliberate subset — which makes the metrics that ARE
# honest look untrustworthy by association.
JOINT_LEFT_ELBOW = "left_elbow"
JOINT_RIGHT_ELBOW = "right_elbow"
JOINT_LEFT_WRIST = "left_wrist"
JOINT_RIGHT_WRIST = "right_wrist"

# A joint below this Vision confidence is treated as absent rather than as a
# guess. Apple's pose model reports low-confidence joints at plausible-looking
# positions, so using them silently would produce a body metric with no body
# behind it.
JOINT_CONFIDENCE_MIN = 0.30

# Metres of head drift beyond which the reading is almost certainly the pose
# model losing the hitter rather than the hitter moving. A swing that actually
# moved the head 40 cm toward the pitcher would be a lunge past any coaching
# reference; the far likelier explanation is a joint jumping to the umpire.
HEAD_DRIFT_IMPLAUSIBLE_M = 0.40


@dataclass
class BodyMetrics:
    """Sagittal-plane swing measurements. Every field is optional because a
    joint the pose model could not see honestly produces no number."""
    stride_m: float | None = None
    head_drift_m: float | None = None
    weight_shift_m: float | None = None
    front_knee_deg: float | None = None
    spine_tilt_deg: float | None = None
    # How many of the frames between load and contact had every joint a metric
    # needed. Low coverage means the numbers rest on a handful of frames.
    coverage: float = 0.0


def sagittal_angle_deg(ax: float, ay: float,
                       bx: float, by: float,
                       cx: float, cy: float) -> float:
    """Interior angle at b, in degrees, between the segments b->a and b->c.

    Pure image geometry, so the y-down convention does not matter: flipping y
    reflects both vectors and leaves the angle between them unchanged. Used for
    knee flexion (hip-knee-ankle), where 180 degrees is a straight leg.
    """
    v1x, v1y = ax - bx, ay - by
    v2x, v2y = cx - bx, cy - by
    n1 = math.hypot(v1x, v1y)
    n2 = math.hypot(v2x, v2y)
    if n1 < 1e-9 or n2 < 1e-9:
        return float("nan")
    cos = (v1x * v2x + v1y * v2y) / (n1 * n2)
    return math.degrees(math.acos(max(-1.0, min(1.0, cos))))


def spine_tilt_deg(hip_x: float, hip_y: float,
                   shoulder_x: float, shoulder_y: float) -> float:
    """Lean of the hip-to-shoulder line away from vertical, in degrees.

    Zero is upright. Sign follows the image: positive means the shoulders are
    displaced toward increasing x from the hips, so it flips with which way the
    hitter faces — the app reports the magnitude and lets the hitter's own
    baseline carry the direction.
    """
    dx = shoulder_x - hip_x
    dy = shoulder_y - hip_y          # negative: shoulders are above the hips
    if abs(dx) < 1e-9 and abs(dy) < 1e-9:
        return float("nan")
    return math.degrees(math.atan2(dx, -dy))


def planar_distance_m(x0: float, y0: float, x1: float, y1: float,
                      scale_m_per_px: float) -> float:
    """Straight-line displacement between two image points, in metres.

    The same metres-per-pixel the ball measurement produced. That matters: it
    means body distances inherit the ball's calibration rather than introducing
    a second one, and they are wrong in exactly the same way if it is wrong —
    which is far better than being wrong independently.
    """
    return math.hypot(x1 - x0, y1 - y0) * scale_m_per_px


def stride_length_m(front_ankle_x_load: float, front_ankle_x_contact: float,
                    scale_m_per_px: float) -> float:
    """How far the front foot travelled toward the pitcher, in metres.

    Horizontal only, and unsigned. Vertical ankle motion during a stride is the
    foot lifting, not stride length, and including it would inflate the number
    for a hitter with a big leg kick.
    """
    return abs(front_ankle_x_contact - front_ankle_x_load) * scale_m_per_px


def head_drift_plausible(drift_m: float | None) -> bool:
    """False when a head-movement reading is too large to be a swing.

    Not a coaching judgement — a sanity gate. Beyond this the pose model has
    almost certainly jumped the head joint to another person or a background
    shape, and the number should be withheld rather than shown.
    """
    if drift_m is None:
        return False
    return drift_m <= HEAD_DRIFT_IMPLAUSIBLE_M


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
