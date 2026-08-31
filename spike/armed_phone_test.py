#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
armed_phone_test.py — can an ARMED phone find a batted ball with no help?

Every other tool here answers a piece of that question and hands you the rest.
`check_audio_trigger.py` measures whether contact stands above the noise floor
but never records anything. `track_ball.py` finds the ball but is *given* the
contact frame — by a human, in a picker, or by `--auto` guessing. `batch_run.py`
runs both and does not connect them. So the pieces have all been exercised and
the CHAIN never has, which is the only thing the phone on the tripod actually
runs:

    microphone -> trigger fires -> ring buffer becomes a clip
      -> contact corrected for sound travel -> detector, motion-gated
      -> track selection using that contact time -> launch angle, exit velocity

Nothing in here may be told the answer. There is no `--contact-frame`, and that
is the point: the phone does not have one either. The only inputs are the ones
a phone genuinely has — the clip, the trigger threshold the user set, and the
camera distance from the ball tap, which is optional because the app allows it
to be.

    python armed_phone_test.py clips/tee_01.mov --fps 240 --distance 4.6
    python armed_phone_test.py clips/ --fps 240          # every clip in a folder
    python armed_phone_test.py --selftest                # prove the tool first

Read the stage table, not the verdict. A PASS on the whole chain is one clip
working once; a FAIL names the stage that broke, which is the useful output and
the reason this prints every stage even when an early one fails.

Requires ffmpeg on PATH for audio extraction (brew install ffmpeg).
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import wave

import numpy as np

import sla_common as sla

try:
    import cv2
except ImportError:  # pragma: no cover - exercised only on a bare install
    cv2 = None


# The app's own numbers. Imported from nowhere because the Swift side owns
# them, so they are restated here with the file and line that must agree — if
# one of these drifts, this tool stops simulating the app that shipped.
PRE_ROLL_S = 1.50        # SLAConstants.swift: preRollS
POST_ROLL_S = 2.00       # SLAConstants.swift: postRollS
TRIGGER_DB = 15.0        # SLAConstants.swift: triggerDb
REFRACTORY_S = 2.0       # ContactTrigger.swift: _refractoryS
RMS_WINDOW_S = 0.005     # ContactTrigger.swift: rmsWindowS
FLOOR_WINDOW_S = 0.5     # ContactTrigger.swift: floorWindowS


# --------------------------------------------------------------------------
# Stage 1 — the trigger, exactly as ContactTrigger.swift runs it


class ArmedTrigger:
    """A port of `ContactTrigger.process`, window for window.

    Deliberately not `check_audio_trigger.py`'s measurement. That script asks
    the venue question — how far does a hit stand above the floor — over the
    whole clip at once, with hindsight. This one has none: it walks the audio
    forward in 5 ms windows exactly as the microphone delivers it, compares
    each against the median of the PREVIOUS 100 windows, and fires or does not.

    Four details that all change the answer and are easy to get wrong:

    * the floor is the median of windows already past. `_lastDb` is computed
      before the current window joins `floorHistory`, so a long impulse cannot
      raise the floor that is judging it;
    * nothing fires until half a floor window has been heard (`maxFloorSamples
      / 2`), so the first 250 ms of a clip cannot trigger — a phone that has
      only just started listening has no idea what quiet sounds like;
    * the comparison is `>=`, not `>`;
    * after a fire, `refractoryS` of silence, measured from the impulse.
    """

    def __init__(self, threshold_db: float = TRIGGER_DB,
                 refractory_s: float = REFRACTORY_S):
        self.threshold_db = threshold_db
        self.refractory_s = refractory_s
        self.floor_history: list[float] = []
        self.last_fire_time = -math.inf
        self.max_floor_samples = max(8, int(FLOOR_WINDOW_S / RMS_WINDOW_S))
        # Every window's dB, for the report. The app throws these away; the
        # question "how close did it come" is only answerable if we keep them.
        self.window_db: list[tuple[float, float]] = []

    def run(self, samples: np.ndarray, sample_rate: float) -> list[float]:
        window_length = max(1, int(RMS_WINDOW_S * sample_rate))
        fires: list[float] = []
        offset = 0
        n = len(samples)
        while n - offset >= window_length:
            block = samples[offset:offset + window_length]
            rms = float(np.sqrt(np.mean(block * block))) + 1e-9
            floor = self._median_floor() + 1e-9
            db = 20.0 * math.log10(rms / floor)
            window_time = offset / sample_rate + RMS_WINDOW_S / 2
            self.window_db.append((window_time, db))

            if (db >= self.threshold_db
                    and len(self.floor_history) >= self.max_floor_samples // 2
                    and window_time - self.last_fire_time >= self.refractory_s):
                self.last_fire_time = window_time
                fires.append(window_time)

            self.floor_history.append(rms)
            if len(self.floor_history) > self.max_floor_samples:
                self.floor_history.pop(0)
            offset += window_length
        return fires

    def _median_floor(self) -> float:
        if not self.floor_history:
            return 1e-9
        return float(statistics.median(self.floor_history))


def extract_mono(clip: str, sample_rate: int = 48000) -> tuple[np.ndarray, int]:
    """Clip audio as float samples in -1..1.

    ffmpeg first, because that is what the other tools here use and what
    `docs/MAC_SETUP.md` tells people to install. PyAV second, because it is a
    library rather than a binary on PATH and so is the one that works in a
    container, on CI, and on a machine where `brew install ffmpeg` has not
    happened yet — and the whole value of this script is that it can be run
    without a field trip first.
    """
    if shutil.which("ffmpeg") is not None:
        with tempfile.TemporaryDirectory() as td:
            wav_path = os.path.join(td, "a.wav")
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", clip,
                 "-vn", "-ac", "1", "-ar", str(sample_rate), "-f", "wav", wav_path],
                check=True)
            with wave.open(wav_path) as wf:
                sr = wf.getframerate()
                raw = wf.readframes(wf.getnframes())
        return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0, sr

    try:
        import av
    except ImportError:
        raise RuntimeError(
            "no audio decoder: install ffmpeg (brew install ffmpeg) or PyAV "
            "(pip install av)") from None

    with av.open(clip) as container:
        streams = [s for s in container.streams if s.type == "audio"]
        if not streams:
            raise RuntimeError("the clip has no audio track at all")
        stream = streams[0]
        sr = int(stream.rate or sample_rate)
        chunks = []
        for frame in container.decode(stream):
            arr = frame.to_ndarray()
            # Planar layouts arrive as (channels, samples), packed as
            # (1, samples*channels). Take channel 0 either way — the app reads
            # the first channel too (`ContactTrigger.monoSamples`).
            if arr.ndim == 2 and arr.shape[0] > 1:
                arr = arr[0]
            else:
                arr = arr.reshape(-1)
                ch = getattr(frame.layout, "nb_channels", 1) or 1
                if ch > 1:
                    arr = arr[::ch]
            chunks.append(np.asarray(arr, dtype=np.float64))
    if not chunks:
        raise RuntimeError("the clip's audio track decoded to nothing")
    data = np.concatenate(chunks)
    if np.issubdtype(data.dtype, np.integer) or np.max(np.abs(data)) > 1.5:
        data = data / 32768.0
    return data, sr


# --------------------------------------------------------------------------
# Frames, with the times they were actually shown at.
#
# `sla.open_video` + `frame_index / fps` is what every other script here does,
# and on these clips it is wrong. Both field clips are slow-motion EDITS: a
# 240fps core with 30fps ramps welded either side, 90% of intervals at 4.167 ms
# and the rest at 12.5, 25 or 33.3. Counting frames puts contact on IMG_6703 at
# 0.644 s; the timestamps put it at 0.769, which is where the audio impulse and
# the recorded bracket in ParityTests both say it is.
#
# The app already reads presentation timestamps — `ClipAnalyzer` takes `t` from
# `CMSampleBufferGetPresentationTimeStamp`. This is the Mac side catching up, so
# that a number checked here means the same thing as the number on the phone.


class FrameSource:
    def __init__(self, path: str, fps_override: float | None):
        self.path = path
        # An override REPLACES the container's clock, it does not merely rename
        # it. That is the whole meaning of `--fps 240` on a slo-mo clip whose
        # metadata lies: the frames are 240fps frames, the container says
        # otherwise, and the timestamps it carries are the thing being
        # overridden. Reading the override for the rate while still taking `t`
        # from the packets gives a clip whose frames are numbered at 240 and
        # timed at 60 — a capture window four times too short.
        self._override = fps_override
        self._times: list[float] = []
        self._use_av = False
        try:
            import av  # noqa: F401
            self._use_av = True
        except ImportError:
            pass

        if self._use_av:
            import av
            with av.open(path) as c:
                vs = [s for s in c.streams if s.type == "video"][0]
                tb = float(vs.time_base)
                self.width = int(vs.codec_context.width)
                self.height = int(vs.codec_context.height)
                self._times = sorted(float(pk.pts) * tb
                                     for pk in c.demux(vs) if pk.pts is not None)
        else:
            cap = cv2.VideoCapture(path)
            self.width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            self.height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            meta = float(cap.get(cv2.CAP_PROP_FPS)) or 30.0
            cap.release()
            f = fps_override or meta
            self._times = [i / f for i in range(max(1, n))]

        if fps_override:
            self.fps = fps_override
            self._times = [i / fps_override for i in range(len(self._times))]
            self.irregular_fraction = 0.0
        else:
            d = (np.diff(np.asarray(self._times)) if len(self._times) > 1
                 else np.array([1.0]))
            med = float(np.median(d)) or 1.0
            # The MEDIAN interval, not frames-over-duration. On a ramped clip
            # the mean reads 175 fps for footage whose core is exactly 240.
            self.fps = 1.0 / med
            self.irregular_fraction = float(np.mean(np.abs(d - med) > 0.2 * med))

    def iter(self):
        """(index, time, BGR frame), in order."""
        def stamp(i, pts_t):
            if self._override:
                return i / self._override
            if pts_t is not None:
                return pts_t
            return self._times[i] if i < len(self._times) else i / self.fps

        if self._use_av:
            import av
            with av.open(self.path) as c:
                vs = [s for s in c.streams if s.type == "video"][0]
                tb = float(vs.time_base)
                for i, fr in enumerate(c.decode(vs)):
                    pts_t = float(fr.pts) * tb if fr.pts is not None else None
                    yield i, stamp(i, pts_t), fr.to_ndarray(format="bgr24")
            return
        cap = cv2.VideoCapture(self.path)
        i = -1
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    return
                i += 1
                yield i, stamp(i, None), frame
        finally:
            cap.release()


def decode_frames(path: str, fps_override: float | None) -> FrameSource:
    return FrameSource(path, fps_override)


# --------------------------------------------------------------------------
# Stage 2-5 — the capture window, the detector, the selection


class StageResult:
    def __init__(self, name: str, ok: bool, detail: str):
        self.name, self.ok, self.detail = name, ok, detail


def run_clip(path: str, fps_override: float | None, distance_m: float | None,
             threshold_db: float, direction: str,
             audio: tuple[np.ndarray, int] | None = None
             ) -> tuple[list[StageResult], dict]:
    """Walk one clip through the whole armed chain.

    `audio` overrides the ffmpeg extraction. Only the synthetic self-check
    passes it — but making the seam explicit is also what lets the video half
    of this be exercised on a machine with no ffmpeg, which is most machines
    that are not a Mac with the clips on them.
    """
    stages: list[StageResult] = []
    facts: dict = {"clip": os.path.basename(path)}

    # --- 1. the trigger ---------------------------------------------------
    if audio is not None:
        samples, sr = audio
    else:
        try:
            samples, sr = extract_mono(path)
        except Exception as exc:
            stages.append(StageResult("audio", False, f"could not read audio: {exc}"))
            return stages, facts

    if len(samples) < sr // 4:
        # The README warns about this: slow-motion clips shared out of Photos
        # frequently lose their audio, and a silent clip is a finding about the
        # export path, not about the trigger.
        stages.append(StageResult(
            "audio", False,
            f"only {len(samples)/sr:.2f} s of audio — a shared or trimmed "
            "slo-mo copy loses it. AirDrop the original."))
        return stages, facts

    trig = ArmedTrigger(threshold_db=threshold_db)
    fires = trig.run(samples, sr)
    # Only windows the trigger could actually have fired on. The first one of
    # every clip reads 120-140 dB because the rolling floor is still empty and
    # the comparison runs against the 1e-9 epsilon — an artefact, not a sound.
    # The app suppresses FIRING on it but `consumePeakDb` still hands it to the
    # level meter, so a phone that has just been armed shows an impossible
    # number for a quarter of a second.
    settled = trig.max_floor_samples // 2
    fireable = trig.window_db[settled:]
    peak_db = max((d for _, d in fireable), default=float("-inf"))
    peak_t = max(fireable, key=lambda p: p[1])[0] if fireable else 0.0
    facts["peak_db"] = peak_db
    facts["peak_t"] = peak_t
    facts["fires"] = fires

    if not fires:
        stages.append(StageResult(
            "trigger", False,
            f"never fired: loudest window {peak_db:.1f} dB over the rolling "
            f"floor at {peak_t:.3f} s, threshold {threshold_db:.1f} dB. "
            "Settings -> Trigger -> Calibrate at this venue."))
        return stages, facts

    # The FIRST fire is the one the phone acts on. A later, louder impulse is
    # the ball hitting the fence, and the refractory window is what stops that
    # one becoming the clip. Reporting the first is the honest simulation.
    audio_t = fires[0]
    extra = f", {len(fires) - 1} later impulse(s) held off by the refractory window" \
        if len(fires) > 1 else ""
    stages.append(StageResult(
        "trigger", True,
        f"fired at {audio_t:.3f} s, peak {peak_db:.1f} dB over floor "
        f"(threshold {threshold_db:.1f}){extra}"))

    # --- 2. the capture window -------------------------------------------
    clip_start = max(0.0, audio_t - PRE_ROLL_S)
    clip_end = audio_t + POST_ROLL_S
    facts["window"] = (clip_start, clip_end)
    stages.append(StageResult(
        "capture window", True,
        f"{clip_start:.3f}-{clip_end:.3f} s "
        f"({PRE_ROLL_S:.2f} s pre-roll, {POST_ROLL_S:.2f} s post)"))

    # --- 3. contact, corrected for sound travel ---------------------------
    contact_t = sla.contact_time_from_audio(audio_t, distance_m)
    shift_ms = (audio_t - contact_t) * 1000.0
    if distance_m is None:
        stages.append(StageResult(
            "contact time", True,
            f"{contact_t:.4f} s — uncorrected, no camera distance "
            "(the ball was never tapped; costs ~3 frames at 240fps)"))
    else:
        stages.append(StageResult(
            "contact time", True,
            f"{contact_t:.4f} s — {shift_ms:.1f} ms earlier than the impulse, "
            f"sound travelling {distance_m:.1f} m"))
    facts["contact_t"] = contact_t

    # --- 4. detection, motion-gated, inside the window only ---------------
    if cv2 is None:
        stages.append(StageResult("detector", False,
                                  "opencv not installed (pip install -r requirements.txt)"))
        return stages, facts

    frames = decode_frames(path, fps_override)
    fps = frames.fps
    width, height = frames.width, frames.height
    facts["fps"], facts["width"], facts["height"] = fps, width, height
    facts["variable_rate"] = frames.irregular_fraction

    # Said out loud, because it changes what every number below means and it is
    # invisible otherwise. An iPhone slow-motion clip shared out of Photos is a
    # 240fps core with 30fps ramps welded either side, and both of the project's
    # field clips are exactly that: 90% of their intervals at 4.167 ms and the
    # rest at 12.5, 25 or 33.3. Every measurement here assumes a constant frame
    # interval, so on a clip like that `frame_index / fps` is not a time — on
    # IMG_6703 it puts contact at 0.644 s where the timestamps put it at 0.769.
    if frames.irregular_fraction > 0.02:
        stages.append(StageResult(
            "frame timing", True,
            f"{100 * frames.irregular_fraction:.0f}% of intervals are off the "
            f"{1000 / fps:.2f} ms median — this is a slow-motion EDIT, not a raw "
            "240fps clip. Timestamps used, not frame numbers."))

    per_frame: dict[int, list] = {}
    prev_gray = None
    frames_in_window = 0
    candidates_total = 0
    gated_out = 0
    n_seen = 0
    for idx, t, frame in frames.iter():
        n_seen += 1
        if t < clip_start:
            # Still worth differencing against, but only from just before the
            # window: a gate needs a previous frame, and the phone's ring
            # buffer has one.
            if t >= clip_start - 2.0 / fps:
                prev_gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            continue
        if t > clip_end:
            break
        frames_in_window += 1
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fg = sla.motion_mask(gray, prev_gray)
        prev_gray = gray
        ungated = sla.detect_ball_candidates(frame, idx, t, None)
        cands = sla.detect_ball_candidates(frame, idx, t, fg)
        candidates_total += len(cands)
        gated_out += len(ungated) - len(cands)
        if cands:
            per_frame[idx] = cands
    idx = n_seen - 1

    facts["frames_in_window"] = frames_in_window
    facts["candidates"] = candidates_total
    facts["gated_out"] = gated_out
    if frames_in_window == 0:
        stages.append(StageResult(
            "detector", False,
            f"the capture window {clip_start:.2f}-{clip_end:.2f} s lies outside "
            f"the clip ({idx + 1} frames at {fps:.0f} fps = "
            f"{(idx + 1) / fps:.2f} s)"))
        return stages, facts

    per_frame_avg = candidates_total / frames_in_window
    if not per_frame:
        stages.append(StageResult(
            "detector", False,
            f"no ball-coloured moving blob in any of {frames_in_window} frames. "
            "Colour window or motion gate — the report from the app names which."))
        return stages, facts
    stages.append(StageResult(
        "detector", True,
        f"{candidates_total} candidates over {frames_in_window} frames "
        f"({per_frame_avg:.1f}/frame); the motion gate removed {gated_out} "
        f"({100.0 * gated_out / max(1, gated_out + candidates_total):.0f}% of colour matches)"))

    # --- 5. track building and selection ----------------------------------
    tracks = sla.build_tracks(per_frame, fps)
    tracks = sla.stitch_tracks(tracks)
    facts["tracks"] = len(tracks)
    if not tracks:
        stages.append(StageResult(
            "tracks", False,
            f"{candidates_total} candidates linked into no track of "
            "the minimum length — detections are not landing on consecutive frames"))
        return stages, facts
    stages.append(StageResult("tracks", True, f"{len(tracks)} candidate chains"))

    chosen = sla.select_outbound_track(tracks, fps, direction=direction,
                                       contact_time=contact_t)
    if chosen is None:
        stages.append(StageResult(
            "selection", False,
            f"none of {len(tracks)} chains was selectable as an outbound hit"))
        return stages, facts

    straight = sla.track_straightness(chosen)
    # The same tolerance `select_outbound_track` uses, and for the same reason:
    # the audio clock and the detector's first sighting are not the same clock,
    # and a frame either side of contact is agreement, not a reversal. The gap
    # this has to resolve is the several hundred milliseconds a pitch spends in
    # frame, not a frame interval.
    starts_after = chosen[0].t >= contact_t - sla.SELECT_CONTACT_TOL_S
    facts["straightness"] = straight
    facts["track_len"] = len(chosen)
    facts["starts_after_contact"] = starts_after
    stages.append(StageResult(
        "selection", True,
        f"{len(chosen)} frames, straightness {straight:.2f}, "
        f"starts {1000.0 * (chosen[0].t - contact_t):+.0f} ms relative to contact"
        + ("" if starts_after else " — that is BEFORE it")))

    # --- 6. the measurement ------------------------------------------------
    result = sla.analyze_track(chosen, contact_time=contact_t)
    facts["launch_angle_deg"] = result.launch_angle_deg
    facts["exit_velo_mph"] = result.exit_velo_mph
    facts["flags"] = list(result.flags)
    stages.append(StageResult(
        "measurement", True,
        f"LA {result.launch_angle_deg:.1f} deg, EV {result.exit_velo_mph:.1f} mph, "
        f"flags {','.join(result.flags) if result.flags else 'none'}"))

    # The one thing this tool must not do is call an unvalidated number right.
    # It can only say the chain produced one, and whether that number is even
    # physically possible for the sport.
    if not starts_after:
        stages.append(StageResult(
            "sanity", False,
            "the selected chain was already in flight well before contact — "
            "that is the PITCH, not the hit. The measurement above is of the "
            "wrong ball."))
    elif sla.FLAG_CONTACT_TIME_REJECTED in result.flags:
        # Not a chain failure. The detector and the selection both did their
        # job; the analyzer noticed the trigger had not, said so, and fell back
        # to the first frame of the flight. Reported as its own line because
        # the swing is usable and the VENUE is the thing that needs attention.
        stages.append(StageResult(
            "sanity", True,
            "the trigger fired on something other than this hit — contact taken "
            "from the flight instead and the reading flagged. Calibrate the "
            "trigger at this venue (Settings -> Trigger -> Calibrate)."))
    elif not sla.in_slowpitch_launch_window(result.launch_angle_deg):
        # Not a chain failure. Every stage did its job and the ball was
        # followed at straightness 1.00; the hitter simply put this one into
        # the ground. The launch window is a coaching band, not a detector
        # gate, and reporting "CHAIN BROKE" for a low line drive would teach
        # exactly the wrong lesson about a tool whose output is meant to be
        # read stage by stage.
        stages.append(StageResult(
            "sanity", True,
            f"LA {result.launch_angle_deg:.1f} deg is outside the slow-pitch "
            "coaching window — a real reading of a mis-hit, or a wrong one. "
            "The frames are the only way to tell; nothing upstream failed."))
    else:
        stages.append(StageResult(
            "sanity", True,
            "launch angle is inside the slow-pitch window and the chain begins "
            "at contact — consistent with a hit ball, NOT a validation of the "
            "value (see docs/VALIDATION.md)"))
    return stages, facts


# --------------------------------------------------------------------------
# A synthetic swing that the chain has to solve with no help.
#
# `synth_test.py` renders a ball and hands the pipeline the contact frame. This
# one renders the whole situation the armed phone is actually in — a lobbed
# pitch arriving first, the hit leaving after, sunlit-grass clutter that is the
# ball's own colour and never moves, and an audio impulse at contact — and then
# tells the chain nothing. It is the difference between "the maths works" and
# "the phone works", and only the second one was ever in question.

SYN_W, SYN_H = 1280, 720
SYN_FPS = 240.0
# 206 px/m, not a round number: it is what the field clips actually measure.
# The detector reported 4.844 mm/px on IMG_6703 and ball diameters of 18-22 px,
# and the scale is not a cosmetic choice — an earlier version of this scene used
# 100 px/m, which put the incoming pitch at 4.5 px a frame, under
# BUILD_TURN_MIN_STEP_PX. The reversal guard switched itself off, association
# walked the pitch through contact into the hit, and the chain reported -81.9
# deg at 3294 mph. That is a real sensitivity worth knowing about — at half this
# scale the guard stops guarding — but it is not what this scene is for, and a
# self-check that fails for a reason it is not testing teaches nothing.
SYN_PX_PER_M = 206.0
SYN_BALL_BGR = (0, 255, 204)
SYN_TRUE_LA = 24.0
SYN_TRUE_EV = 62.0
SYN_CONTACT_T = 1.30          # s into the clip
SYN_DISTANCE_M = 4.6


def _syn_flight(n: int, la_deg: float, ev_mph: float,
                x0: float, y0: float, sign: float = 1.0):
    """Drag-integrated flight, sampled per frame. Same model as synth_test."""
    ev = ev_mph / sla.MPH_PER_MPS
    la = math.radians(la_deg)
    k_over_m = (0.5 * sla.AIR_DENSITY * sla.DRAG_CD * math.pi
                * (sla.BALL_DIAMETER_M / 2) ** 2 / sla.BALL_MASS_KG)
    vx, vy = ev * math.cos(la), ev * math.sin(la)
    xm, ym = 0.0, 0.0
    dt = 1.0 / (SYN_FPS * 10.0)
    out = []
    for _ in range(n):
        out.append((x0 + sign * xm * SYN_PX_PER_M, y0 - ym * SYN_PX_PER_M))
        for _ in range(10):
            v = math.hypot(vx, vy)
            vx += (-k_over_m * v * vx) * dt
            vy += (-sla.G - k_over_m * v * vy) * dt
            xm += vx * dt
            ym += vy * dt
    return out


def render_synthetic(path: str) -> tuple[np.ndarray, int]:
    """Render the clip; return the audio track that goes with it."""
    rng = np.random.default_rng(11)
    yy = np.linspace(0, 1, SYN_H, dtype=np.float32)[:, None]
    base = np.zeros((SYN_H, SYN_W, 3), np.uint8)
    base[:, :, 0] = (40 + 30 * yy).astype(np.uint8)
    base[:, :, 1] = (95 + 40 * yy).astype(np.uint8)
    base[:, :, 2] = (55 + 25 * yy).astype(np.uint8)
    for x in range(0, SYN_W, 160):
        cv2.line(base, (x, 0), (x, SYN_H), (35, 60, 40), 5)

    # The clutter that broke colour-only detection on real footage: ball-sized,
    # ball-coloured, parked at the same pixel for the whole clip. If the motion
    # gate is doing its job these never become candidates; if it is not, they
    # outnumber the ball by a hundred to one and the selection picks scenery.
    clutter = [(rng.integers(60, SYN_W - 60), rng.integers(60, SYN_H - 60))
               for _ in range(40)]
    for cx, cy in clutter:
        cv2.circle(base, (int(cx), int(cy)), 11, SYN_BALL_BGR, -1)

    n_frames = int(3.4 * SYN_FPS)
    contact_f = int(SYN_CONTACT_T * SYN_FPS)
    d_px = sla.BALL_DIAMETER_M * SYN_PX_PER_M
    shutter = 1.0 / 1000.0

    # The pitch: lobbed in from the right, arriving at the contact point. Slow
    # and long — 1.3 s in frame — which is exactly the shape that beats a
    # "longest track" or "straightest track" heuristic.
    pitch_n = contact_f
    pitch = _syn_flight(pitch_n, 22.0, 24.0, 180.0, 560.0, sign=1.0)
    pitch = list(reversed(pitch))       # arrive at the plate, not leave it

    hit = _syn_flight(n_frames - contact_f, SYN_TRUE_LA, SYN_TRUE_EV, 180.0, 560.0)

    vw = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), 60.0,
                         (SYN_W, SYN_H))
    if not vw.isOpened():
        raise IOError("VideoWriter failed to open (mp4v)")

    def draw(frame, pts, i):
        if i <= 0 or i >= len(pts):
            return
        x, y = pts[i]
        if not (0 <= x < SYN_W and 0 <= y < SYN_H):
            return
        px, py = pts[i - 1]
        vx, vy = (x - px) * SYN_FPS, (y - py) * SYN_FPS
        smear = math.hypot(vx, vy) * shutter
        axes = (int(round((d_px + smear) / 2)), int(round(d_px / 2)))
        cv2.ellipse(frame, (int(round(x)), int(round(y))), axes,
                    math.degrees(math.atan2(vy, vx)), 0, 360, SYN_BALL_BGR, -1)

    for f in range(n_frames):
        frame = base.copy()
        noise = rng.integers(-6, 7, (SYN_H, SYN_W, 1), dtype=np.int16)
        frame = np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)
        if f < contact_f:
            draw(frame, pitch, f)
        else:
            draw(frame, hit, f - contact_f)
        vw.write(frame)
    vw.release()

    # The audio the microphone would have heard: hiss, one bat crack at
    # contact plus the sound-travel delay, and — because this is the case that
    # matters — the ball hitting the fence 1.2 s later, loud enough to trigger
    # on its own. The refractory window is what keeps that from becoming the
    # clip, and nothing else in the app does.
    sr = 48000
    audio = rng.normal(0.0, 0.0012, int(n_frames / SYN_FPS * sr))
    crack_t = SYN_CONTACT_T + SYN_DISTANCE_M / sla.SPEED_OF_SOUND_MPS
    for at, amp in ((crack_t, 0.12), (crack_t + 1.2, 0.09)):
        j = int(at * sr)
        if j + 240 < len(audio):
            audio[j:j + 240] += rng.normal(0.0, amp, 240)
    return audio, sr


def synthetic_check() -> int:
    """Run the chain on the synthetic swing and check what came back."""
    if cv2 is None:
        print("opencv not installed — pip install -r requirements.txt")
        return 2
    os.makedirs("out", exist_ok=True)
    path = os.path.join("out", "armed_synthetic.mp4")
    print("rendering a synthetic swing (pitch + hit + stationary clutter)...")
    audio, sr = render_synthetic(path)

    stages, facts = run_clip(path, SYN_FPS, SYN_DISTANCE_M, TRIGGER_DB, "auto",
                             audio=(audio, sr))
    print()
    for s in stages:
        print(f"  [{'PASS' if s.ok else 'FAIL'}] {s.name:<14} {s.detail}")

    ok = all(s.ok for s in stages)
    print()

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}{'  ' + detail if detail else ''}")
        if not cond:
            ok = False

    # Truth, which the chain was never told.
    got_t = facts.get("contact_t")
    if got_t is not None:
        check("contact recovered to within one frame",
              abs(got_t - SYN_CONTACT_T) <= 1.5 / SYN_FPS,
              f"{got_t:.4f} s vs {SYN_CONTACT_T:.4f} s "
              f"({1000 * (got_t - SYN_CONTACT_T):+.1f} ms)")
    la, ev = facts.get("launch_angle_deg"), facts.get("exit_velo_mph")
    if la is not None:
        check("launch angle within 2 deg of truth",
              abs(la - SYN_TRUE_LA) <= 2.0,
              f"{la:.2f} vs {SYN_TRUE_LA:.2f}")
    if ev is not None:
        check("exit velocity within 5% of truth",
              abs(ev - SYN_TRUE_EV) / SYN_TRUE_EV <= 0.05,
              f"{ev:.2f} vs {SYN_TRUE_EV:.2f} mph")
    # The one that is really being tested: the pitch was in frame, longer and
    # earlier than the hit, and the chain had to not choose it.
    if facts.get("starts_after_contact") is not None:
        check("the chain chose the hit, not the pitch",
              facts["starts_after_contact"] is True)

    print("\n" + ("ALL PASS — the armed chain solved a swing it was told nothing about."
                  if ok else "FAILURES above — the chain did not."))
    return 0 if ok else 1


# --------------------------------------------------------------------------
# Self-test: the tool proves itself before it is trusted with real footage,
# the same discipline `audio_lab.py --selftest` follows.


def selftest() -> int:
    print("armed_phone_test self-test")
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}{'  ' + detail if detail else ''}")
        if not cond:
            ok = False

    sr = 48000
    rng = np.random.default_rng(7)

    # A second of hiss, then a click 40 dB above it, then more hiss.
    quiet = rng.normal(0.0, 0.001, sr * 2)
    impulse_at = 1.0
    sig = quiet.copy()
    i0 = int(impulse_at * sr)
    sig[i0:i0 + 240] += rng.normal(0.0, 0.1, 240)

    t = ArmedTrigger()
    fires = t.run(sig, sr)
    check("fires once on a clean impulse", len(fires) == 1, f"fires={len(fires)}")
    if fires:
        check("fires within 10 ms of the impulse",
              abs(fires[0] - impulse_at) < 0.010,
              f"at {fires[0]:.4f} s vs {impulse_at:.4f} s")

    # Nothing but hiss must never fire. This is the false-positive question and
    # it is the one that matters on a tripod left armed between pitches.
    t2 = ArmedTrigger()
    check("silence never fires", len(t2.run(quiet, sr)) == 0)

    # Two impulses inside the refractory window are one clip, not two.
    twin = quiet.copy()
    for at in (1.0, 1.4):
        j = int(at * sr)
        twin[j:j + 240] += rng.normal(0.0, 0.1, 240)
    t3 = ArmedTrigger()
    f3 = t3.run(twin, sr)
    check("a second impulse inside the refractory window is held off",
          len(f3) == 1, f"fires={len(f3)}")

    # ...and outside it is a second swing.
    twin2 = rng.normal(0.0, 0.001, sr * 5)
    for at in (1.0, 4.0):
        j = int(at * sr)
        twin2[j:j + 240] += rng.normal(0.0, 0.1, 240)
    t4 = ArmedTrigger()
    check("an impulse past the refractory window fires again",
          len(t4.run(twin2, sr)) == 2)

    # An impulse in the first 250 ms must be ignored: the phone has not heard
    # enough to know what quiet is. This is the guard that stops the very act
    # of pressing ARM — or setting the phone down — recording a clip.
    early = rng.normal(0.0, 0.001, sr * 2)
    j = int(0.05 * sr)
    early[j:j + 240] += rng.normal(0.0, 0.1, 240)
    t5 = ArmedTrigger()
    f5 = t5.run(early, sr)
    check("an impulse before the floor is established is ignored",
          all(f > 0.2 for f in f5), f"fires at {[round(x, 3) for x in f5]}")

    # The sound-travel correction, against the one real-footage bracket the
    # project has: IMG_6703's impulse at 0.781 s from 4.6 m.
    corrected = sla.contact_time_from_audio(0.781, 4.6)
    check("IMG_6703 contact lands inside the measured bracket",
          0.7667 <= corrected <= 0.7708, f"{corrected:.4f} s")

    # The window arithmetic the phone does with that fire.
    start, end = max(0.0, 0.781 - PRE_ROLL_S), 0.781 + POST_ROLL_S
    check("the capture window contains the corrected contact",
          start <= corrected <= end, f"[{start:.3f}, {end:.3f}]")

    print("\n" + ("ALL PASS — the trigger simulation matches the app's rules."
                  if ok else "FAILURES above."))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip", nargs="?", help="clip file, or a folder of them")
    ap.add_argument("--fps", type=float,
                    help="override container fps — slo-mo metadata is often "
                         "wrong and 240 is what the phone actually shot")
    ap.add_argument("--distance", type=float,
                    help="camera distance in metres, as the ball tap would "
                         "give it. Omit to simulate a hitter who skipped it.")
    ap.add_argument("--threshold-db", type=float, default=TRIGGER_DB,
                    help=f"trigger threshold (default {TRIGGER_DB})")
    ap.add_argument("--direction", choices=["left", "right", "auto"], default="auto")
    ap.add_argument("--selftest", action="store_true",
                    help="prove the trigger simulation against the app's rules")
    ap.add_argument("--synthetic", action="store_true",
                    help="render a swing with a pitch, a hit and clutter, then "
                         "solve it with no help and check the answer")
    args = ap.parse_args()

    if args.selftest:
        rc = selftest()
        return rc if not args.synthetic else (rc or synthetic_check())
    if args.synthetic:
        return synthetic_check()
    if not args.clip:
        ap.error("give a clip or a folder, or --selftest / --synthetic")

    if os.path.isdir(args.clip):
        paths = sorted(p for p in glob.glob(os.path.join(args.clip, "*"))
                       if os.path.splitext(p)[1].lower() in (".mov", ".mp4", ".m4v"))
        if not paths:
            print(f"no clips in {args.clip}")
            return 2
    else:
        paths = [args.clip]

    overall = 0
    for p in paths:
        print(f"\n=== {os.path.basename(p)} " + "=" * max(0, 60 - len(os.path.basename(p))))
        try:
            stages, _facts = run_clip(p, args.fps, args.distance,
                                      args.threshold_db, args.direction)
        except Exception as exc:
            print(f"  [FAIL] {type(exc).__name__}: {exc}")
            overall = 1
            continue
        for s in stages:
            print(f"  [{'PASS' if s.ok else 'FAIL'}] {s.name:<14} {s.detail}")
        chain_ok = all(s.ok for s in stages)
        if not chain_ok:
            overall = 1
        print(f"  ---> {'CHAIN COMPLETE' if chain_ok else 'CHAIN BROKE at ' + next(s.name for s in stages if not s.ok)}")

    if len(paths) > 1:
        print(f"\n{sum(1 for _ in paths)} clips, exit {overall}")
    return overall


if __name__ == "__main__":
    sys.exit(main())
