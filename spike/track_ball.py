#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
track_ball.py — extract the hit ball's flight path from one slo-mo clip.

Usage:
  python track_ball.py clips/tee_01.mov                      # interactive
  python track_ball.py clips/tee_01.mov --auto               # no GUI
  python track_ball.py clips/tee_01.mov --debug-video --fps 240

Interactive mode opens a scrubber so you mark the contact frame yourself:
  a / d   step 1 frame back / forward        w / s   step 10 frames
  g       jump to auto-guessed contact       space   confirm contact frame
  q       quit without saving

Output: out/<clip>.csv (frame, t, x_px, y_px, diameter_px, area_px) plus
metadata header lines, and optionally out/<clip>_debug.mp4 with the detected
track drawn on every frame.
"""

from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np

import sla_common as sla


def collect_candidates(cap, fps, args, n_frames):
    """Pass 1: stream frames, detect per-frame ball candidates (memory-light)."""
    per_frame = {}
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    idx = 0
    prev_gray = None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if args.normalize_brightness:
            frame = sla.normalize_brightness(frame)
        # Frame differencing, not MOG2. On two real field clips MOG2 left 446
        # candidate chains where differencing left 3: a learned background
        # model needs warm-up, and wind-moved foliage keeps re-entering the
        # foreground. The ball is the fastest thing in the picture, which is
        # the one case differencing is good at.
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fg = sla.motion_mask(gray, prev_gray)
        prev_gray = gray
        if fg is None and not args.no_bgsub:
            idx += 1                       # first frame: nothing to difference
            continue
        cands = sla.detect_ball_candidates(
            frame, idx, idx / fps,
            fg_mask=fg if not args.no_bgsub else None,
            hsv_lo=tuple(args.hsv_lo), hsv_hi=tuple(args.hsv_hi),
            min_radius_px=args.min_radius, max_radius_px=args.max_radius,
        )
        if cands:
            per_frame[idx] = cands
        idx += 1
        if idx % 200 == 0:
            print(f"  scanned {idx}/{n_frames} frames...", file=sys.stderr)
    return per_frame, idx


def pick_contact_interactive(cap, guess_frame, n_frames, fps):
    """Frame scrubber; returns chosen contact frame or None if aborted."""
    win = "mark contact frame  (a/d +-1, w/s +-10, g=guess, space=confirm, q=quit)"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    f = max(0, guess_frame)
    while True:
        cap.set(cv2.CAP_PROP_POS_FRAMES, f)
        ok, frame = cap.read()
        if not ok:
            # Step BACK and keep servicing the keyboard. CAP_PROP_FRAME_COUNT
            # overstates decodable frames on iPhone slo-mo regularly; clamping
            # to the same failing index and continuing spun this loop at 100%
            # CPU with a frozen window and no way to press q.
            f = max(0, f - 1)
            if (cv2.waitKey(30) & 0xFF) == ord("q"):
                cv2.destroyWindow(win)
                return None
            continue
        disp = frame.copy()
        cv2.putText(disp, f"frame {f}/{n_frames-1}  t={f/fps:.4f}s  (guess={guess_frame})",
                    (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 255), 2)
        cv2.imshow(win, disp)
        k = cv2.waitKey(0) & 0xFF
        if k == ord("a"):
            f = max(0, f - 1)
        elif k == ord("d"):
            f = min(n_frames - 1, f + 1)
        elif k == ord("w"):
            f = max(0, f - 10)
        elif k == ord("s"):
            f = min(n_frames - 1, f + 10)
        elif k == ord("g"):
            f = guess_frame
        elif k == ord(" "):
            cv2.destroyWindow(win)
            return f
        elif k == ord("q"):
            cv2.destroyWindow(win)
            return None


def write_debug_video(cap, fps, track, contact_frame, out_path, n_frames):
    """Pass 2: stream again, draw candidates trail + contact marker."""
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    vw = cv2.VideoWriter(out_path, cv2.VideoWriter_fourcc(*"mp4v"), min(fps, 60.0), (w, h))
    by_frame = {o.frame: o for o in track}
    trail = []
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        o = by_frame.get(idx)
        if o is not None:
            trail.append((int(o.x), int(o.y)))
        for i in range(1, len(trail)):
            cv2.line(frame, trail[i - 1], trail[i], (0, 0, 255), 2)
        if o is not None:
            cv2.circle(frame, (int(o.x), int(o.y)), max(3, int(o.diameter_px / 2)), (0, 255, 0), 2)
        label = f"frame {idx}"
        if idx == contact_frame:
            label += "  CONTACT"
            cv2.rectangle(frame, (0, 0), (w - 1, h - 1), (0, 255, 255), 8)
        cv2.putText(frame, label, (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 255), 2)
        vw.write(frame)
        idx += 1
    vw.release()
    print(f"debug video: {out_path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip")
    ap.add_argument("--out", help="output CSV path (default out/<clip>.csv)")
    ap.add_argument("--fps", type=float, help="override container fps (slo-mo metadata is often wrong; use 240)")
    ap.add_argument("--auto", action="store_true", help="no GUI: use auto-detected contact frame")
    ap.add_argument("--contact-frame", type=int, help="known contact frame (skips picker)")
    ap.add_argument("--debug-video", action="store_true", help="write out/<clip>_debug.mp4")
    ap.add_argument("--direction", choices=["left", "right", "auto"], default="auto",
                    help="outbound hit direction in frame")
    ap.add_argument("--hsv-lo", type=int, nargs=3, default=list(sla.HSV_LO_DEFAULT), metavar=("H", "S", "V"))
    ap.add_argument("--hsv-hi", type=int, nargs=3, default=list(sla.HSV_HI_DEFAULT), metavar=("H", "S", "V"))
    ap.add_argument("--min-radius", type=float, default=sla.MIN_RADIUS_PX_DEFAULT)
    ap.add_argument("--max-radius", type=float, default=sla.MAX_RADIUS_PX_DEFAULT)
    ap.add_argument("--no-bgsub", action="store_true",
                    help="disable motion gating (colour window alone; expect heavy clutter outdoors)")
    ap.add_argument("--normalize-brightness", action="store_true", help="counter LED flicker banding")
    args = ap.parse_args()

    cap, fps, n_frames, w, h = sla.open_video(args.clip, args.fps)
    print(f"clip: {args.clip}  {w}x{h}  fps={fps:g}  frames={n_frames}")
    if fps < 100 and not args.fps:
        print("WARNING: fps < 100 — slo-mo metadata often lies. If this clip is "
              "240fps slo-mo, re-run with --fps 240.", file=sys.stderr)

    print("pass 1: detecting ball candidates...")
    per_frame, scanned = collect_candidates(cap, fps, args, n_frames)
    n_frames = scanned
    print(f"  candidates on {len(per_frame)} of {n_frames} frames")

    tracks = sla.build_tracks(per_frame, fps)
    track = sla.select_outbound_track(tracks, fps, direction=args.direction)
    if track is None:
        print("ERROR: no coherent ball track found. Try --hsv-lo/--hsv-hi tuning, "
              "--min-radius/--max-radius, --no-bgsub, or --normalize-brightness.")
        sys.exit(2)
    guess = track[0].frame
    print(f"tracked {len(track)} frames, auto-guessed contact at frame {guess}")

    if args.contact_frame is not None:
        contact = args.contact_frame
    elif args.auto:
        contact = guess
    else:
        picked = pick_contact_interactive(cap, guess, n_frames, fps)
        if picked is None:
            print("aborted.")
            sys.exit(1)
        contact = picked

    os.makedirs("out", exist_ok=True)
    stem = os.path.splitext(os.path.basename(args.clip))[0]
    out_csv = args.out or os.path.join("out", stem + ".csv")
    sla.write_track_csv(out_csv, track, fps, meta={
        "clip": os.path.basename(args.clip),
        "contact_frame": contact,
        "contact_time": f"{contact / fps:.6f}",
        "direction": args.direction,
    })
    print(f"wrote {out_csv}  (contact_frame={contact})")

    if args.debug_video:
        write_debug_video(cap, fps, track, contact, os.path.join("out", stem + "_debug.mp4"), n_frames)
    cap.release()


if __name__ == "__main__":
    main()
