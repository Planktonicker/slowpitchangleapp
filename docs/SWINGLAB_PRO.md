# SwingLab Pro — two phones, one swing, honest 3D

How SwingLab grows a multi-phone mode — two tripod iPhones filming the same
swing from different angles, triangulated into 3D — **without** breaking the
app that already works or the honesty rules that govern it. This file is the
referee for the Pro work the way `BIOMECHANICS.md` is for biomechanics and
`spike/sla_common.py` is for the physics.

> [!WARNING]
> Nothing here is validated on real two-phone footage. Every number below is a
> design target taken from published validations of comparable systems, or from
> this repo's own synthetic simulations (`spike/synth_multiview.py`). Until the
> `VALIDATION_PRO` ladder is green, no Pro output is a measurement.

## Why Pro exists

`BIOMECHANICS.md` withholds hip–shoulder separation, X-factor and the
kinematic sequence because one side-on camera views axial rotation edge-on,
and names the only honest fix: *"Two-phone mode (v2) — the only honest path to
true kinematic sequence and hip-shoulder separation: a second phone at
~45–90°."* Pro is that mode. It exists to deliver three things:

1. **Rotation metrics** — pelvis and thorax azimuth, and their difference
   (hip–shoulder separation), the numbers every competitor shows and SwingLab
   refuses to fake. They ship **labelled experimental and gated** until
   validated, exactly as BIOMECHANICS.md requires.
2. **An orbitable 3D replay** — the reconstructed skeleton, bat and ball,
   scrubbed and rotated. Joints the cameras could not both see are absent in
   the replay, not guessed.
3. **A cross-check on the 2D metrics** — each phone still runs the full
   single-camera pipeline, so every Pro swing carries two independent
   sagittal-plane measurements plus a 3D one, and disagreement is evidence.

## What Pro will never ship

- **Joint axial rotation** (hip or shoulder internal/external rotation).
  Every published markerless system measures it at 12–29° RMSE — worse than
  the signal. *Segment* rotation (whole pelvis, whole thorax) validates at
  4–6° in good systems and is what hip–shoulder separation actually needs;
  that distinction is load-bearing and the reason Pro's headline metric is
  defensible at all.
- **Ball spin.** Rapsodo needs a marked ball at 240fps to read spin; a
  softball's seams under a 4 ms shutter will not resolve it.
- **Torque.** Unchanged from `BIOMECHANICS.md`: inverse dynamics needs segment
  masses, segment inertias and ground-reaction forces. Two cameras measure
  none of the three. No camera count fixes this.

## How Pro stays separate until it has earned a merge

Pro is a **second app target in the same tree**, not a fork:

- `app/project.yml` gains a `SwingLabPro` target: the whole shared `Sources/`
  (minus the `@main` file), plus `app/SourcesPro/` for Pro-only code, its own
  bundle id and its own generated Info.plist. The `SwingLab` target stanza is
  untouched, so the shipping app cannot be disturbed by construction.
- Pro's **Solo mode is the entire existing app** — same views, same pipeline,
  same store protocol — running under the Pro bundle id. That is deliberate:
  it proves the shared tree daily, and it means a Pro phone at a field with a
  dead second phone is still a complete SwingLab.
- Swift ports of the 3D math live in `app/SourcesPro/Core3D/`, compiled only
  into Pro, pinned by their own fixtures (`app/TestsPro/`, arriving with the
  first port). `app/Tests/Fixtures/parity.json` is never touched: it is
  decoded by a non-optional struct in the shipping test target, so extending
  it would drag the 3D port into the shipping app.

## The second reference module

`spike/sla_multiview.py` is the source of truth for everything 3D, under the
same law as `sla_common.py`: reference math in Python first, fixtures
generated (`spike/gen_parity_multiview.py` → `app/TestsPro/Fixtures/
parity_multiview.json`), Swift pinned number-for-number. It is a second file
rather than an extension of `sla_common.py` only because of the fixture
mechanics above — the discipline is identical, and it imports every shared
constant from `sla_common` rather than restating one. Symbols are tagged
`[PARITY]` (destined for the Swift port) or `[SPIKE]` (Python tooling, never
ported).

Flags follow the established three-way split:

| Kind | Lives in | Examples |
|---|---|---|
| `SwingFlag` | `sla_common.py`, parity-pinned | unchanged |
| `CaptureFlag` | app-only, per-clip conditions | unchanged |
| **3D measurement flags** | `sla_multiview.py`, parity-pinned | `LOW_COVERAGE_3D`, `ONE_VIEW_ONLY`, `HIGH_REPROJECTION`, `RESAMPLE_GAP` |
| **Pro conditions** | `SourcesPro` app-only (`ProCaptureFlag`) | `syncDegraded`, `peerLost`, `calibrationStale`, `rigMoved`, `tooDarkForShutter`, `clipMissingOneView` |

Thresholds that both sides must agree on (`SYNC_DEGRADED_S`,
`REPROJ_RMS_MAX_PX`, …) are reference constants in `sla_multiview.py`, the
way trigger thresholds live in `sla_common.py`.

## Synchronization — the design decision everything else leans on

At 240fps a frame is 4.17 ms. One frame of timing error moves a 30 m/s bat
head 12.5 cm — several times the error budget of everything else combined.
And the failure mode is silent: badly-synced views triangulate into smooth,
plausible, *wrong* 3D. So sync is designed in layers, and its quality is an
always-on output, never a hidden internal.

1. **A shared clock, not shared shutters.** iPhones cannot phase-lock their
   camera sensors to each other (genlock arrived with iPhone 17 Pro and needs
   external hardware — noted, ignored). Instead the phones agree on *time*:
   NTP-style ping exchanges over the peer link, keeping only minimum-RTT
   samples (MultipeerConnectivity's median round trip is ~4 ms but its tail
   reaches hundreds — the tail is discarded, not averaged), then a robust
   offset + skew fit. Published equivalents on commodity phones reach
   250–300 µs; plain NTP over Wi-Fi measures ~0.8 ms RMSE. Budget: **≤1 ms**.
2. **Timestamps that mean something.** Every frame is stamped with its PTS on
   `AVCaptureSession.synchronizationClock`, converted to host time with
   `CMSyncConvertTime` — never the container's claimed frame rate, which lies
   (the app already measures true fps from sample timestamps; Pro keeps that
   habit and adds *whose clock*).
3. **Resample, never frame-align.** The two sensors free-run, so their frames
   interleave with a uniformly random ±2.1 ms phase. No pairing of "frame k
   with frame k" fixes that. Instead each camera's 2D tracks (joints, bat,
   ball) are resampled onto one common timeline with a monotone cubic
   (`pchip_resample`) *before* triangulation. Whole-frame alignment as used
   by OpenCap and Pose2Sim at 60fps is not good enough here.
4. **Rolling shutter folds into the same step.** Sensor readout at 1080p240
   is ~4 ms — essentially the whole frame period — so the bottom of the frame
   is a frame older than the top. Two cameras seeing the bat at different
   image rows disagree by up to ~2.2 ms ≈ 5–9 cm. Each observation's
   timestamp therefore gets `+ (row / height) · T_readout` before resampling.
   `T_readout` is measured once per device model with an LED bench, not
   assumed.
5. **The bat crack is a free sync beacon.** Both phones already timestamp the
   contact impulse to sub-buffer precision (`ContactTrigger`), and
   `contactTimeFromAudio` already corrects the sound's travel time using each
   camera's solved distance. The network clock and the corrected audio clock
   must agree; their disagreement is the sync-quality number shown to the
   user. Audio alone (1–3 ms after correction) is also the fallback when the
   link drops. Never use it uncorrected: phones at different distances hear
   the same crack ~2.9 ms apart per metre of path difference.
6. **Drift is re-measured, not trusted.** Phone clocks drift ~1 ms/min
   relative to each other, so the offset is re-estimated around every swing —
   each ping burst is cheap, and a swing capture is seconds long.

## Calibration — the ball is the wand

Each session the phones must learn exactly where they stand. The ritual
(~90 s, no props beyond what a softball player is already holding):

1. **Anchor.** Both phones run the existing setup solve on the same resting
   ball: IMU tilt, ball-tap distance (the 9.702 cm ball is the shared metric
   scale), feet-derived lens height. Gravity gives each camera two of its
   three rotation axes; the shared ball gives range. After this, exactly one
   degree of freedom is missing: the cameras' **relative bearing**.
2. **Wand pass.** One person carries or tosses the ball through the hitting
   volume for ~15 s while both phones track it. A single moving point seen
   from two places, resampled onto the shared clock, pins the relative
   bearing and lets a bundle adjustment refine every camera parameter at
   once. (This is the calibration-wand idea from the animal-mocap literature;
   the wand we already own is round, optic yellow, and has a sub-pixel
   detector written for it.)
3. **Self-check, or refusal.** Calibration reports its reprojection RMS and
   re-measures known geometry — home plate is 43.2 cm across, the resting
   ball is 9.7 cm. Out of tolerance (`REPROJ_RMS_MAX_PX`, `SCALE_CHECK_TOL`)
   means **no 3D metrics**, said plainly, not a quietly worse number.
4. **Drift watch.** Two cameras have zero redundancy to notice their own
   miscalibration, so the rig re-checks a static reference (the resting ball
   before each pitch) between swings; a bumped tripod raises `rigMoved` and
   gates 3D until the wand pass is repeated.

Intrinsics are not solved in the field: focal length per (iPhone model, lens,
video mode) is stable, so Pro ships a lookup table seeded from
`TiltRectifier.focalPx` and refined on the bench — keyed by video mode,
because 1080p240 crops the sensor differently than 4K30. A printed ChArUco
board remains the indoor/cage fallback, not the default: it is a prop users
do not own, and on a wide outdoor baseline a flat board is rarely visible
well from both cameras at once.

Camera placement inherits `CAPTURE_PROTOCOL.md` for phone A (side-on,
perpendicular, 4.5–6 m) and adds phone B at **60–110° of separation, 90°
ideal** — and *not downrange*: the second phone goes on the side the ball
flies away from, never the side it flies toward.

## Accuracy targets (the honest-claims contract)

From published validations (OpenCap, Pose2Sim, Theia3D vs marker-based;
KinaTrax and Hawk-Eye in stadiums) scaled to a 2-camera consumer rig, and to
be confirmed by `spike/synth_multiview.py --sweep` and the validation ladder:

| Quantity | 2 phones | 3 phones | Ships as |
|---|---|---|---|
| Joint centres (3D) | 30–60 mm | 25–45 mm | replay + internal |
| Sagittal joint angles | 4–8° RMSE | 3–6° | cross-check vs 2D |
| Pelvis / thorax azimuth (each) | 6–10° RMSE | 4–7° | experimental |
| **Hip–shoulder separation** | **7–12° RMSE** | 5–8° | **experimental, gated** |
| Bat head speed | ±3–5 mph | ±2–4 | experimental |
| Exit velocity (3D) | ±2–3 mph | ±1.5–2.5 | cross-check vs 2D |
| Launch angle (3D) | ±2–3° | ±1.5–2° | cross-check vs 2D |
| Joint IR/ER, spin, torque | — | — | **never** |

Context for the headline row: hip–shoulder separation in ball sports spans
roughly 30–60°, so 7–12° of error is useful for coaching direction and
within-athlete trends and marginal for fine session-to-session deltas. The
ceiling is the 2D pose estimator (3–8 px of keypoint noise ≈ 20–60 mm at
6 m), not the triangulation — which is why a bat/softball-tuned keypoint
model would move these numbers more than any geometry work.

**The ship test is Glazier's criterion, not "close to a lab":** a metric
graduates from experimental only when its measurement error is smaller than
the athlete's own swing-to-swing variability — and both numbers are shown.
With no published slow-pitch norms (still true), feedback stays
within-athlete, never against an invented population band.

Two cameras also carry a structural weakness no tuning removes: the trail
hip and shoulder are occluded by the torso through part of the swing —
sometimes exactly at peak separation. Those samples are **absent, not
interpolated**, per-joint coverage is reported, and a third phone (which
makes outlier rejection possible at all) is the recorded upgrade path.

## Linked live capture — roles and wire protocol

One phone is **master** (the operator's: arms, triggers, gathers,
calibrates, reconstructs, shows results); the rest are **workers** (capture
and report). Same app, role chosen at session start. Transport is
MultipeerConnectivity (peer-to-peer, `.required` encryption, works with no
internet), service type `swinglab-pro`. Control messages are JSON with a
`protoMajor` that refuses mismatched peers.

| Message | Direction | Notes |
|---|---|---|
| `hello` / `caps` | both / worker→master | identity, formats with *exact* frame durations, intrinsics entry, `T_readout` |
| `adoptFormat` | master→worker | chosen format + exposure policy |
| `clockPing`/`Pong` | both, unreliable | ~150 per burst; bursts at start, each arm, each swing |
| `calibAnchor` / `calibObservation` / `calibResult` | worker↔master | the ritual, §above |
| `arm` / `trigger` | master→worker | trigger carries the master-clock contact estimate |
| `swingMeta` / `swingPayload` | worker→master | per-view track CSV + pose JSON + audio impulse + diagnostics — **~100–300 KB** |
| clip transfer | on demand only | 17–18 MB via `sendResource`, for replay/export |
| `stateUpdate` | worker→master, ≤10 Hz | battery/thermal/fps/armed — feeds per-peer HUD tiles |
| `degrade` / `bye` | both | `ProCaptureFlag` values; clean teardown |

The wire carries **analysis, not video** — that is the architectural
constraint that makes a no-internet field workable, and it is why each phone
analyzes its own clip (each also quiesces its own capture session first;
every single-phone gotcha applies per phone).

Degradation ladder, never silent: peer lost → master keeps capturing solo,
swings flagged `clipMissingOneView` / `ONE_VIEW_ONLY`; sync worse than
`SYNC_DEGRADED_S` → 3D gated, 2D untouched; `rigMoved` / stale calibration →
3D withheld until the wand pass is redone.

Storage: each phone keeps its normal solo history. The master additionally
writes a `Swing3DRecord` JSON sidecar per swing (rig snapshot, per-view
artifact refs with device ids, sync report, 3D metrics + flags) — schema
will churn, so it stays JSON behind a small storing protocol until it earns
a database. Per-view track CSVs carry `# device_id=` / `# rig_id=` /
`# clock_offset_s=` meta lines; the CSV format already allows arbitrary keys.

## Roadmap and gates

Cheap gates first; a failed gate stops the spending. P0 ships with this
document.

- **P0 — Synthetic proof (done with this doc).** `spike/sla_multiview.py` +
  `spike/synth_multiview.py`: a known 3D swing projected through two modelled
  cameras (rolling shutter, clock error, noise, occlusion), reconstructed by
  the reference pipeline, checked against truth and against hand-derived
  geometry; `--sweep` writes the error budget
  (`spike/out/multiview_budget.csv`) that justifies every number above.
  **Gate: self-test ALL PASS.**
- **P1 — Sync bench.** `SourcesPro/Link/` (session, clock sync), a bench
  screen showing live offset/skew/confidence, the two-phone clap test
  (network model vs corrected audio), CSV export; `spike/sync_bench.py` to
  analyze; first Swift ports (`fit_clock_model`, `pchip_resample`) with the
  `SwingLabProTests` target and `parity_multiview.json`. **Gate: clap
  disagreement median ≤1.5 ms, p95 ≤3 ms over 10 min at field distances;
  re-lock ≤5 s after a forced link drop.**
- **P2 — Calibration.** Rig solvers in the reference module
  (`solve_relative_azimuth`, `bundle_adjust_rig`, `rig_drift_check`) with
  synthetic recovery checks (azimuth ≤0.3°, position ≤2 cm); the ritual UI;
  `calib*` messages live. **Gate (field): reprojection RMS ≤3 px, plate
  width within 5%, ritual repeats within 0.5° azimuth, a deliberate 2°
  tripod nudge caught on the next swing.**
- **P3 — Reconstruction core.** Skeleton regularization (temporal +
  limb-length constraints), full 3D metrics, complete `Core3D` port with an
  end-to-end golden fixture; offline validation against the Driveline
  OpenBiomechanics multi-camera data (CC BY-NC-SA, local only, never
  committed). **Gate: parity green; OBM hip–shoulder RMSE ≤12°, joints
  ≤60 mm median; 3D EV/LA vs the shipping 2D pipeline within ±2 mph / ±2°.**
- **P4 — Linked live session.** Pairing, arm, trigger, gather, per-peer HUD
  (under the no-republish rule), Pro swing records; `CaptureController`
  gains its default-off exposure policy and explicit-clock helper. **Gate
  (field, 20 swings): ≥90% complete two-view payloads within 10 s of
  contact; sync ≤1.5 ms on ≥90%; per-phone dropped frames no worse than
  solo; the entire SwingLab test suite green; Pro Solo behaviorally
  identical to SwingLab.**
- **P5 — 3D metrics, replay, validation.** Rotation metrics surfaced
  experimental + gated; SceneKit replay; the 2D cross-check panel;
  `docs/VALIDATION_PRO.md` filled: static props (plate/tee vs tape ≤2 cm) →
  sync gate at the venue → tossed-ball 3D gravity within 3% of 9.80665 (the
  scale-free 3D drop test) → per-phone independent EV within 8% → five-swing
  repeatability with the Glazier rule (**hip–shoulder separation graduates
  only when its error ≤ 0.5× the athlete's swing-to-swing SD**).

## Capture changes Pro needs (and Solo must not feel)

- **Exposure**: at 240fps the default shutter is the full 4.17 ms — a 40 m/s
  ball smears ~17 cm, hopeless for a sub-pixel edge. Pro locks frame duration
  *and* caps exposure (~1/1000–1/2000 s in daylight, ISO capped), and refuses
  to measure when the light cannot support it (`tooDarkForShutter`) — the
  same phones that silently sag to 160–220 fps in dim light are the reason.
  Implemented as a default-off policy on the shared `CaptureController`; the
  solo path keeps today's behavior bit-for-bit.
- **Clocks**: one helper converts capture PTS to host time explicitly; every
  cross-device timestamp routes through it.

## Licensing notes

- SwingLab is AGPL-3.0-only; a networked mode is exactly what the AGPL's
  network clause contemplates, and everything here stays under it.
- OpenCap is Apache-2.0 (ideas reused, product is 60fps and cloud-only);
  Pose2Sim is BSD-3; aniposelib is BSD-2 and fine to use inside `spike/`
  experiments. Nothing copyleft-incompatible is linked into the app.
- The Driveline OpenBiomechanics data is CC BY-NC-SA 4.0 with an explicit
  exclusion for professional-org employees: it is used only as a local,
  offline correctness check and is never redistributed or committed.

## Rules for extending Pro

1. Reference math goes in `spike/sla_multiview.py` first, fixtures via
   `spike/gen_parity_multiview.py`, Swift pinned by `ParityMultiviewTests`.
   Same discipline as the ball physics; `sla_common.py` and `parity.json`
   are never touched by 3D work.
2. Every new 3D flag needs a fixture case that provokes it, and flag order
   is pinned.
3. A number the rig cannot stand behind is flagged or withheld — sync
   degradation, stale calibration and occlusion all *gate* metrics, they do
   not soften them silently.
4. Count constraints against unknowns before trusting any new solve — the
   lesson `CameraPose.swift` already paid for.
5. Prefer within-athlete change over absolute thresholds; show measurement
   error next to swing-to-swing variability wherever a rotation metric
   appears.
