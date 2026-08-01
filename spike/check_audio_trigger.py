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
          f"at t={t[peak_i]:.3f}s  -> {verdict} (G5 needs >= {PASS_DB:.0f} dB)")

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
