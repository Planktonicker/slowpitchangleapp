# SwingLab for Android — the port plan

The owner replaced the iPhone with a Galaxy S21+ (Singapore model, Exynos 2100,
SM-G996B) and asked for the whole app on it. This is the record of how that is
being done and what is still unknown. Read `CLAUDE.md` first; every rule in it
applies here too.

## The decision

- **A port, not a recompile.** The iOS app is written against AVFoundation,
  Vision, Photos and SwiftData. None of those exist on Android, so everything
  above the measurement maths is rewritten.
- **Full parity** with the iOS app is the target (live capture, trigger, setup,
  pose, rounds, export), not an import-only viewer.
- **`spike/sla_common.py` stays the single source of truth.** The Kotlin in
  `android/core` is a port of it, pinned number-for-number by the *same*
  `app/Tests/Fixtures/parity.json` the Swift tests read — the file is read in
  place, never copied.
- **The iOS app is frozen at `8c87828`** (owner's decision). It stays in the repository and
  keeps building against a snapshot of the reference numbers taken at the
  freeze, but receives no further measurement changes — so a measurement change
  costs two edits, Python and Kotlin, not three. The Swift stays useful as the
  working specification for every screen and edge case the port must match.

## Layout

```
android/
  core/   plain Kotlin on the JVM, no Android imports — the measurement port
          and its parity tests. `gradle :core:test` runs in seconds anywhere.
  app/    the Android app (Jetpack Compose). Depends on core.
  keystore/  the committed development signing key, and why it is committed.
```

Build here: `cd android && gradle :core:test :app:assembleDebug` (the Android
SDK lives in `/opt/android-sdk` in the cloud container). CI:
`.github/workflows/android.yml` runs the same, and on every push to `main`
replaces `SwingLab.apk` on the `android-latest` release, which is the page the
phone installs from.

## What maps to what

| iOS | Android | Why it is not a one-for-one swap |
|---|---|---|
| `AVCaptureSession` at 1080p240 | Camera2 constrained high-speed session (or CameraX 1.5's high-speed API on top of it) | A high-speed session accepts only a preview surface and an encoder surface. Frames cannot also be read on the CPU at 240 Hz, so anything live must work from the encoder's output or from a separate low-rate stream. |
| `VideoEncoder` + `SampleRing` pre-roll | `MediaCodec` encoder feeding a ring of encoded samples, muxed with `MediaMuxer` on trigger | Same idea as the iOS ring: keep compressed frames, not raw ones. |
| `ContactTrigger` (AVAudioEngine tap) | `AudioRecord` + the same DSP from `core` | The DSP is pure and is ported into core; only the microphone plumbing is new. |
| `AVAssetReader` decode in `ClipAnalyzer` | `MediaExtractor` + `MediaCodec` to YUV, converted into core's `PixelImage` | Frame timing is measured from the file, exactly as on iOS — never trusted from the container. |
| `VNDetectHumanBodyPoseRequest` | ML Kit Pose Detection (or MediaPipe Pose) | A different model with different joints and confidence semantics. Every body number and `HitterScale` must be re-validated, not assumed to carry over. |
| `VNDetectTrajectoriesRequest` | none | Already only a hint on iOS, and currently discarded. |
| `PHAssetResource` original of a slow-mo clip | Android photo picker + `MediaStore` | How Samsung stores a slow-motion recording is **unknown** — see device test 2. |
| CoreMotion gravity / attitude | `SensorManager` (gravity, rotation vector) | Same physics; a different axis convention to map carefully. |
| SwiftData | Room | Same model. Export before any schema change, as on iOS. |
| SwiftUI | Jetpack Compose | |

## Phases

0. **Skeleton** — done: modules, parity harness, signed APK, CI publishing.
1. **Measurement core** — the Swift `Core` and the pure parts of `Vision`,
   ported to `android/core` and pinned by parity. The tests run on this
   machine, so this part is built and checked here, not blind. **Ported: 283
   tests, every fixture block covered in full.** The detector and the trigger
   are pinned to the Python itself, which the Swift never was. Still to do:
   `ClipAnalyzer.analyze`, the orchestration that ties the stages together.
   **Meanwhile the app is a device check** (see below).
2. **Import and analyse** — pick a clip from the Gallery, measure it on the
   phone, keep a history, export bundles the corpus can ingest. The first build
   worth installing. Depends on device test 2.
3. **Live capture and trigger** — the 240fps pre-roll ring, the audio trigger,
   arming. Depends on device test 1.
4. **Setup** — level, hitter scale, sound calibration, framing guide.
5. **Everything else the iOS app has** — rounds, trends, the validation
   scoreboard, diagnostics, overlays.
6. **Field validation on the S21+** — none of the numbers is trusted until
   `docs/VALIDATION.md` has been filled in *on this phone*. A new camera is a
   new lens, a new rolling shutter and a new encoder; nothing measured on the
   iPhone transfers.

## What the S21+ has told us (device check, 2026-11-09)

From the owner's phone: Samsung SM-G996B (Exynos 2100), Android 15.

- **Test 1 — ANSWERED: YES.** A third-party app gets a constrained high-speed
  session at **1920x1080, 240fps** on camera 0 (the main lens). The 3-second
  trial delivered frames 4.167 ms apart, and `MediaRecorder` with the hardware
  H.264 encoder wrote a **true 240fps file**: 618 frames in 2.607 s, file
  timestamps at 240.0 fps, two long gaps in 600 intervals. Such a file needs
  no capture-rate tag and none was written. Live capture is buildable.
- **The camera reports most frames twice.** In that session nearly every
  frame's capture result arrived twice, sensor timestamps about 1 µs apart (621
  near-zero intervals among 631 real ones). Anything that times frames from
  capture results must collapse timestamps closer than half a millisecond, or
  time them from the encoder's output instead. The first device check did not,
  and read "295 fps" off a camera delivering 240.
- **Indoors, auto-exposure chose the whole frame period**: 4.0 ms (1/250 s) at
  ISO 2500. That is the most motion blur a 240fps frame can hold, and a lot of
  sensor noise. Whether a shorter shutter can be forced is in the camera
  capabilities report (exposure range, MANUAL_SENSOR), still to be read.
- Hardware H.264 and HEVC encoders both declare 1080p up to 476fps.
- **Test 2 is still open**: the clip inspected was the trial clip itself, not
  one filmed in Samsung's own Slow motion mode. It now matters only for
  importing clips filmed with the stock camera; the app's own capture is
  already proven.

## Device tests the port depends on

All three are buttons in the current APK's device check, each producing a
report to paste back: camera capabilities, a 3-second 240fps recording trial
timed from the sensor's own timestamps, and an inspector for a Samsung
slow-motion clip. A Samsung community report already warns that an S21 saves
a 240fps clip as a slowed-down 30fps file with no visible record of the true
rate; Android can carry it in a `com.android.capture.fps` tag, which the
inspector reads alongside the timestamps.

1. **Can a third-party app record 240fps on this phone?** Samsung has a
   history of reserving high frame rates for its own camera app. One developer
   reports the Exynos S21 exposes 240fps to other apps where the Snapdragon one
   does not; that is unconfirmed. Test: a Camera2 capability probe app from the
   Play Store, high-speed video section, main back camera.
2. **Does Samsung's Slow motion mode save a true 240fps file?** Test: film one
   swing in Slow motion and run `ffprobe` and the Python detector on the file.
   If yes, the S21+ is usable as a camera today through the Python pipeline,
   before any of the app exists.
