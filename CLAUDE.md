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
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Any installed iPhone simulator works; the name above is only an example, and a
retired one fails the build for a reason that has nothing to do with the code.
CI picks the newest available automatically.

**CI is the compiler of record.** `.github/workflows/ios.yml` generates the
project, builds and tests on every push, and writes the errors into the run's
job summary. Most of this app is edited from a machine with no Swift toolchain,
so that summary — not a screenshot — is how a compile error gets read.

Python side:

```
cd spike
python synth_test.py           # end-to-end self-test of the measurement core
python gen_parity_fixtures.py  # after any sla_common.py change
python audio_lab.py --selftest # trigger-feature tool, proves itself first
python replay_corpus.py --selftest  # mirrored gates + rate estimator, proves itself first
python replay_corpus.py        # re-run selection + publish gates on every saved clip
```

**Real footage lives in `spike/corpus/`, and a clip is added once.** A `.mov`
cannot be committed, but the candidate detections inside one can — all the
clips so far come to under a megabyte. `spike/corpus/README.md` has the three
ways in; the phone route is Swings → Select → Share, which produces one JSON
bundle. Run the harness before and after any change to selection or to the
publish gates: it is the only thing that will notice a fix for one clip
breaking another. It found the frame-rate bug in `ClipAnalyzer.frameTiming`
that this paragraph's neighbours describe, on four clips at once.

Labels, not clips, are the scarce resource. Only the hitter knows whether a
swing happened, so `label_source` is recorded and printed, and a label of
`inferred` is exactly as fallible as the pipeline it is being used to test.

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
4. **`TrackPlausibility.maxStartAfterContactS` is a dead gate.** It fires when
   the chosen track starts more than 0.25 s after contact, and it is skipped
   whenever `SwingFlag.contactTimeRejected` is set — which `analyze_track`
   sets at 0.06 s. Every track late enough to trip the gate has already
   disabled it. Six of the eight corpus clips replay with both contact gates
   skipped. The skip itself is right (an early trigger and a late false
   positive look identical from the contact time alone), so the fix is not to
   remove the skip; it needs a signal the contact time does not supply.

## Gotchas that have already cost time

- **The batter outline cannot tell you where the phone is.** It constrains two
  things — how tall the hitter is in frame and where their feet land — against
  three unknowns: distance, tilt and lens height. Distance sets the size, tilt
  slides the picture up or down, so *every* lens height has a distance and a
  tilt that match the outline exactly, including a phone lying in the grass.
  The first real clip was filmed that way, from a guide glowing confident
  yellow. `CameraPose` closes the system: tilt from the IMU, distance from the
  setup measurement (by default the hitter's own nose-to-ankle span —
  `HitterScale`), feet from the live pose, and the height falls out. Any new
  framing aid has to be checked the same way — count the constraints against
  the unknowns before trusting it.

- **A side-on camera cannot measure home plate's front edge.** The protocol
  camera is perpendicular to the pitch line, so the 17 in front edge points
  *at* the lens and is seen end-on: the pixels between its two corners are
  depth foreshortening, not 43 cm, and a distance derived from them is
  arbitrary rather than approximate. The 17 in that does run across the
  picture is **front edge to rear point** — hence `plateDepthM`, and hence
  where the two markers go.

- **Pinch-to-zoom on the preview is a display transform, never
  `videoZoomFactor`.** Sensor zoom is a centre crop that cannot be panned, and
  the plate sits about a third of the way in from the frame edge by protocol,
  so at 3x it leaves the picture entirely. It also changes the buffers and the
  field of view the wizard read once at configure time, which silently
  invalidates every distance on the screen doing the zooming.

- **Never put a transform on a `UIViewRepresentable`'s own view.** SwiftUI
  assigns that view's `frame` on every layout pass, and `frame` is undefined
  while `transform` is not the identity. `CameraPreview` is a plain container
  that is never transformed, wrapping an inner view whose backing layer is the
  preview layer and which carries the zoom.

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

- **"Cannot find 'X' in scope" for a type whose file is plainly on disk means
  the generated project is stale, not that the code is wrong.** Quit Xcode
  first, then `xcodegen generate`, then reopen — a running Xcode can write its
  old in-memory project back over the new one. The symptom cascades and hides
  its own cause: an enum with a payload of the missing type stops synthesising
  `Equatable`, which reads as a second, unrelated bug in a file that is fine.
  Decline "Update to recommended settings" while you are there; it edits the
  generated, gitignored `.xcodeproj`.

## Style

Match the surrounding code. Comments explain **why**, especially why an obvious
alternative was rejected; the code already says what. Commit messages are
written to be read later by someone who was not here.
