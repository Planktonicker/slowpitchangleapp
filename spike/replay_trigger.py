#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
replay_trigger.py — run the app's contact trigger over the corpus's real audio
and measure whether it can tell a hit from what fools it.

`replay_corpus.py` replays what the DETECTOR saw. This replays what the
MICROPHONE heard, on the same clips, because the field complaint — "most of the
time I arm it, the person hits the ball, and nothing happens" — is upstream of
anything the detector does. A clip that was never recorded has no trace.

    python replay_trigger.py --selftest   # the DSP, against known signals
    python replay_trigger.py              # what fires on each corpus clip
    python replay_trigger.py --sweep      # separation vs. the band listened in
    python replay_trigger.py --band 6000  # one cutoff in detail

**The measurement this exists for.** `sla_common.suggest_trigger_db` says a
venue is unusable when its loudest background comes within 6 dB of its quietest
hit, because no threshold can then separate them. Run on this corpus, that is
exactly what the venue measures — see `--sweep`. It is the whole explanation for
false positives and false negatives arriving together, and it is not something a
threshold, a refractory or a floor statistic can fix.

Audio needs an ffmpeg to decode FLAC. `pip install imageio-ffmpeg` supplies one;
so does a system ffmpeg on PATH. Without either, this tool says so and exits —
`replay_corpus.py` does not depend on it.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
INDEX = os.path.join(CORPUS, "index.json")
CONSTANTS_SWIFT = os.path.join(HERE, "..", "app", "Sources", "Core", "SLAConstants.swift")
TRIGGER_SWIFT = os.path.join(HERE, "..", "app", "Sources", "Capture", "ContactTrigger.swift")

# Mirrors of ContactTrigger's own windowing. Read from the Swift below where
# they are declared there; these are the fallbacks.
RMS_WINDOW_S = 0.005
FLOOR_WINDOW_S = 0.5


def ffmpeg() -> str | None:
    for probe in ("ffmpeg",):
        try:
            subprocess.run([probe, "-version"], capture_output=True, check=True)
            return probe
        except Exception:
            pass
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def load_audio(path: str) -> tuple[np.ndarray, int]:
    """Mono float samples and the sample rate, from FLAC or WAV."""
    if path.endswith(".wav"):
        wav_path, tmp = path, None
    else:
        exe = ffmpeg()
        if not exe:
            raise SystemExit(
                "no ffmpeg found — `pip install imageio-ffmpeg`, or put one on PATH.\n"
                "replay_corpus.py does not need it; only the audio replay does.")
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        wav_path = tmp.name
        subprocess.run([exe, "-y", "-loglevel", "error", "-i", path,
                        "-ac", "1", "-c:a", "pcm_s16le", wav_path], check=True,
                       capture_output=True)
    try:
        with wave.open(wav_path) as w:
            sr = w.getframerate()
            raw = w.readframes(w.getnframes())
        d = np.frombuffer(raw, np.int16).astype(np.float64) / 32768.0
    finally:
        if tmp:
            os.unlink(wav_path)
    return d, sr


def highpass(x: np.ndarray, sr: float, fc: float) -> np.ndarray:
    """Second-order Butterworth high-pass, written out as a biquad.

    Deliberately a biquad and not a library call: the Swift has to run the SAME
    filter sample-for-sample or this tool stops predicting the phone, and a
    biquad is ten lines with no dependency. Direct form I, Q = 1/sqrt(2).
    """
    w0 = 2 * math.pi * fc / sr
    c, s = math.cos(w0), math.sin(w0)
    alpha = s / (2 * (1 / math.sqrt(2)))
    b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
    a0, a1, a2 = 1 + alpha, -2 * c, 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.empty_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, xn in enumerate(x):
        yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        y[i] = yn
        x2, x1 = x1, xn
        y2, y1 = y1, yn
    return y


def simulate(d: np.ndarray, sr: float, threshold_db: float, refractory_s: float,
             floor_span_s: float = FLOOR_WINDOW_S, quantile: float = 0.5,
             band_hz: float | None = None, attempt_refractory_s: float | None = None):
    """`ContactTrigger.process`, window for window.

    Faithful to the order that matters: the current window is tested BEFORE its
    own rms joins the floor history, and nothing may fire until the history is
    half full. Both decide what happens in the first quarter-second after every
    arm and every clip.

    `attempt_refractory_s` models the two-stage refractory: detection buys only
    the short window, and the full `refractory_s` is paid only once something
    CONFIRMS the fire. Pass it to model the app as it now is; leave it None to
    model the app as it was, where every detection paid the full price whether
    or not a clip was ever written.
    """
    if band_hz:
        d = highpass(d, sr, band_hz)
    w = max(1, int(RMS_WINDOW_S * sr))
    n = len(d) // w
    if n < 2:
        return [], np.zeros(0), np.zeros(0), np.zeros(0)
    rms = np.sqrt(np.mean(d[:n * w].reshape(n, w) ** 2, axis=1)) + 1e-9
    max_floor = max(8, int(floor_span_s / RMS_WINDOW_S))
    hist: list[float] = []
    fires: list[tuple[float, float]] = []
    db = np.empty(n)
    floor = np.empty(n)
    last_fire = -math.inf
    for i in range(n):
        f = (np.quantile(hist, quantile) if hist else 1e-9) + 1e-9
        v = 20 * math.log10(rms[i] / f)
        db[i] = v
        floor[i] = f
        t = i * RMS_WINDOW_S + RMS_WINDOW_S / 2
        gap = attempt_refractory_s if attempt_refractory_s is not None else refractory_s
        if (v >= threshold_db and len(hist) >= max_floor // 2
                and t - last_fire >= gap):
            last_fire = t
            fires.append((t, v))
        hist.append(rms[i])
        if len(hist) > max_floor:
            hist.pop(0)
    t = np.arange(n) * RMS_WINDOW_S + RMS_WINDOW_S / 2
    return fires, db, t, floor


def swift_constant(path: str, name: str, fallback: float) -> float:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return fallback
    m = re.search(rf"static let {name}\s*(?::\s*\w+\s*)?=\s*(-?\d+(?:\.\d+)?)", src)
    return float(m.group(1)) if m else fallback


def load_index() -> dict:
    with open(INDEX, encoding="utf-8") as fh:
        return json.load(fh)


def audio_path(clip_id: str) -> str | None:
    for ext in (".audio.flac", ".audio.wav"):
        p = os.path.join(CORPUS, clip_id + ext)
        if os.path.exists(p):
            return p
    return None


# The instant the shipping trigger fired, per clip, recovered by simulating it
# on the clip's own audio and confirmed against the contact time the app stored
# (which is the fire time minus the sound's travel from the plate). Kept here
# rather than in index.json because it is a property of the trigger, not of the
# clip.
FIRE_TOLERANCE_S = 0.040

# How far below the clip's loudest moment the stored contact time may sit and
# still be believed to BE the hit. Beyond it the trigger fired on something
# else, and the clip is excluded from the separation rather than counted as a
# very quiet hit.
CONTACT_MUST_BE_LOUDEST_WITHIN_DB = 10.0


def hit_and_noise(index: dict, band: float | None, floor_span: float,
                  quantile: float, edge_s: float = 0.06):
    """Loudest hit and loudest non-hit across the corpus, in dB over the floor.

    Positives are the bat crack in clips whose ball flight was verified, taken
    as the loudest window within FIRE_TOLERANCE_S of the stored contact time.
    Negatives are EVERY window of every clip the hitter labelled `no_swing` —
    those clips exist because something fooled the trigger, which makes them
    exactly the right negative set.

    A hit-labelled clip is EXCLUDED, loudly, when its stored contact time is
    not at an impulse — when the loudest window near it is far below the
    loudest window in the clip. That is not a missing measurement to be
    averaged in at whatever value the quiet moment happens to have; it means
    the trigger fired on something else and the stored contact time is of that
    other thing, so the clip cannot say how loud the hit was. `live_39` is such
    a clip: it fires 0.72 s before its stored contact, and including it drags
    the "quietest hit" from 27 dB to 5 and makes every band look equally
    hopeless.

    `edge_s` drops the last moments of each clip: `live_61` was truncated
    mid-write by a bug since fixed, and the cut itself is a broadband click.
    """
    hits, noises, excluded = [], [], []
    for c in index["clips"]:
        p = audio_path(c["id"])
        if not p:
            continue
        d, sr = load_audio(p)
        _, db, t, _ = simulate(d, sr, math.inf, 0.0, floor_span, quantile, band)
        if len(t) == 0:
            continue
        usable = (t >= floor_span) & (t <= len(d) / sr - edge_s)
        if not usable.any():
            continue
        if c["label"] == "hit" and c.get("contact_time"):
            near = usable & (np.abs(t - c["contact_time"]) <= FIRE_TOLERANCE_S + 0.02)
            if not near.any():
                excluded.append((c["id"], "contact time outside the audio"))
                continue
            at_contact = float(db[near].max())
            loudest = float(db[usable].max())
            if loudest - at_contact > CONTACT_MUST_BE_LOUDEST_WITHIN_DB:
                excluded.append((c["id"],
                                 f"contact time is not at an impulse "
                                 f"({at_contact:.0f} dB there, {loudest:.0f} dB "
                                 f"elsewhere in the clip)"))
                continue
            hits.append((c["id"], at_contact))
        elif c["label"] == "no_swing":
            noises.append((c["id"], float(db[usable].max())))
    return hits, noises, excluded


def verdict_for(separation: float) -> str:
    if separation < 6:
        return "UNUSABLE"
    return "marginal" if separation < 12 else "good"


def selftest() -> int:
    """Prove the DSP before it is allowed to judge a venue."""
    failures = []

    def check(name, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}{'  ' + detail if detail else ''}")
        if not ok:
            failures.append(name)

    sr = 48000
    t = np.arange(sr) / sr

    # A pure tone well inside the stop band must be attenuated; one well inside
    # the pass band must not be.
    lo = np.sin(2 * math.pi * 500 * t)
    hi = np.sin(2 * math.pi * 12000 * t)
    a_lo = 20 * math.log10(np.sqrt((highpass(lo, sr, 6000)[sr // 4:] ** 2).mean()) /
                           np.sqrt((lo ** 2).mean()))
    a_hi = 20 * math.log10(np.sqrt((highpass(hi, sr, 6000)[sr // 4:] ** 2).mean()) /
                           np.sqrt((hi ** 2).mean()))
    check("6 kHz high-pass kills a 500 Hz tone", a_lo < -40, f"{a_lo:.0f} dB")
    check("...and passes a 12 kHz tone", a_hi > -3, f"{a_hi:+.1f} dB")

    # An impulse on a quiet floor must fire once, not twice, and the refractory
    # must be what stops the second.
    x = np.random.default_rng(7).normal(0, 1e-3, sr)
    for at in (0.40, 0.60):
        x[int(at * sr):int(at * sr) + 48] += 0.5
    fires, _, _, _ = simulate(x, sr, 20.0, 2.0)
    check("two impulses 0.2 s apart fire once under a 2 s refractory",
          len(fires) == 1, f"{len(fires)} fires")
    fires, _, _, _ = simulate(x, sr, 20.0, 0.05)
    check("...and twice when the refractory is shorter than the gap",
          len(fires) == 2, f"{len(fires)} fires")

    # The floor must not be liftable by something shorter than half its span,
    # and must be fully liftable by something longer. This is the failure the
    # field report describes, stated as a test.
    def floor_after(noise_s):
        y = np.random.default_rng(3).normal(0, 1e-3, sr)
        y[int(0.3 * sr):int((0.3 + noise_s) * sr)] += np.random.default_rng(4).normal(
            0, 3e-2, int(noise_s * sr))
        _, _, tt, fl = simulate(y, sr, math.inf, 0.0)
        i = int(np.argmin(np.abs(tt - (0.3 + noise_s - 0.01))))
        return 20 * math.log10(fl[i] / 1e-3)
    short, long = floor_after(0.10), floor_after(0.45)
    check("a 0.10 s noise barely moves the 0.5 s median floor", short < 3,
          f"{short:+.1f} dB")
    check("a 0.45 s noise lifts it wholesale", long > 15, f"{long:+.1f} dB")

    print()
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        return 1
    print("ALL PASS — the filter, the refractory and the floor behave as described.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--sweep", action="store_true",
                    help="separation against the band listened in")
    ap.add_argument("--band", type=float, default=None,
                    help="high-pass cutoff in Hz applied before the RMS")
    ap.add_argument("--threshold", type=float, default=None,
                    help="dB over the floor (default: SLA.triggerDb)")
    ap.add_argument("--floor-span", type=float, default=FLOOR_WINDOW_S)
    ap.add_argument("--quantile", type=float, default=0.5)
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    threshold = args.threshold if args.threshold is not None else \
        swift_constant(CONSTANTS_SWIFT, "triggerDb", 20.0)
    refractory = 2.0
    index = load_index()

    if args.sweep:
        print("Separation between the quietest verified hit and the loudest thing\n"
              "in a clip the hitter says had no swing in it.\n"
              "Under 6 dB, `suggest_trigger_db` calls the venue unusable: no\n"
              "threshold can separate them, so tuning one cannot help.\n")
        print(f"{'high-pass':>10}  {'quietest hit':>12}  {'loudest non-hit':>15}  "
              f"{'separation':>10}  verdict")
        print("-" * 74)
        seen_excluded = None
        for band in (None, 1000, 2000, 3000, 4000, 6000, 8000):
            hits, noises, excluded = hit_and_noise(index, band, args.floor_span,
                                                   args.quantile)
            seen_excluded = excluded
            if not hits or not noises:
                print(f"{str(band or 'none'):>10}  (not enough labelled audio)")
                continue
            qh = min(v for _, v in hits)
            worst = max(noises, key=lambda kv: kv[1])
            sep = qh - worst[1]
            print(f"{(str(int(band)) + ' Hz') if band else 'none':>10}  {qh:12.1f}  "
                  f"{worst[1]:15.1f}  {sep:+10.1f}  {verdict_for(sep)} ({worst[0]})")
        if seen_excluded:
            print("\nExcluded from the positives:")
            for cid, why in seen_excluded:
                print(f"  {cid}: {why}")
        print(f"\nPositives: {len(hits)} clip(s). Read label_source in index.json\n"
              "before drawing a conclusion — an `inferred` label is exactly as\n"
              "fallible as the pipeline it is being used to test, and this many\n"
              "clips cannot fix a cutoff to better than the nearest octave.")
        return 0

    band_note = f", high-passed at {args.band:.0f} Hz" if args.band else ""
    print(f"Threshold {threshold:.0f} dB over a {args.floor_span:.2f} s "
          f"{'median' if args.quantile == 0.5 else str(args.quantile) + ' quantile'} "
          f"floor{band_note}\n")
    print(f"{'clip':9} {'label':9} {'src':8} {'fires (t @ dB)'}")
    print("-" * 78)
    for c in index["clips"]:
        p = audio_path(c["id"])
        if not p:
            print(f"{c['id']:9} {c['label']:9} {c.get('label_source','none'):8} "
                  "(no audio in the corpus)")
            continue
        d, sr = load_audio(p)
        fires, db, t, _ = simulate(d, sr, threshold, refractory,
                                   args.floor_span, args.quantile, args.band)
        shown = "  ".join(f"{a:.3f}s@{b:.1f}" for a, b in fires) or "— nothing fires"
        mark = ""
        if c["label"] == "no_swing" and fires:
            mark = "   <- FALSE POSITIVE"
        elif c["label"] == "hit" and not fires:
            mark = "   <- FALSE NEGATIVE"
        print(f"{c['id']:9} {c['label']:9} {c.get('label_source','none'):8} {shown}{mark}")
    print("\nA clip only exists because the trigger fired, so this cannot see the\n"
          "swings it missed. That is the one thing this corpus structurally cannot\n"
          "measure, and it is the hitter's main complaint.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
