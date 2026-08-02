# Biomechanics & swing-feedback roadmap

How SwingLab adds swing feedback (bat metrics, then body metrics) **without**
overclaiming what a single side-on phone can measure. This file is the referee
for the biomechanics work the way `spike/sla_common.py` is the referee for the
physics: if a feature would report a number the camera geometry can't support,
it doesn't ship as a measurement.

> [!WARNING]
> Nothing here is validated on real footage yet. Everything below is design
> intent and grounded estimates, not proven accuracy. See [NOTICE](../NOTICE).

## What we learned from the market

The apps in this space split by how they capture motion:

- **b4-app** ("better baseball batting biomechanics") — single iPhone + tripod,
  **no sensors**. Measures exit velocity, launch angle, bat path, **Bat Contact
  Point** (where on the barrel the ball struck, knob-to-tip ratio), a
  **Flush Factor** contact-quality score, and side-on biomechanics it lists as
  stride, head movement and weight shift. This is the closest product to
  SwingLab and the model for what one phone can credibly do.
- **4D Motion** — 1–12 Bluetooth IMU sensors (~200 Hz) on pelvis/torso/arm/hand.
  Its headline "kinematic sequence" and "X-factor" (hip-shoulder separation)
  come from the **sensors**, not the camera. A 2023 AJSM validation (Loushin et
  al., Mayo Clinic) found even its own IMU magnitudes are not lab-equivalent.
- **Uplift Labs** — true 3D from **two** synchronized iPhones.
- **Sportsbox AI / ProPlayAI** — single video **lifted** to 3D with a trained
  motion prior (and cloud compute), not read off a raw 2D side projection.

The pattern is unambiguous: **credible rotational biomechanics needs sensors,
two cameras, or a learned 3D lift.** No product recovers the kinematic sequence
or hip-shoulder separation from one raw side-on view, and there is no published
validation that it can be done.

## The measurement boundary (the load-bearing rule)

A side-on camera looks at the **sagittal plane**. The literature is consistent:

- Sagittal-plane joint angles (knee/hip flexion, spine tilt, stride) land within
  ~2–5° of marker-based motion capture — **honest**.
- **Axial / transverse-plane rotation** — pelvis and torso turning about the
  vertical axis, i.e. hip-shoulder separation — is the **worst**-measured
  quantity in every markerless system (hip RMSD ~21°, off-axis errors 15–37°),
  and a side-on camera views it nearly edge-on, so most of the true motion is
  along the foreshortened axis. A projected 2D proxy's peak need not even occur
  at the same time as the true 3D peak.

**Consequence — hard rule:** SwingLab does **not** report hip-shoulder
separation, X-factor, or kinematic-sequence *ordering* as a measured number
from the single side-on camera. Those are deferred to a future two-phone mode.
Any such signal, if ever surfaced, must be labelled experimental and gated the
same way a low-confidence scale reading is. This mirrors the product's founding
ethos: a number you can't stand behind gets flagged, not quietly shown.

There are also no published slow-pitch adult/senior swing-kinematics norms —
every threshold in circulation is from baseball or fastpitch-female studies —
so feedback is built around **each hitter's own baseline over time**, not
comparison to a population number we'd be inventing.

## Shipped now: bat speed + smash factor

Learned from b4-app's bat-metrics pairing, and uniquely cheap for SwingLab
because it already tracks **both** the barrel tape and the ball.

- **Bat speed** — magnitude of the barrel-tape velocity at contact, converted
  with the same ball-size scale exit velocity uses. Reported "at the tape
  marker" (a disclosed bat point, like Statcast's "at the sweet spot").
- **Smash factor** — exit velocity ÷ bat speed; b4-app's "flush"/contact-quality
  idea. ~1.35+ is a well-struck ball. Exact off a tee; approximate off live
  pitching, where the ball carries its own inbound speed into the collision.

Reference math is in `spike/sla_common.py` (`bat_speed_mps`, `smash_factor`,
`smash_quality`), pinned by `ParityTests.testBatMetricsMatchReference`. It only
computes when the bat was tracked with acceptable confidence and the ball scale
is sound; otherwise it shows "—".

## Shipped now: contact offset ("undercut")

The side-view-honest half of b4-app's Bat Contact Point. At contact the bat
points nearly along the camera's optical axis, so the knob-to-tip position b4
reports is foreshortened from a side view and **not** honestly measurable here.
What the side view measures *well* is the **vertical offset between barrel
centre and ball centre** — Alan Nathan's "undercut distance", the quantity that
decides topped vs flush vs popup and sets backspin (~10–25 mm under the centre is
the carry zone).

Computed from two numbers the pipeline already fits: the tape path evaluated at
contact and the ball's position at contact (both extrapolated through the
occlusion around impact). Sign: positive = barrel under the ball. Readings
where the two centres are farther apart than the two radii (~77 mm) cannot have
been a contact — they're discarded by a plausibility gate, not displayed.
Stated caveat: the tape centroid stands in for the barrel at the contact point,
so the reading is accurate when contact happens near the tape — which is why
`CAPTURE_PROTOCOL.md` puts the tape at the sweet spot. Reference math:
`undercut_m` / `contact_quality` in `sla_common.py`, pinned by
`ParityTests.testContactOffsetMatchesReference`.

## Roadmap (in priority order)

1. **Knob-to-tip Bat Contact Point** — deferred: needs either a non-side camera
   angle or barrel-endpoint detection robust to foreshortening. The EV-vs-
   contact-spot report can proceed from undercut alone (EV vs vertical miss).
2. **Slow-pitch launch-window guidance** — colour launch angle against the
   slow-pitch line-drive band (~10–25°, distinct from MLB's 25–35°, which
   misleads slow-pitch hitters) and add a "will it clear a 90 m fence?" carry
   readout from the existing drag model. Descriptive, not prescriptive.
   (`in_slowpitch_launch_window` / `SLA.inSlowpitchLaunchWindow` already exist.)
3. **On-device 2D pose, offline on the ring-buffer clip** — the body-metrics
   engine. Run `VNDetectHumanBodyPoseRequest` (already used at ~10 Hz as the
   presence gate) over the saved clip *after* the trigger: subsample to ~30–60 Hz
   for load/stride, every frame in a ±100 ms window around the audio-detected
   contact. Never live at 240 fps — nobody does; analyze the buffer. Report only
   sagittal-honest metrics: **stride length** (in metres via the ball scale),
   **head drift**, **posture/spine angle**, **lead-knee flexion**, **launch
   quickness** (first forward hand move → contact) and **peak hand speed**.
   Smooth each joint track (One-Euro / Kalman) before differentiating, and gate
   on per-joint confidence + occlusion, same as the physics gates.
4. **Feedback UX** — deliver cues as **external-focus, prescriptive** language
   ("drive the barrel at the pitcher sooner"), never a raw joint-angle dump: the
   motor-learning evidence (Wulf, 40+ studies) shows internal-focus joint
   readouts hurt retention. Keep launch angle / exit velocity as the hero;
   biomechanics is a *pull* (tap "why was that one better?"), not a push.
5. **Two-phone mode (v2)** — the only honest path to true kinematic sequence and
   hip-shoulder separation: a second phone at ~45–90°, audio- or flash-synced.
   Single-phone stays the accessible default; two-phone is the accuracy upgrade.

## Rules for anyone extending this

- Reference math goes in `spike/sla_common.py` **first**, with parity fixtures
  regenerated (`python spike/gen_parity_fixtures.py`) and the Swift port pinned
  by `ParityTests`. Same discipline as the ball physics.
- If a metric depends on transverse-plane rotation from one camera, it is not a
  measurement — it's an experiment, and it ships (if at all) flagged and gated.
- Prefer within-athlete change and repeatability over absolute population
  thresholds until slow-pitch norms actually exist.
