<!--
SwingLab — Copyright (C) 2026 Planktonicker
SPDX-License-Identifier: AGPL-3.0-only
Full terms in LICENSE at the repository root. No warranty.
-->

# Clip corpus

Real footage, distilled small enough to keep.

## Why this exists

Every clip so far arrived as a 20 MB `.mov` in a chat attachment, was looked at
once, and was gone by the next session. Changes to the selector were then
argued from memory of a clip nobody could re-open, and a change that fixed one
clip could silently break another with nothing to notice.

A `.mov` cannot live in the repo — it is gitignored, and rightly. But the
evidence inside one can. What an argument about selection actually needs is the
candidate detections, their timing, and what the hitter said happened. All
seven original clips together come to 700 KB. That is cheap enough to keep
forever.

So: **a clip is added once and replayed for good.**

```
cd spike
python replay_corpus.py --selftest # the mirrored gates and rate estimator, first
python replay_corpus.py            # re-run selection and the publish gates on everything
python replay_corpus.py --verbose  # + frame timing and the losing tracks
```

## Getting footage in here

Whichever you have. Every route ends in a `<id>.trace.json.gz` plus a row in
`index.json`; nothing else is kept.

**From the phone** — this is the one that costs the hitter the least:

> Swings → **Select** → tick the swings → **Share** → send the one JSON file.

That is a `swinglab_diagnostics_bundle`, and it carries the trace, the report,
the track CSV and the flags for every swing selected, in one file.

```
python replay_corpus.py --add-bundle diagnostics_5swings_20260905_143012.json
python replay_corpus.py --relabel live_61 no_swing        # then label each one
```

⚠️ The phone trims a bundle's candidates to ±0.5 s around contact, to keep the
file small. Selection outside that window cannot be replayed from a bundle, and
the harness says so per clip when it happens. A trace exported whole does not
have that limit.

**From a raw clip**, when there is no phone artefact — runs the Python
reference detector over it and distils the result:

```
python replay_corpus.py --add-clip live_61.mov --id live_61 \
    --label no_swing --label-source hitter --notes "..."
```

**From a single exported trace**:

```
python replay_corpus.py --add-trace live_61.trace.json --id live_61 --label hit
```

## Labels are the scarce resource, not clips

`label` is what actually happened, in the hitter's terms:

| label      | meaning                                     | correct behaviour |
|------------|---------------------------------------------|-------------------|
| `hit`      | bat met ball in this clip                    | a reading is published |
| `no_swing` | the trigger fired; nobody hit anything       | nothing is published |
| `unknown`  | nobody ever said                             | no verdict         |

`label_source` says who decided, and it is printed on every row because it
changes what a result is worth:

- **`hitter`** — the person who filmed it said so. Evidence.
- **`inferred`** — read off the geometry by whoever added the clip. Exactly as
  fallible as the pipeline being tested with it, and circular if used to tune
  the thing that produced the inference.
- **`none`** — unlabelled. Useful only for showing that behaviour *changed*
  between two builds, never for saying which build was right.

**As it stands there is not one hitter-confirmed `hit` in here.** Four clips are
hitter-confirmed `no_swing`; three `hit` labels are inferred; one is unknown.
Every gate this corpus scores is a way of saying "no", and it is being scored
almost entirely against clips whose right answer is "no". False negatives are
invisible until that changes — the harness prints this warning on every run
until a hitter-confirmed hit lands here.

## What is replayed, and what is not

The harness re-runs **track building, selection and the publish gates**. The
candidates are frozen at whatever build detected them, so it will catch a
selector that picks the wrong track and a gate that lets junk through, and it
will **not** notice a detector that stopped finding the ball. `--add-clip` is
the one path that exercises detection, because it re-detects from pixels.

The publish gates are read out of `app/Sources/Core/TrackPlausibility.swift` at
run time rather than restated in Python, so a threshold changed in the app
changes what this reports on the next run with nothing to remember. The run
prints where they came from.

## Frame rate is derived here, never trusted

`index.json` records `stamped_fps` — what the build at the time believed — and
the harness ignores it, deriving the rate from the frame timestamps instead.

They disagree, and it matters. `AVAssetWriter` gives a passthrough track
QuickTime's default timescale of 600, which cannot express 240 fps (2.5 ticks a
frame), so a flawless capture alternates 3333 µs and 5000 µs. The four oldest
clips here were analysed at **200 fps** because of it — every speed on them is
20% low. Replaying them found a second bug in the same estimator: its
"one frame period" tolerance was 1.5, exactly the alternation's own ratio, so
whether it worked came down to floating-point noise, and on real timestamps it
read **300 fps**. Fixed, with a test that builds its intervals the way real
ones arrive.

## Files

| file | what |
|---|---|
| `index.json` | one row per clip: label, provenance, contact time, notes |
| `<id>.trace.json.gz` | candidate detections with timestamps; the replay input |
| `<id>.selected.csv` | the track the build at the time chose — the record of what the app did then, not ground truth |

## Adding to it

Send more clips of the same swings from the same spot, especially **hits the
hitter can confirm**. Volume is not the constraint; confirmed labels are.
