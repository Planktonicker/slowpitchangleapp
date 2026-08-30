# SwingLab — working notes for Claude

Read this before changing anything. It is the short version of decisions that
have already been made and paid for; re-deriving them costs a field trip.

## What this is

A native Swift/SwiftUI iPhone app that measures slow-pitch softball **launch
angle**, **exit velocity**, **bat metrics** and **sagittal-plane body metrics**
from one tripod-mounted phone filming side-on at 240fps. Everything stays on the
device. AGPL-3.0-only; every source file carries an SPDX header.

## The rule that governs everything

**`spike/sla_common.py` is the single source of truth for measurement.** The
Swift in `app/Sources/Core/` is a port of it, pinned number-for-number by
`app/Tests/ParityTests.swift` against `app/Tests/Fixtures/parity.json`.

To change any measurement:

1. Edit `spike/sla_common.py`.
2. `cd spike && python gen_parity_fixtures.py`
3. Mirror into Swift.
4. Run the tests. Parity must never go red.

Never "improve" a number in Swift alone. If a value exists in both places and
they drift, the tests are the only thing that will notice, and only if the value
is in the fixtures — so add it there too.

Two enums look similar and are deliberately separate: `SwingFlag` mirrors the
Python's flag strings and is parity-pinned; `CaptureFlag` is app-only, for
conditions the Python cannot know about (tripod level, dropped frames, imported
clips). Adding an app-only flag to `SwingFlag` breaks `testFixturesCoverEveryFlag`.

## The honest-measurement rule

`docs/BIOMECHANICS.md` is the referee. The short version:

- A side-on camera measures the **sagittal plane** well: stride, head movement,
  weight shift, knee flexion, spine tilt.
- It measures **axial rotation** badly — hip-shoulder separation, X-factor,
  kinematic sequence are viewed nearly edge-on. **Not reported at any
  confidence.**
- **Torque is not measurable at all.** It needs segment masses, inertias and
  ground reaction forces. No camera has any of them.

A number that cannot be stood behind gets **flagged, or withheld** — never
quietly shown looking like every other number. There are no published slow-pitch
swing-kinematics norms, so nothing is scored against a population band; feedback
is against the hitter's own history.

## Build and run

```
cd app && xcodegen generate && open SwingLab.xcodeproj
```

`.xcodeproj` is generated and gitignored — regenerating it is routine, not
destructive. Re-run `xcodegen generate` when files are added or removed or
`project.yml` changes; plain edits to existing files need only a rebuild.

Tests: ⌘U in Xcode, or

```
xcodebuild test -project app/SwingLab.xcodeproj -scheme SwingLab \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

Python side:

```
cd spike
python synth_test.py           # end-to-end self-test of the measurement core
python gen_parity_fixtures.py  # after any sla_common.py change
python audio_lab.py --selftest # trigger-feature tool, proves itself first
```

## State of play

**Nothing is validated against real footage.** `docs/VALIDATION.md` has never
been filled in. The app compiles and runs on a phone; it has not yet
successfully measured a real swing. Do not describe any output as accurate.

Open, in rough priority order:

1. **Ball detection has found the ball on two real clips, and nothing more
   than that has been checked.** Both were gated by frame differencing
   (`MotionMask` / `motion_mask`) and the selected chain followed the ball at
   straightness 1.00 over 18 and 24 frames; the launch angles were not
   independently measured, so they are unvalidated. Colour alone had produced
   ~130 candidates per frame and ~1000 candidate chains — sunlit grass and
   foliage are the ball's colour, and the tree canopy yields round ball-sized
   blobs parked at the same pixel all clip. Import a clip (Swings → import →
   **From Photos**) and read the diagnostics report; it names the stage that
   failed. That report, or full-resolution frames exported from the same
   screen, is what any tuning should be based on — not guesses.
2. Pose tracking on real footage is unproven. The diagnostics report per-joint
   confidence, which is the evidence.
3. Trigger thresholds are per-venue; Settings → Trigger → Calibrate measures one.

## Gotchas that have already cost time

- **The batter outline cannot tell you where the phone is.** It constrains two
  things — how tall the hitter is in frame and where their feet land — against
  three unknowns: distance, tilt and lens height. Distance sets the size, tilt
  slides the picture up or down, so *every* lens height has a distance and a
  tilt that match the outline exactly, including a phone lying in the grass.
  The first real clip was filmed that way, from a guide glowing confident
  yellow. `CameraPose` closes the system: tilt from the IMU, distance from the
  ball tap, feet from the live pose, and the height falls out. Any new framing
  aid has to be checked the same way — count the constraints against the
  unknowns before trusting it.

- **One `AVCaptureVideoPreviewLayer` in the whole app.** Two sharing a session
  fight over the preview connection and leave the screen permanently black.
  Setup is an overlay over the existing preview, not a sheet with its own.
- **Never touch `layer.session` on the main thread.** It blocks for seconds
  against a running 240fps session. `CaptureController.attachPreview` does it on
  `sessionQueue` with an explicit connection.
- **The capture session holds the hardware video decoder.** Anything that
  decodes a file must stop the camera first and wait for it (`quiesce()`), or
  `AVAssetReader` fails with "Operation Interrupted" after zero frames.
- **iPhone slow motion is a 240fps original plus a slow-motion edit.** Every
  ordinary export path renders the edit to 30fps. Only `PHAssetResource`'s
  `.video` resource gives the original — hence `PhotoClipPicker`.
- **Vision reports normalized points on the *oriented* image, origin
  bottom-left.** Mapping them back to buffer pixels goes through
  `VisionGeometry`, which is unit-tested per orientation. Assuming `.up` silently
  puts everything in the wrong half of a sideways frame.
- **`AppModel` deliberately does not republish `capture`/`wizard` changes.**
  Doing so invalidates every view in the app twenty times a second. Views that
  need live camera or placement state hold them as `@ObservedObject` directly.
- **Ball colour is not a discriminator outdoors.** The HSV window that finds
  optic yellow also passes about 5% of a sunlit grass frame. Every heuristic
  tried on top of the colour mask — longest track, fastest track, straightest
  track — picked scenery. What actually separates the ball is that it *moves*:
  the motion gate is now load-bearing, not an optimisation. It is applied
  after the morphology, exactly where `detect_ball_candidates` applies its
  `fg_mask`; gating the colour loop instead is cheaper but opens and closes an
  already-cut blob, which changes the measured diameter, which is a scale.
- **The build is `-O` in Debug too.** The detector walks two million pixels a
  frame; `-Onone` makes analysis take minutes instead of seconds.
- `AVAssetImageGenerator` defaults to **half a second** of seek tolerance — 120
  frames at 240fps. Always set both tolerances to `.zero`.

## Style

Match the surrounding code. Comments explain **why**, especially why an obvious
alternative was rejected; the code already says what. Commit messages are
written to be read later by someone who was not here.
