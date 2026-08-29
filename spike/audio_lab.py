#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
audio_lab.py — work out what actually separates bat-on-ball from everything else.

check_audio_trigger.py answers one question per clip: did the loudest impulse
clear 15 dB (gate G5). This answers a harder one: given real venue audio with
real hits and real noise in it, what measurable property tells them apart?

The live trigger uses level alone — a 5 ms RMS window against a 0.5 s rolling
median floor. Level is the cheapest thing that could work and it is what
ContactTrigger implements, but a dropped bat, a fence rattle and a ball hitting
a net are all loud. If level is not enough at a venue, something else has to
carry the decision, and this is where that gets decided from evidence instead
of from a guess.

So it lists every impulse it can find, with features that are plausible
discriminators, and — when told which ones were real hits — reports how well
each feature separates them.

Usage
-----
    python audio_lab.py audio/tee_01.wav
    python audio_lab.py audio/                      # every wav in a directory
    python audio_lab.py audio/tee_01.wav --labels 1.83 4.20 6.55

`--labels` are the times in seconds of real hits. Anything within
LABEL_TOLERANCE_S of one is a hit; everything else is a non-hit. With labels it
prints a separation report; without them it just lists what it found.

Getting a WAV out of a clip, on a Mac, with nothing installed
-------------------------------------------------------------
    afconvert -f WAVE -d LEI16@22050 -c 1 clips/tee_01.mov audio/tee_01.wav

`afconvert` ships with macOS. If it refuses the .mov, export Audio Only from
QuickTime first and convert the .m4a the same way.

A warning worth reading first: iPhone slow-motion clips often lose or stretch
their audio when exported from Photos. If the WAV is silent or the impulses
land at times that do not match the video, that is why — AirDrop the original
rather than a trimmed or shared copy.
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import sys
import wave

import numpy as np

# Matches ContactTrigger and check_audio_trigger.py exactly. Any feature work
# here has to sit on the same measurement the app makes, or it is describing a
# different signal from the one that will be running in the field.
RMS_WINDOW_S = 0.005
FLOOR_WINDOW_S = 0.5

# Impulses quieter than this are not worth listing. Deliberately well below the
# 15 dB gate: the point is to see what the app is choosing between, including
# the near-misses that a lowered threshold would start firing on.
CANDIDATE_DB = 6.0
# Two peaks closer than this are the same event ringing out.
REFRACTORY_S = 0.15
# How close a detected impulse has to be to a label to count as that hit.
LABEL_TOLERANCE_S = 0.08

# Frequency split for the brightness feature. Bat-on-ball is a hard, short,
# broadband crack; most venue noise (traffic, wind, voices, footsteps) carries
# proportionally more of its energy low down.
BRIGHT_SPLIT_HZ = 2000.0


def load_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path) as wf:
        sr = wf.getframerate()
        width = wf.getsampwidth()
        channels = wf.getnchannels()
        raw = wf.readframes(wf.getnframes())
    if width != 2:
        raise SystemExit(f"{path}: need 16-bit PCM, got {width * 8}-bit. "
                         "Re-convert with:  afconvert -f WAVE -d LEI16@22050 -c 1 in out.wav")
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float64)
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, sr


def level_curve(data: np.ndarray, sr: int) -> tuple[np.ndarray, np.ndarray]:
    """The app's own metric: short-window RMS in dB over a rolling median floor."""
    w = max(1, int(RMS_WINDOW_S * sr))
    n = len(data) // w
    if n < 4:
        return np.zeros(0), np.zeros(0)
    rms = np.sqrt(np.mean(data[: n * w].reshape(n, w) ** 2, axis=1)) + 1e-9
    fw = max(3, int(FLOOR_WINDOW_S / RMS_WINDOW_S))
    # Trailing median, like the live one: it can only use what it has already
    # heard. A centred window would let the impulse raise its own floor and
    # quietly flatter every measurement here relative to the field.
    floor = np.empty(n)
    for i in range(n):
        floor[i] = np.median(rms[max(0, i - fw):i + 1])
    floor += 1e-9
    db = 20 * np.log10(rms / floor)
    t = (np.arange(n) + 0.5) * w / sr
    return t, db


def find_candidates(t: np.ndarray, db: np.ndarray) -> list[int]:
    """Local maxima above CANDIDATE_DB, thinned by the refractory period."""
    if len(db) == 0:
        return []
    order = np.argsort(db)[::-1]
    picked: list[int] = []
    for i in order:
        if db[i] < CANDIDATE_DB:
            break
        if all(abs(t[i] - t[j]) >= REFRACTORY_S for j in picked):
            picked.append(int(i))
    return sorted(picked)


def features(data: np.ndarray, sr: int, t_peak: float, peak_db: float) -> dict:
    """Describe one impulse.

    Every feature here is cheap enough to run live on the phone if it turns out
    to earn its place — no point discovering a discriminator the app cannot
    afford to compute at 240 fps with a camera running.
    """
    centre = int(t_peak * sr)
    # 20 ms around the peak: long enough to hold the crack and its immediate
    # ring, short enough not to swallow whatever came next.
    half = int(0.010 * sr)
    lo, hi = max(0, centre - half), min(len(data), centre + half)
    seg = data[lo:hi]
    if len(seg) < 32:
        return {}

    windowed = seg * np.hanning(len(seg))
    spec = np.abs(np.fft.rfft(windowed))
    freqs = np.fft.rfftfreq(len(seg), 1 / sr)
    total = float(spec.sum()) + 1e-9
    bright = float(spec[freqs >= BRIGHT_SPLIT_HZ].sum()) / total
    centroid = float((freqs * spec).sum() / total)

    # Envelope shape, from the same 5 ms RMS the level curve uses. A struck ball
    # is near-instantaneous attack and fast decay; a voice or an engine is not.
    w = max(1, int(RMS_WINDOW_S * sr))
    env_lo = max(0, centre - int(0.05 * sr))
    env_hi = min(len(data), centre + int(0.15 * sr))
    env_seg = data[env_lo:env_hi]
    m = len(env_seg) // w
    rise_ms = decay_ms = float("nan")
    if m >= 4:
        env = np.sqrt(np.mean(env_seg[: m * w].reshape(m, w) ** 2, axis=1))
        p = int(np.argmax(env))
        thresh = env[p] * 0.2
        pre = np.where(env[:p + 1] < thresh)[0]
        post = np.where(env[p:] < thresh)[0]
        if len(pre):
            rise_ms = (p - pre[-1]) * RMS_WINDOW_S * 1000
        if len(post):
            decay_ms = post[0] * RMS_WINDOW_S * 1000

    peak_abs = float(np.max(np.abs(seg)))
    rms_abs = float(np.sqrt(np.mean(seg ** 2))) + 1e-9
    return {
        "t": t_peak,
        "db": peak_db,
        "bright": bright,
        "centroid_hz": centroid,
        "rise_ms": rise_ms,
        "decay_ms": decay_ms,
        "crest": peak_abs / rms_abs,
    }


def separation(hits: list[float], others: list[float]) -> tuple[float, str]:
    """How well one feature splits hits from everything else.

    Cohen's d, and a plain-language verdict. Deliberately not a trained
    classifier: with a handful of swings from one venue, a fitted model would
    describe that afternoon rather than the sport, and the whole point of this
    project is not shipping numbers that only look measured.
    """
    if len(hits) < 2 or len(others) < 2:
        return float("nan"), "not enough samples"
    h, o = np.array(hits), np.array(others)
    pooled = math.sqrt((h.var(ddof=1) + o.var(ddof=1)) / 2) + 1e-9
    d = abs(h.mean() - o.mean()) / pooled
    if d >= 2.0:
        verdict = "strong"
    elif d >= 1.0:
        verdict = "usable"
    elif d >= 0.5:
        verdict = "weak"
    else:
        verdict = "none"
    return d, verdict


def analyse(path: str, labels: list[float] | None) -> list[dict]:
    data, sr = load_wav(path)
    if len(data) < sr // 2:
        print(f"{os.path.basename(path)}: under half a second of audio — "
              "slo-mo exports often drop it. Use the original clip.")
        return []

    t, db = level_curve(data, sr)
    picked = find_candidates(t, db)
    rows = []
    for i in picked:
        f = features(data, sr, float(t[i]), float(db[i]))
        if not f:
            continue
        if labels is not None:
            f["is_hit"] = any(abs(f["t"] - L) <= LABEL_TOLERANCE_S for L in labels)
        f["clip"] = os.path.basename(path)
        rows.append(f)

    print(f"\n=== {os.path.basename(path)} — {len(data)/sr:.1f}s at {sr} Hz, "
          f"{len(rows)} impulses over {CANDIDATE_DB:.0f} dB ===")
    header = f"{'t (s)':>8} {'dB':>6} {'bright':>7} {'centroid':>9} {'rise':>7} {'decay':>7} {'crest':>6}"
    if labels is not None:
        header += "  label"
    print(header)
    for f in sorted(rows, key=lambda r: -r["db"]):
        line = (f"{f['t']:8.3f} {f['db']:6.1f} {f['bright']:7.2f} "
                f"{f['centroid_hz']:8.0f}Hz {f['rise_ms']:6.0f}m {f['decay_ms']:6.0f}m "
                f"{f['crest']:6.1f}")
        if labels is not None:
            line += "   HIT" if f["is_hit"] else "   ."
        print(line)

    if labels is not None:
        missed = [L for L in labels
                  if not any(abs(r["t"] - L) <= LABEL_TOLERANCE_S for r in rows)]
        if missed:
            print(f"  !! {len(missed)} labelled hit(s) produced no impulse at all "
                  f"over {CANDIDATE_DB:.0f} dB: {', '.join(f'{m:.2f}s' for m in missed)}")
            print("     Level alone cannot detect these. That is the finding.")
    return rows


def report(rows: list[dict]):
    hits = [r for r in rows if r.get("is_hit")]
    others = [r for r in rows if not r.get("is_hit")]
    print(f"\n=== separation over {len(rows)} impulses "
          f"({len(hits)} hits, {len(others)} not) ===")
    if not hits or not others:
        print("Need both hits and non-hits to compare. Label a clip that has "
              "some ordinary noise in it as well as the swings.")
        return

    for key, name in [("db", "level over floor"),
                      ("bright", f"energy above {BRIGHT_SPLIT_HZ:.0f} Hz"),
                      ("centroid_hz", "spectral centroid"),
                      ("rise_ms", "attack time"),
                      ("decay_ms", "decay time"),
                      ("crest", "crest factor")]:
        h = [r[key] for r in hits if not math.isnan(r[key])]
        o = [r[key] for r in others if not math.isnan(r[key])]
        d, verdict = separation(h, o)
        if math.isnan(d):
            print(f"  {name:<26} {verdict}")
            continue
        print(f"  {name:<26} d={d:5.2f}  {verdict:<8} "
              f"hits {np.mean(h):8.2f} vs {np.mean(o):8.2f}")

    # The question the app actually has to answer.
    lo_hit = min(r["db"] for r in hits)
    hi_other = max(r["db"] for r in others)
    print(f"\n  quietest hit {lo_hit:.1f} dB, loudest non-hit {hi_other:.1f} dB")
    if lo_hit > hi_other:
        mid = hi_other + 0.35 * (lo_hit - hi_other)
        print(f"  -> level alone separates them. A threshold near {mid:.0f} dB "
              "catches every hit and no noise here.")
    else:
        print("  -> level alone does NOT separate them: at least one noise is "
              "louder than the quietest hit.")
        print("     Look at the features above — any marked 'strong' is a "
              "second test worth adding to ContactTrigger.")


def selftest():
    """Prove the tool before trusting its verdict on real audio.

    Builds a venue with known content — three bright broadband cracks (bat on
    ball) plus a traffic rumble, a dropped bat and a fence rattle, both dull —
    and checks it finds the three and rates brightness a strong discriminator.
    A tool that reports which feature separates hits has to be shown to work on
    a case where the answer is known, or its verdict on a real clip is just an
    assertion.
    """
    sr, dur = 22050, 8.0
    n = int(sr * dur)
    rng = np.random.default_rng(7)
    t = np.arange(n) / sr
    x = rng.normal(0, 300, n)
    x += 900 * np.sin(2 * np.pi * 90 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.3 * t))

    def crack(at, amp, bright):
        i, L = int(at * sr), int(0.05 * sr)
        env = np.exp(-np.arange(L) / (sr * 0.006))
        noise = rng.normal(0, 1, L)
        if not bright:
            noise = np.convolve(noise, np.ones(40) / 40, "same")
        x[i:i + L] += amp * env * noise

    truth = [1.83, 4.20, 6.55]
    for at, amp in zip(truth, (26000, 21000, 17000)):
        crack(at, amp, bright=True)
    crack(3.10, 15000, bright=False)
    crack(5.40, 19000, bright=False)

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "audio", "_selftest.wav")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(np.clip(x, -32767, 32767).astype(np.int16).tobytes())

    rows = analyse(path, truth)
    report(rows)
    os.remove(path)

    found = sum(1 for r in rows if r.get("is_hit"))
    bright_hits = [r["bright"] for r in rows if r.get("is_hit")]
    bright_other = [r["bright"] for r in rows if not r.get("is_hit")]
    d, _ = separation(bright_hits, bright_other)
    ok = found == len(truth) and d >= 2.0
    print(f"\nSELF-TEST {'PASS' if ok else 'FAIL'}: found {found}/{len(truth)} "
          f"planted hits, brightness d={d:.2f} (needs >= 2.0)")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", help="a .wav, or a directory of them")
    ap.add_argument("--selftest", action="store_true",
                    help="run on synthetic audio with known hits and check the tool works")
    ap.add_argument("--labels", nargs="*", type=float, default=None,
                    help="times (s) of real hits; omit to just list impulses")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())
    if not args.path:
        ap.error("give a .wav or a directory, or --selftest")

    if os.path.isdir(args.path):
        paths = sorted(glob.glob(os.path.join(args.path, "*.wav")))
        if args.labels:
            sys.exit("--labels applies to one clip; pass a single .wav with it.")
    else:
        paths = [args.path]
    if not paths:
        sys.exit(f"no .wav files in {args.path}")

    all_rows: list[dict] = []
    for p in paths:
        all_rows += analyse(p, args.labels)
    if args.labels is not None and all_rows:
        report(all_rows)


if __name__ == "__main__":
    main()
