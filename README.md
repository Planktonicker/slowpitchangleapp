# SwingLab — slow-pitch softball swing tracker

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Status: unvalidated](https://img.shields.io/badge/measurements-unvalidated-orange.svg)
![Platform: iOS 17+](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey.svg)

An iPhone app (native Swift/SwiftUI) that measures, from a single tripod-mounted
phone filming side-on at 240fps:

- **Launch angle** — vertical angle of the ball leaving the bat
- **Exit velocity** — ball speed off the bat
- **Bat attack angle** — barrel path angle through contact, drawn over the replay

All data stays **on the device** (no accounts, no cloud). Camera placement is
wizard-guided (bubble level, AR distance readout, home-plate scale check) so
readings are consistent session to session.

> [!WARNING]
> **The numbers are not validated.** SwingLab has never been run against real
> footage or a calibrated reference. The Phase 0 validation in
> [docs/VALIDATION.md](docs/VALIDATION.md) has not been carried out, and the app
> has not been compiled. Don't use its output for coaching, equipment or player
> decisions. See [NOTICE](NOTICE).

## How measurement works (and why you can trust it without a radar gun)

- The ball's flight is tracked frame-by-frame in slo-mo video; launch angle and
  exit velocity come from a trajectory fit over the first ~120 ms after contact.
- Real-world scale is estimated **two independent ways** and cross-checked on
  every swing:
  1. the ball's known size (12 in circumference → 3.82 in diameter) vs its
     apparent size in pixels, measured sub-pixel on the motion-blur-free axis;
  2. the fitted vertical acceleration vs gravity — **drag-aware**: a softball
     flies at roughly its terminal velocity (~30 m/s), so air drag is comparable
     to g and is solved for, not ignored.
  If the two scales disagree beyond tolerance, the reading is flagged
  low-confidence instead of silently reported.
- Fly balls give free ground truth: stopwatch hang time and paced-off carry
  distance must match what the drag model predicts from the measured numbers.

## Project status

| Phase | What | Status |
|-------|------|--------|
| 0 | Validation spike: measurement core proven on synthetic footage (Python/OpenCV) | core done; **not yet run on real footage** |
| 1 | Capture app: guided placement wizard + auto-triggered 240fps clip capture | built, unproven in the field |
| 2 | On-device analysis, local storage, trends, CSV export | built, unproven in the field |
| 3 | Bat attack angle + replay overlay, TestFlight | attack angle + overlay built; TestFlight not started |

The app was brought forward deliberately so that filming and validating happen
in one pass: the app records the clips **and** computes the go/no-go
scoreboard, instead of the footage making a round trip to the Mac first. The
measurement core it runs is the Phase 0 reference, ported to Swift and pinned
to it by `app/Tests/ParityTests.swift`. What remains unproven is the capture
half — real ball, real light, real cage. See [docs/APP_GUIDE.md](docs/APP_GUIDE.md).

## Quickstart — the app

```
cd app && xcodegen generate && open SwingLab.xcodeproj
```

Set your signing team, Run to your iPhone, then follow
[docs/APP_GUIDE.md](docs/APP_GUIDE.md): placement wizard, arm, hit. The
**Validation** tab computes the Phase 0 gates live from what you capture.

## Quickstart — the Python reference (the referee)

1. **Set up the Mac** — follow [docs/MAC_SETUP.md](docs/MAC_SETUP.md) §1–3
   (Python only for now; Xcode matters from Phase 1).
2. **Verify the install** (no footage needed):
   ```
   cd spike
   python3 -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt
   python synth_test.py        # must print: ALL PASS
   ```
3. **Film real swings** — follow [docs/CAPTURE_PROTOCOL.md](docs/CAPTURE_PROTOCOL.md),
   AirDrop clips into `spike/clips/`, rename by setting (`tee_01.mov`, ...).
4. **Run the pipeline**:
   ```
   python batch_run.py --fps 240             # scoreboard for G1/G2/G4
   python analyze_swing.py out/fly_01.csv --flyball --hang 4.1 --carry-ft 185
   python check_audio_trigger.py clips/tee_01.mov          # G5 (needs ffmpeg)
   python track_ball.py clips/cage_02.mov --debug-video    # eyeball a track
   ```
5. **Record results** in [docs/VALIDATION.md](docs/VALIDATION.md) and make the
   go/no-go call.

The go/no-go call still governs. The app existing does not pre-empt it: if
outdoor tee trackability (G1) fails on real footage, the answer is to rethink
capture — distance, ball, background — not to keep building on top of it.

## Repo layout

```
docs/       MAC_SETUP, CAPTURE_PROTOCOL, VALIDATION, APP_GUIDE
spike/      Python reference implementation + field-validation scripts
  sla_common.py          ← single source of truth for all tracking/physics math
  gen_parity_fixtures.py ← freezes that math into golden vectors for the port
app/        XcodeGen project.yml + Swift sources
  Sources/Core/          ← the port of sla_common.py; must match it number-for-number
  Sources/Capture/       ← 240fps capture, pre-roll ring, audio contact trigger
  Sources/Vision/        ← detection, Vision trajectory locator, bat tracking
  Sources/Wizard/        ← guided placement (level, ARKit distance, plate scale)
  Sources/Storage/       ← SwiftData behind a thin protocol + the validation scoreboard
  Tests/                 ← parity tests against spike/, plus pipeline tests
```

Conventions: video files and live databases are never committed (see
`.gitignore`); the `.xcodeproj` is generated on your Mac by XcodeGen, not
checked in; `spike/out/` holds all script outputs and is disposable.

**The Python is the referee.** If a device number and a Python number disagree
on the same clip, the Python is right until proven otherwise — and the parity
tests exist to make that disagreement impossible to reach by accident.

## License

Copyright (C) 2026 Planktonicker.

SwingLab is free software licensed under the **GNU Affero General Public
License v3.0 only** — see [LICENSE](LICENSE) for the full text, and
[NOTICE](NOTICE) for trademarks, third-party dependencies and the measurement
disclaimer.

In short: you may use, study, modify and share it, but anything you build on
it has to stay under the AGPL and ship its source — including if you only ever
offer it to people over a network (AGPL §13). That is deliberate. The
drag-aware scale solve and the sub-pixel diameter method are the hard-won parts
of this project, and the license is what keeps them open.

The license covers copyright in the software. It does not grant rights to the
SwingLab name.

Contributions are welcome under the terms in [CONTRIBUTING.md](CONTRIBUTING.md),
which asks for an extra relicensing grant so the app can still be distributed
through TestFlight and the App Store.

- [Security policy](SECURITY.md) — report vulnerabilities privately
- [Code of conduct](CODE_OF_CONDUCT.md)
