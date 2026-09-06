#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
check_audio_trigger.py — measure how loud bat-ball contact is vs ambient (G5).

The Phase 1 app auto-triggers clip capture on the contact sound. This script
verifies, per venue, that the impulse stands >=15 dB above the rolling noise
floor so that trigger will be reliable.

Usage:
  python check_audio_trigger.py clips/tee_01.mov

Requires ffmpeg on PATH for audio extraction:  brew install ffmpeg
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RMS_WINDOW_S = 0.005      # 5 ms short-window RMS (the impulse)
FLOOR_WINDOW_S = 0.5      # rolling median noise floor
PASS_DB = 15.0

# The band the app's trigger listens in. Mirrors SLA.triggerHighPassHz and
# SLA.triggerHighPassOrder.
#
# This gate only means something if it measures what the phone measures — the
# whole promise of G5 is that a venue passing here will trigger there. The app
# stopped measuring the broadband signal when the corpus showed that level alone
# cannot separate a hit from what fools the trigger (see
# `spike/replay_trigger.py --sweep`), so this follows it into the high band.
#
# A venue measured with an older copy of this script is not comparable: the same
# clip reads about 20 dB higher here now, because the floor it is being compared
# against is the high band's, which is far quieter.
HIGHPASS_HZ = 6000.0
HIGHPASS_ORDER = 4


def highpass(x: np.ndarray, sr: float, fc: float = HIGHPASS_HZ,
             order: int = HIGHPASS_ORDER) -> np.ndarray:
    """Cascaded second-order Butterworth sections, direct form I.

    Written out rather than taken from scipy so the Swift port
    (`TriggerBiquad`) is the same ten lines of arithmetic and cannot drift, and
    so this script keeps working with numpy alone.
    """
    w0 = 2 * math.pi * fc / sr
    c, sn = math.cos(w0), math.sin(w0)
    alpha = sn / (2 * (1 / math.sqrt(2)))
    a0 = 1 + alpha
    b0, b1, b2 = (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0
    a1, a2 = -2 * c / a0, (1 - alpha) / a0
    y = x.astype(np.float64)
    for _ in range(order // 2):
        out = np.empty_like(y)
        x1 = x2 = y1 = y2 = 0.0
        for i, xn in enumerate(y):
            yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = yn
            x2, x1 = x1, xn
            y2, y1 = y1, yn
        y = out
    return y


def extract_wav(clip: str, dst: str):
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", clip,
           "-vn", "-ac", "1", "-ar", "48000", "-f", "wav", dst]
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip")
    args = ap.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found — install it with:  brew install ffmpeg")
        sys.exit(2)

    with tempfile.TemporaryDirectory() as td:
        wav_path = os.path.join(td, "a.wav")
        extract_wav(args.clip, wav_path)
        with wave.open(wav_path) as wf:
            sr = wf.getframerate()
            data = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16).astype(np.float64)

    if len(data) < sr:
        print("clip has <1 s of audio; slo-mo audio may be absent on trimmed exports — "
              "AirDrop the original clip.")
        sys.exit(2)

    # Into the band the trigger listens in, before anything is measured.
    data = highpass(data, sr)

    w = max(1, int(RMS_WINDOW_S * sr))
    n = len(data) // w
    rms = np.sqrt(np.mean(data[: n * w].reshape(n, w) ** 2, axis=1)) + 1e-9
    t = (np.arange(n) + 0.5) * w / sr

    fw = max(3, int(FLOOR_WINDOW_S / RMS_WINDOW_S))
    floor = np.array([np.median(rms[max(0, i - fw): i + 1]) for i in range(n)]) + 1e-9
    snr_db = 20 * np.log10(rms / floor)

    peak_i = int(np.argmax(snr_db))
    peak_db = float(snr_db[peak_i])
    verdict = "PASS" if peak_db >= PASS_DB else "FAIL"
    print(f"{os.path.basename(args.clip)}: peak impulse {peak_db:.1f} dB over rolling floor "
          f"above {HIGHPASS_HZ/1000:.0f} kHz at t={t[peak_i]:.3f}s  -> {verdict} "
          f"(G5 needs >= {PASS_DB:.0f} dB)")

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(t, snr_db, lw=0.8)
    ax.axhline(PASS_DB, color="r", ls="--", label=f"{PASS_DB:.0f} dB trigger threshold")
    ax.plot(t[peak_i], peak_db, "rv")
    ax.set_xlabel("t [s]")
    ax.set_ylabel("short-window RMS over floor [dB]")
    ax.set_title(os.path.basename(args.clip))
    ax.legend()
    os.makedirs("out", exist_ok=True)
    out = os.path.join("out", os.path.splitext(os.path.basename(args.clip))[0] + "_audio.png")
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    print(f"plot: {out}")


if __name__ == "__main__":
    main()
