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
   machine, so this part is built and checked here, not blind. **Ported: 189
   tests, every fixture block covered in full at the Swift's tolerances.**
   Still to do: `frameTiming`, `BatTracker`, the level-sensor maths with an
   Android axis adapter, and pinning the detector and the trigger to the Python
   rather than only to the Swift (see `CLAUDE.md`, State of play).
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

## Device tests the port depends on

1. **Can a third-party app record 240fps on this phone?** Samsung has a
   history of reserving high frame rates for its own camera app. One developer
   reports the Exynos S21 exposes 240fps to other apps where the Snapdragon one
   does not; that is unconfirmed. Test: a Camera2 capability probe app from the
   Play Store, high-speed video section, main back camera.
2. **Does Samsung's Slow motion mode save a true 240fps file?** Test: film one
   swing in Slow motion and run `ffprobe` and the Python detector on the file.
   If yes, the S21+ is usable as a camera today through the Python pipeline,
   before any of the app exists.
