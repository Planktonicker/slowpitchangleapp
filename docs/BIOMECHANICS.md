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

## Shipped now: sagittal body metrics

The pose model was already running as the hitter gate — `HumanPresenceGate`
asked it "is anybody there?" and threw the joints away. It now keeps them.

**Live:** the skeleton is drawn over the preview during setup, in the app's
yellow, from exactly the joints the metrics use. That makes the overlay the
diagnostic as well as the reassurance: if a stride number looks wrong, the ankle
in the picture is where to look. It is drawn only during setup — the question
"is the detector seeing this hitter, in this light?" is what setup exists to
answer, and a skeleton over a live swing you are watching is the last thing
wanted.

**Recorded:** `ClipAnalyzer` runs a third pass over each clip at ~60 Hz (a swing
is ~180 ms, so that is ~11 samples across it; 240 Hz would cost four times as
much for no more information) and stores the track beside the ball track.
`BodyAnalyzer` then measures, between a load frame 0.25 s before contact and
contact itself:

| Metric | What it is |
|---|---|
| Stride | horizontal travel of the front ankle, unsigned |
| Head movement | straight-line drift of nose (or neck) |
| Weight shift | drift of the hip centre |
| Front knee | interior hip–knee–ankle angle at contact; 180° is straight |
| Spine tilt | lean of the hip-to-shoulder line from vertical, magnitude |

Distances use the ball's own metres-per-pixel, so body and ball distances mean
the same thing and are wrong in the same way if the scale is wrong — far better
than being wrong independently. The pose track goes through the same tilt
rectification as the flight.

Which leg is the front leg comes from the ball's horizontal velocity: the hitter
strides toward the pitcher and the ball leaves that way, so a left-handed hitter
is handled without being asked.

Three rules the code enforces rather than documents:

- A joint below `JOINT_CONFIDENCE_MIN` is **absent**, not a guess. Apple's model
  reports low-confidence joints at plausible-looking positions.
- A hip or shoulder *centre* needs **both** sides. From a side view the near and
  far joints of a pair sit at noticeably different image positions, so falling
  back to whichever was visible would move the centre half a body width between
  frames and read as weight shift that never happened.
- A head-movement reading over `HEAD_DRIFT_IMPLAUSIBLE_M` is **withheld**. Past
  that it is the model jumping the joint to another person, and the hitter has
  no way to tell that apart from their own swing.

Coverage — the fraction of load-to-contact frames in which the hitter was found
— is shown whenever it drops below 80%, because these numbers resting on three
frames and on thirty are different claims.

Reference math is in `sla_common.py` (`sagittal_angle_deg`, `spine_tilt_deg`,
`planar_distance_m`, `stride_length_m`, `head_drift_plausible`), pinned by
`ParityTests.testBodyGeometryMatchesReference`.

### Still not measured, deliberately

Not "not yet" — **not from this camera**:

- **Hip–shoulder separation / X-factor / kinematic sequence.** Axial rotation,
  viewed nearly edge-on from the side. See the boundary rule above.
- **Torque.** Joint torque comes from inverse dynamics: segment masses, segment
  inertias and ground reaction forces. A camera measures none of the three. No
  amount of pose quality turns video into a torque measurement, and a number
  presented as one would be invented outright.

The swing-detail screen says this on the screen, not only here. Every competitor
shows rotation numbers, so a user who does not see them will assume they were
forgotten rather than withheld.

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
