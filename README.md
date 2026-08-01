# SwingLab — slow-pitch softball swing tracker

An iPhone app (native Swift/SwiftUI) that measures, from a single tripod-mounted
phone filming side-on at 240fps:

- **Launch angle** — vertical angle of the ball leaving the bat
- **Exit velocity** — ball speed off the bat
- **Bat attack angle** — barrel path angle through contact, drawn over the replay

All data stays **on the device** (no accounts, no cloud). Camera placement is
wizard-guided (bubble level, AR distance readout, home-plate scale check) so
readings are consistent session to session.

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
| 0 | Validation spike: prove the measurement core on real footage (Python/OpenCV, no app yet) | **← you are here** |
| 1 | Capture app: guided placement wizard + auto-triggered 240fps clip capture | gated on Phase 0 |
| 2 | On-device analysis, local storage, trends, CSV export | |
| 3 | Bat attack angle + replay overlay, TestFlight | |

## Quickstart (Phase 0)

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
   go/no-go call. Phase 1 app code starts only after outdoor tee passes.

## Repo layout

```
docs/       MAC_SETUP, CAPTURE_PROTOCOL, VALIDATION (+ SETUP_GUIDE, TESTFLIGHT later)
spike/      Python reference implementation + field-validation scripts
  sla_common.py   ← single source of truth for all tracking/physics math;
                    the Phase 2 Swift port must match it number-for-number
app/        (from Phase 1) XcodeGen project.yml + Swift sources
```

Conventions: video files and live databases are never committed (see
`.gitignore`); the `.xcodeproj` is generated on your Mac by XcodeGen, not
checked in; `spike/out/` holds all script outputs and is disposable.
