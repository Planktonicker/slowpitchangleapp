#!/usr/bin/env python3
# SwingLab — Copyright (C) 2026 Planktonicker
# SPDX-License-Identifier: AGPL-3.0-only
# Full terms in LICENSE at the repository root. No warranty.
"""
replay_corpus.py — re-run selection and the publish gates over every clip in
`spike/corpus/`, and say which ones the pipeline gets wrong.

The problem this exists to solve: footage arrives as a 20 MB `.mov` in a chat
attachment, gets looked at once, and is gone by the next session. Every change
to the selector was then argued from memory of a clip nobody could re-open. A
`.mov` cannot be committed — it is gitignored, and rightly — but the evidence
inside it can: the candidate detections, their timing, and what the hitter said
happened. That is small enough to keep forever, and it is all a selector
argument ever actually needs.

So a clip is added ONCE and replayed for good:

    python replay_corpus.py                        # replay everything
    python replay_corpus.py --only live_48 live_42
    python replay_corpus.py --verbose              # per-clip detail
    python replay_corpus.py --json                 # machine-readable

Adding footage — pick whichever you have:

    # a raw clip: runs the Python detector over it and distils a trace
    python replay_corpus.py --add-clip live_61.mov --id live_61 \
        --label no_swing --label-source hitter --contact 1.58 \
        --notes "session, false positive, 6 m away"

    # a diagnostics bundle off the phone (Swings -> Select -> Share)
    python replay_corpus.py --add-bundle diagnostics_5swings_20260905.json

    # a single trace exported beside a clip
    python replay_corpus.py --add-trace live_61.trace.json --id live_61 --label hit

    # fix or add a label later; nothing is re-detected
    python replay_corpus.py --relabel live_40 hit --label-source hitter

**Labels are the scarce resource, not clips.** A clip whose label is "unknown"
can show that behaviour CHANGED between two builds, but it cannot say which
build was right. Only the hitter knows whether a swing happened, so
`label_source` is recorded and printed: `hitter` is evidence, `inferred` is my
reading of the geometry and is exactly as fallible as the thing it is being
used to test.

What is replayed is SELECTION and the PUBLISH GATES, not detection: the
candidates are frozen at the build that produced them. That is the honest
boundary of this tool — it will catch a selector that picks the wrong track and
a gate that lets junk through, and it will not notice a detector that stopped
finding the ball. `--add-clip` re-detects with the Python reference, which is
the one path here that does exercise detection.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import re
import sys

import sla_common as sla

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
INDEX = os.path.join(CORPUS, "index.json")
PLAUSIBILITY_SWIFT = os.path.join(
    HERE, "..", "app", "Sources", "Core", "TrackPlausibility.swift")

LABELS = ("hit", "no_swing", "unknown")
LABEL_SOURCES = ("hitter", "inferred", "none")


# ---------------------------------------------------------------------------
# Publish gates
# ---------------------------------------------------------------------------
#
# `TrackPlausibility` is app-only and deliberately NOT parity-pinned — the
# Python reference is handed a track and asked to measure it, and deciding
# whether to believe one is not its job. So this file has to carry a second
# copy of the gates, and a second copy is a second thing to drift.
#
# The numbers are therefore READ OUT OF THE SWIFT rather than restated here.
# A threshold changed in the app changes what this harness reports on the next
# run, with nothing to remember. Only the shape of the tests lives here, and
# the shape is the part that gets reviewed when it changes.

_DEFAULT_GATES = {
    "maxFlightS": 2.5, "minLaunchDeg": -25.0, "maxLaunchDeg": 75.0,
    "minStraightness": 0.80, "minDiametersPerFrame": 0.20,
    "maxExitVeloMph": 130.0, "residualMeaninglessBelow": 6,
    "maxShortTrackSpeedGrowth": 2.0, "maxStartAfterContactS": 0.25,
}


def load_gates(path: str = PLAUSIBILITY_SWIFT) -> tuple[dict, str]:
    """Gate thresholds, parsed from TrackPlausibility.swift.

    Returns (gates, provenance). Falls back to the defaults above with a loud
    provenance string rather than failing: a harness that refuses to run
    because a Swift file moved is a harness nobody runs.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        return dict(_DEFAULT_GATES), f"BUILT-IN DEFAULTS ({exc.strerror}) — VERIFY"
    found = {}
    for name, raw in re.findall(r"static let (\w+)\s*=\s*(-?\d+(?:\.\d+)?)", src):
        found[name] = float(raw) if "." in raw else int(raw)
    missing = [k for k in _DEFAULT_GATES if k not in found]
    gates = dict(_DEFAULT_GATES)
    gates.update({k: v for k, v in found.items() if k in _DEFAULT_GATES})
    if missing:
        return gates, f"TrackPlausibility.swift (missing {', '.join(missing)} — VERIFY)"
    return gates, "TrackPlausibility.swift"


def speed_growth(track) -> float | None:
    """Last frame-to-frame speed over the first. Mirror of the Swift."""
    steps = []
    for a, b in zip(track, track[1:]):
        dt = b.t - a.t
        if dt > 0:
            steps.append(math.hypot(b.x - a.x, b.y - a.y) / dt)
    if len(steps) < 2 or steps[0] <= 0:
        return None
    return steps[-1] / steps[0]


def diameters_per_frame(track, fps: float) -> float | None:
    """Median step travel as a multiple of the object's own median diameter."""
    if fps <= 0 or len(track) < 2:
        return None
    steps = []
    for a, b in zip(track, track[1:]):
        dt = b.t - a.t
        if dt > 0:
            steps.append(math.hypot(b.x - a.x, b.y - a.y) / dt)
    diameters = sorted(o.diameter_px for o in track if o.diameter_px > 0)
    if not steps or not diameters:
        return None
    steps.sort()
    median_step = steps[len(steps) // 2]
    median_diameter = diameters[len(diameters) // 2]
    if median_diameter <= 0:
        return None
    return (median_step / fps) / median_diameter


def rejection(track, launch_angle_deg, flags, fps, contact_time,
              exit_velo_mph, g) -> str | None:
    """Why this track is not worth publishing, or None. Mirror of the Swift.

    Kept in the same ORDER as `TrackPlausibility.rejection` so the reason a
    clip is refused here is the reason the phone would give, not merely one of
    several true ones.
    """
    if not track:
        return "no ball was tracked at all"
    duration = track[-1].t - track[0].t
    if duration > g["maxFlightS"]:
        return f"in frame for {duration:.1f}s"
    if launch_angle_deg < g["minLaunchDeg"] or launch_angle_deg > g["maxLaunchDeg"]:
        return f"{launch_angle_deg:.0f}° is not a hit"
    straight = sla.track_straightness(track)
    if straight < g["minStraightness"]:
        return f"path wanders (straightness {straight:.2f})"
    if sla.FLAG_HIGH_RESIDUAL in flags:
        return "does not fit a parabola"
    per_frame = diameters_per_frame(track, fps)
    if fps > 0 and per_frame is not None and per_frame < g["minDiametersPerFrame"]:
        return f"moved {per_frame:.2f} of its own width per frame"
    # Both contact-relative tests are skipped when the analyzer has already
    # said the contact time is wrong — see the long note in the Swift.
    trustworthy = sla.FLAG_CONTACT_TIME_REJECTED not in flags
    if trustworthy and contact_time is not None:
        late = track[0].t - contact_time
        if late > g["maxStartAfterContactS"]:
            return f"first seen {late:.2f}s after contact"
        if track[-1].t < contact_time:
            return f"whole path over {(contact_time - track[-1].t) * 1000:.0f}ms before contact"
    if exit_velo_mph > g["maxExitVeloMph"]:
        return f"{exit_velo_mph:.0f} mph is impossible"
    if len(track) < g["residualMeaninglessBelow"]:
        growth = speed_growth(track)
        if growth is not None and growth > g["maxShortTrackSpeedGrowth"]:
            return f"sped up {growth:.1f}-fold over {len(track)} frames"
    return None


# ---------------------------------------------------------------------------
# Frame timing
# ---------------------------------------------------------------------------

# How much longer than the shortest interval an interval may be and still
# count as ONE frame period. Mirror of `ClipAnalyzer.singleIntervalTolerance`.
SINGLE_INTERVAL_TOLERANCE = 1.75


def derive_fps(times_by_frame: dict[int, float]) -> tuple[float | None, dict]:
    """Frame rate from the frame->timestamp map. Mirror of `ClipAnalyzer
    .frameTiming`, restricted to ADJACENT frames.

    Restricted because a trace only records frames that produced a candidate,
    so most gaps in it are "nothing yellow moved", not a dropped frame. Only
    consecutive indices are known to be one period apart, and that is enough:
    the estimator wants the base period, and every adjacent pair is one.

    Why this is not simply `1 / median(interval)`: `AVAssetWriter` defaults a
    passthrough video track to timescale 600, which cannot express 240 fps —
    2.5 ticks per frame — so a flawless capture alternates 2- and 3-tick
    durations, 3333 and 5000 us. The median of that is 5000, i.e. 200 fps, and
    that is exactly the number stamped into the four oldest clips here. Every
    speed measured on them is 20% low as a result. The mean of the singles is
    4167 us and correct.
    """
    frames = sorted(times_by_frame)
    intervals = [times_by_frame[b] - times_by_frame[a]
                 for a, b in zip(frames, frames[1:])
                 if b - a == 1 and times_by_frame[b] > times_by_frame[a]]
    if len(intervals) < 4:
        return None, {"reason": f"only {len(intervals)} adjacent-frame intervals"}
    s = sorted(intervals)
    shortest = s[max(0, len(s) // 20)]          # 5th percentile, not the min
    singles = [i for i in s if i <= shortest * SINGLE_INTERVAL_TOLERANCE]
    if not singles or shortest <= 0:
        return None, {"reason": "no usable intervals"}
    base = sum(singles) / len(singles)
    if base <= 0:
        return None, {"reason": "base period is zero"}
    irregular = sum(1 for i in intervals
                    if not (round(i / base) >= 1
                            and abs(i - round(i / base) * base) <= base * 0.25))
    return 1.0 / base, {
        "intervals": len(intervals),
        "singles": len(singles),
        "irregular_fraction": irregular / len(intervals),
        "median_fps_would_be": 1.0 / s[len(s) // 2],
    }


# ---------------------------------------------------------------------------
# Corpus I/O
# ---------------------------------------------------------------------------

def load_index() -> dict:
    if not os.path.exists(INDEX):
        return {"swinglab_corpus": 1, "clips": []}
    with open(INDEX, "r", encoding="utf-8") as fh:
        return json.load(fh)


def save_index(index: dict) -> None:
    index["clips"].sort(key=lambda c: c["id"])
    index["count"] = len(index["clips"])
    os.makedirs(CORPUS, exist_ok=True)
    with open(INDEX, "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=2, sort_keys=True)
        fh.write("\n")


def trace_path(clip_id: str) -> str:
    return os.path.join(CORPUS, clip_id + ".trace.json.gz")


def load_trace(path: str) -> dict:
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def save_trace(clip_id: str, trace: dict) -> str:
    path = trace_path(clip_id)
    os.makedirs(CORPUS, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        json.dump(trace, fh, separators=(",", ":"), sort_keys=True)
    return path


def observations(trace: dict) -> tuple[dict[int, list], dict[int, float]]:
    """Per-frame candidates and the frame->timestamp map, from a trace."""
    per_frame: dict[int, list] = {}
    times: dict[int, float] = {}
    for c in trace.get("candidates", []):
        f = int(c["frame"])
        obs = sla.BallObservation(
            frame=f, t=float(c["t"]), x=float(c["x"]), y=float(c["y"]),
            diameter_px=float(c.get("diameterPx", c.get("diameter_px", 0.0))),
            area_px=float(c.get("areaPx", c.get("area_px", 0.0))),
        )
        per_frame.setdefault(f, []).append(obs)
        times.setdefault(f, obs.t)
    return per_frame, times


# ---------------------------------------------------------------------------
# Replay
# ---------------------------------------------------------------------------

def replay(entry: dict, gates: dict) -> dict:
    out = {"id": entry["id"], "label": entry.get("label", "unknown"),
           "label_source": entry.get("label_source", "none"),
           "notes": entry.get("notes", "")}
    path = trace_path(entry["id"])
    if not os.path.exists(path):
        out["error"] = "trace missing"
        return out
    trace = load_trace(path)
    per_frame, times = observations(trace)
    out["candidates"] = sum(len(v) for v in per_frame.values())
    out["candidate_frames"] = len(per_frame)
    out["trimmed_to_window_s"] = trace.get("candidatesTrimmedToWindowS")

    fps, timing = derive_fps(times)
    if fps is None:
        fps = entry.get("fps")
        out["fps_source"] = "index (" + timing.get("reason", "?") + ")"
    else:
        out["fps_source"] = "frame timing"
    out["fps"] = fps
    out["timing"] = timing
    if not fps:
        out["error"] = "no frame rate"
        return out

    contact = entry.get("contact_time")
    if contact is None:
        contact = trace.get("contactT")
    out["contact_time"] = contact

    tracks = sla.build_tracks(per_frame, fps)
    out["tracks_built"] = len(tracks)
    out["field"] = sorted(
        ({"frames": len(t), "start_t": t[0].t, "end_t": t[-1].t,
          "median_step_px_s": sla.median_step_speed(t) or 0.0,
          "straightness": sla.track_straightness(t)}
         for t in tracks if len(t) >= 2),
        key=lambda d: -d["median_step_px_s"])[:6]
    chosen = sla.select_outbound_track(tracks, fps, contact_time=contact)
    if not chosen:
        out["selected"] = None
        out["published"] = False
        out["reason"] = "nothing selected"
    else:
        out["selected"] = {
            "frames": len(chosen),
            "start_t": chosen[0].t,
            "end_t": chosen[-1].t,
            "start_minus_contact": (chosen[0].t - contact) if contact is not None else None,
            "straightness": sla.track_straightness(chosen),
            "median_step_px_s": sla.median_step_speed(chosen),
            "diameters_per_frame": diameters_per_frame(chosen, fps),
            "speed_growth": speed_growth(chosen),
            "median_diameter_px": sorted(o.diameter_px for o in chosen)[len(chosen) // 2],
        }
        try:
            m = sla.analyze_track(chosen, contact_time=contact)
            out["selected"]["launch_angle_deg"] = m.launch_angle_deg
            out["selected"]["exit_velo_mph"] = m.exit_velo_mph
            out["selected"]["flags"] = list(m.flags)
            why = rejection(chosen, m.launch_angle_deg, m.flags, fps,
                            contact, m.exit_velo_mph, gates)
        except Exception as exc:                      # analysis is not the test
            out["selected"]["analyze_error"] = repr(exc)
            why = "analyze_track raised"
        out["published"] = why is None
        out["reason"] = why or "published"
        if contact is None:
            out["reason"] += "  [no contact time — the two contact gates were skipped]"
        elif sla.FLAG_CONTACT_TIME_REJECTED in out["selected"].get("flags", []):
            out["reason"] += "  [contact time disowned — the two contact gates were skipped]"

    label = out["label"]
    if label == "hit":
        out["verdict"] = "ok" if out["published"] else "FALSE NEGATIVE"
    elif label == "no_swing":
        out["verdict"] = "FALSE POSITIVE" if out["published"] else "ok"
    else:
        out["verdict"] = "unlabelled"
    return out


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

def detect_from_clip(path: str, progress=True) -> dict:
    """Run the Python detector over a clip and distil a trace.

    Timestamps come from the container, not `frame / fps`. That is the whole
    point of keeping them: `live_40` and `live_61` drop a quarter of their
    frames, and a nominal timestamp hides exactly that.
    """
    import cv2                                  # only this path needs it
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit(f"cannot open {path}")
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    candidates, idx, prev_gray = [], 0, None
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        fg = sla.motion_mask(gray, prev_gray)
        prev_gray = gray
        if fg is None:
            idx += 1                            # first frame: nothing to diff
            continue
        for o in sla.detect_ball_candidates(frame, idx, t, fg_mask=fg):
            candidates.append({"frame": o.frame, "t": o.t, "x": o.x, "y": o.y,
                               "diameterPx": o.diameter_px, "areaPx": o.area_px})
        idx += 1
        if progress and idx % 100 == 0:
            print(f"  {idx}/{n} frames, {len(candidates)} candidates",
                  file=sys.stderr)
    cap.release()
    return {"candidates": candidates, "framesDecoded": idx,
            "source": "spike/replay_corpus.py --add-clip (Python reference detector)"}


def upsert(index: dict, entry: dict) -> None:
    for i, c in enumerate(index["clips"]):
        if c["id"] == entry["id"]:
            merged = dict(c)
            merged.update({k: v for k, v in entry.items() if v is not None})
            index["clips"][i] = merged
            return
    index["clips"].append(entry)


def fps_from_bundle_entry(swing: dict) -> float | None:
    """The measured frame rate, dug out of whichever artefact carries it.

    The CSV header is tried FIRST and then distrusted: builds before the
    timescale fix wrote `# fps=200.0` onto flawless 240 fps captures. It is
    recorded so the drift is visible, never used to overrule the frame timing.
    """
    csv = swing.get("trackCSV") or ""
    m = re.search(r"^#\s*fps=([\d.]+)", csv, re.M)
    if m:
        return float(m.group(1))
    report = swing.get("report") or ""
    m = re.search(r"([\d.]+)\s*fps", report)
    return float(m.group(1)) if m else None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", help="replay just these clip ids")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--add-clip", metavar="MOV", help="detect over a raw clip and add it")
    ap.add_argument("--add-trace", metavar="JSON", help="add an exported trace")
    ap.add_argument("--add-bundle", metavar="JSON", help="add every swing in a phone bundle")
    ap.add_argument("--relabel", nargs=2, metavar=("ID", "LABEL"))
    ap.add_argument("--id", help="clip id for --add-clip / --add-trace")
    ap.add_argument("--label", choices=LABELS, default=None)
    ap.add_argument("--label-source", choices=LABEL_SOURCES, default=None)
    ap.add_argument("--contact", type=float, help="contact time, seconds")
    ap.add_argument("--notes", default=None)
    ap.add_argument("--build", default=None, help="what produced it, e.g. a commit sha")
    args = ap.parse_args()

    index = load_index()
    gates, provenance = load_gates()

    if args.relabel:
        clip_id, label = args.relabel
        if label not in LABELS:
            raise SystemExit(f"label must be one of {LABELS}")
        upsert(index, {"id": clip_id, "label": label,
                       "label_source": args.label_source or "hitter",
                       "notes": args.notes})
        save_index(index)
        print(f"{clip_id}: label={label} source={args.label_source or 'hitter'}")
        return 0

    if args.add_clip or args.add_trace:
        clip_id = args.id or os.path.basename(
            args.add_clip or args.add_trace).split(".")[0]
        if args.add_clip:
            trace = detect_from_clip(args.add_clip)
        else:
            trace = load_trace(args.add_trace)
        save_trace(clip_id, trace)
        _, times = observations(trace)
        fps, _ = derive_fps(times)
        upsert(index, {
            "id": clip_id,
            "label": args.label or "unknown",
            "label_source": args.label_source or ("none" if not args.label else "hitter"),
            "contact_time": args.contact if args.contact is not None else trace.get("contactT"),
            "fps": fps,
            "notes": args.notes or "",
            "build": args.build or "",
        })
        save_index(index)
        print(f"added {clip_id}: {len(trace.get('candidates', []))} candidates, "
              f"fps {fps:.2f}" if fps else f"added {clip_id}")
        return 0

    if args.add_bundle:
        with open(args.add_bundle, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        if "swinglab_diagnostics_bundle" not in doc:
            raise SystemExit("not a SwingLab diagnostics bundle")
        for swing in doc.get("swings", []):
            clip_id = os.path.splitext(os.path.basename(swing.get("clip", "")))[0]
            trace = swing.get("trace")
            if not clip_id or clip_id == "(none)" or not trace:
                print(f"  skipped {clip_id or '(unnamed)'}: no trace in the bundle")
                continue
            save_trace(clip_id, trace)
            _, times = observations(trace)
            fps, _ = derive_fps(times)
            upsert(index, {
                "id": clip_id,
                "label": args.label or "unknown",
                "label_source": args.label_source or ("none" if not args.label else "hitter"),
                "contact_time": swing.get("contactTime"),
                "fps": fps,
                "stamped_fps": fps_from_bundle_entry(swing),
                "app_launch_angle_deg": swing.get("launchAngleDeg"),
                "app_exit_velo_mph": swing.get("exitVeloMph"),
                "app_flags": swing.get("flags"),
                "captured_at": swing.get("capturedAt"),
                "session_id": swing.get("sessionID"),
                "notes": args.notes or "",
                "build": args.build or "",
            })
            trimmed = trace.get("candidatesTrimmedToWindowS")
            warn = (f"  (candidates trimmed to +-{trimmed}s around contact — "
                    "selection outside that window cannot be replayed)"
                    if trimmed else "")
            print(f"  added {clip_id}: {len(trace.get('candidates', []))} candidates{warn}")
        save_index(index)
        print("\nNow give each one a label the hitter would recognise:\n"
              "  python replay_corpus.py --relabel <id> hit|no_swing")
        return 0

    clips = index["clips"]
    if args.only:
        wanted = set(args.only)
        clips = [c for c in clips if c["id"] in wanted]
        for missing in sorted(wanted - {c["id"] for c in clips}):
            print(f"no such clip: {missing}", file=sys.stderr)
    if not clips:
        print("corpus is empty — see spike/corpus/README.md")
        return 1

    results = [replay(c, gates) for c in clips]

    if args.json:
        json.dump({"gates": gates, "gates_from": provenance, "results": results},
                  sys.stdout, indent=2, default=str)
        print()
        return 0

    print(f"gates from {provenance}\n")
    head = (f"{'clip':10} {'label':9} {'src':8} {'fps':>7} {'trk':>4} {'n':>3} "
            f"{'t-tc':>7} {'d/frm':>6} {'grow':>5} {'strt':>5} {'LA':>6} "
            f"{'mph':>6}  verdict")
    print(head)
    print("-" * len(head))
    for r in results:
        if r.get("error"):
            print(f"{r['id']:10} {r['label']:9} {r['label_source']:8} "
                  f"{'':>7} {'':>4} {'':>3} {'':>7} {'':>6} {'':>5} {'':>5} "
                  f"{'':>6} {'':>6}  ERROR: {r['error']}")
            continue
        s = r.get("selected")
        def num(v, fmt):
            if isinstance(v, (int, float)):
                return format(v, fmt)
            width = int(re.match(r"(\d+)", fmt).group(1)) if re.match(r"\d", fmt) else 1
            return "-".rjust(width)
        cells = [f"{r['id']:10}", f"{r['label']:9}", f"{r['label_source']:8}",
                 f"{num(r.get('fps'), '7.2f')}", f"{r['tracks_built']:>4}"]
        if s:
            cells += [f"{s['frames']:>3}",
                      f"{num(s.get('start_minus_contact'), '7.3f')}",
                      f"{num(s.get('diameters_per_frame'), '6.2f')}",
                      f"{num(s.get('speed_growth'), '5.1f')}",
                      f"{num(s.get('straightness'), '5.2f')}",
                      f"{num(s.get('launch_angle_deg'), '6.1f')}",
                      f"{num(s.get('exit_velo_mph'), '6.1f')}"]
        else:
            cells += [f"{'-':>3}"] + [f"{'-':>7}", f"{'-':>6}", f"{'-':>5}",
                                      f"{'-':>5}", f"{'-':>6}", f"{'-':>6}"]
        mark = {"ok": "ok", "unlabelled": "?", }.get(r["verdict"], r["verdict"])
        pub = "PUBLISHED" if r["published"] else "withheld"
        print(" ".join(cells) + f"  {mark:14} {pub}: {r['reason']}")
        if args.verbose:
            t = r.get("timing", {})
            if t.get("median_fps_would_be"):
                print(f"           timing: {t['intervals']} adjacent intervals, "
                      f"{t['singles']} at the base period, "
                      f"{t['irregular_fraction']:.1%} irregular; "
                      f"a median estimate would have said "
                      f"{t['median_fps_would_be']:.1f} fps")
            if r.get("trimmed_to_window_s"):
                print(f"           candidates trimmed to ±{r['trimmed_to_window_s']}s "
                      "around contact — selection outside that window is not replayable")
            print(f"           field of {r['tracks_built']} tracks, fastest first:")
            for f in r.get("field", []):
                print(f"             {f['frames']:>3} frames  "
                      f"{f['start_t']:.3f}..{f['end_t']:.3f}s  "
                      f"{f['median_step_px_s']:>8.0f} px/s  "
                      f"straightness {f['straightness']:.2f}")
            if r.get("notes"):
                print(f"           {r['notes']}")

    labelled = [r for r in results if r["label"] in ("hit", "no_swing")]
    fp = [r for r in labelled if r["verdict"] == "FALSE POSITIVE"]
    fn = [r for r in labelled if r["verdict"] == "FALSE NEGATIVE"]
    hitter = [r for r in labelled if r["label_source"] == "hitter"]
    print(f"\n{len(labelled) - len(fp) - len(fn)}/{len(labelled)} labelled clips correct"
          f"   false positives {len(fp)}   false negatives {len(fn)}")
    print(f"{len(results) - len(labelled)} unlabelled; "
          f"{len(hitter)} of the {len(labelled)} labels came from the hitter, "
          f"the rest are inferred and are only as good as the inference.")
    hits = [r for r in labelled if r["label"] == "hit" and r["label_source"] == "hitter"]
    if not hits:
        print("\nNOTE: no clip here is a hitter-confirmed HIT. Every gate this "
              "harness scores is a way of saying 'no', and it is being scored "
              "only against clips whose right answer is 'no'. False negatives "
              "are invisible until that changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
