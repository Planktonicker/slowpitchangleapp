# Phase 0 validation — go/no-go record

Fill this in after running the pipeline on your footage (`batch_run.py`
prints most of these numbers directly). Phase 1 app code starts only when
the decision rule at the bottom says GO.

## How to establish that the speed is right

Exit velocity is `pixels per second x metres per pixel`. The first half is
solved: presentation timestamps come out of the file and the app measures the
true frame rate from the samples rather than believing the header, which on two
real clips claimed 175 and 147 fps for footage that was actually 240. So **all
of the accuracy question is the scale**, and the scale has exactly two
independent sources:

1. **The ball's apparent diameter.** A known 3.82 in object at exactly the depth
   that matters, in every frame that matters. Needs nothing from you and works
   in every situation. Its weakness is that the ball is small — 18-22 px on a
   720p clip — so a 1 px error in the diameter is 5% on every mile per hour.
2. **Gravity.** The ball's vertical acceleration in px/s^2 against 9.81 m/s^2.
   This one is **absolute**: it does not care what size the ball is, what lens
   is on the phone, or how far away the tripod is.

When those two agree, both are right, and you have a validated speed with no
radar gun, no tape measure and no reference object. That agreement is what the
app calls the scale cross-check, and it is why a reading with
`NO_GRAVITY_CHECK` on it is weaker than one without — not because the number is
worse, but because only one of the two witnesses turned up.

### G0 — The drop test (do this first, it takes five minutes)

The cheapest and by far the sharpest calibration check available, because it
isolates the scale from everything else. A dropped ball has no launch angle to
get wrong, no contact to time, no bat, no hitter, and an acceleration that is
known to four figures.

1. Set the phone up exactly as you would to film hitting — same tripod, same
   distance, same 240fps format.
2. Stand where the hitter stands. Hold a ball at head height and **drop** it.
   Do not throw it. Let it fall past the frame.
3. Import the clip: **Swings & imports -> the download icon -> From Photos**.
4. Open the resulting record, expand **Measurement detail**, read the
   **Scale cross-check**.

Read the disagreement, not the launch angle. Expect:

| Disagreement | Meaning |
|---|---|
| under 2% | The scale is good. Every mph the app reports rests on this. |
| 2-8% | Usable, flagged. Worth re-shooting closer or at higher resolution. |
| over 8% | Something is wrong with the scale. Do not trust any speed until it is found. |

The reference recovers a known scale from a simulated drop to **0.33%**, and the
gravity check needs **0.25 s of fall (about 31 cm)** before it will report at
all — so a drop from head height clears it with a factor of four to spare.
A drop from below knee height will come back `NO_GRAVITY_CHECK` and tells you
nothing.

Expect the app to also mark the clip **"No struck ball identified"**. That is
correct and does not affect this test: a falling ball is not a swing, the
plausibility gate says so, and the two scale numbers are computed either way.

### G0 result — 2026-08-30, tee_05.mov (FAIL, and it found something)

First run of this test. Indoors, 1920x1080 at 240fps, 12-inch softball dropped
from head height in front of the camera.

The fall itself is textbook: 63 tracked points over 342 ms fitting a parabola
with a **0.55 px** residual. That is what makes the rest of this trustworthy.

| | apparent ball diameter | implied scale | vs gravity |
|---|---|---|---|
| what gravity requires | **~38 px** | ~2.55 mm/px | — |
| raw colour mask | 35.0 px | 2.771 mm/px | +9% |
| **what the app measured** | **32.8 px** | 2.958 mm/px | **+14%** |

**Verdict: the app under-measures the ball, so every exit velocity it reports
is roughly 14% too high.** The app flagged `SCALE_DISAGREE` on the clip, which
is the gate working — it refused to stand behind the reading.

Uncertainty on that 14% is a few percent, not tenths. Fitting `g` over sliding
windows gives 3525-3997 px/s^2, converging near 3950 once the ball is moving
fast enough for the quadratic term to be well conditioned; the early windows,
where it has barely started falling, are ill-posed and should be ignored. The
apparent diameter stayed 34-36 px for the whole fall, so the ball was not
moving in depth and the two scales really are measuring the same thing.

**Not acted on yet, deliberately.** One clip is not grounds for changing a
number that `ParityTests` pins and every reading depends on. What would settle
it, in order of value:

1. **A second drop, framed better.** Keep the ball nearer the middle of the
   frame and let it fall further before it leaves — the ill-conditioned early
   windows are what widen the error bar. Two clips agreeing to a couple of
   percent turns this from a finding into a correction.
2. **A drop at a different distance.** If the bias is the same percentage at
   4 m as at 2 m, it is the diameter measurement. If it changes with distance,
   it is the optics.
3. **Then, and only then, fix the mechanism** — `_subpixel_minor_diameter`,
   which reads 32.8 px where the raw mask reads 35.0 and gravity wants 38.
   Its alpha = 0.5 crossing lands inside the true silhouette. Fixing the
   measurement is right; scaling its output by a number derived from one clip
   is not.

Readings taken before this is resolved should be treated as **~14% high in
speed**. Launch angle is unaffected — it is an angle, and needs no scale.

### G0 second run — tee_06.mov: the error is SIZE-DEPENDENT

A second drop, further back, so the ball is about 26 px instead of 37. This
was shot to answer one question: is the bias the same percentage at two
distances (then it is the diameter measurement) or does it change (then it is
the optics)? It changes, and by a lot.

Measured with the app's own colour window on both clips, against gravity:

| clip | ball px (gravity) | raw colour mask | app's refined diameter | error |
|---|---|---|---|---|
| tee_05, ball 37 px | 37.00 | 35.00 (-5.4%) | 32.80 | **-11.4%** |
| tee_06, ball 26 px | 26.24 | 24.00 (-8.5%) | 14.99 | **-42.8%** |

Both falls are clean — parabola residuals of 0.55 px and 0.45 px over 342 and
442 ms — so the reference is sound in both cases.

**So `_subpixel_minor_diameter` degrades as the ball gets smaller, and no
calibration constant can fix it.** A single factor would be right at one
apparent size and wrong at every other. This is a measurement to repair, not
a number to scale. Until it is repaired:

- **Exit velocity is unreliable by an amount that depends on how big the ball
  is in frame** — roughly 10% high when it fills 37 px, far worse when it is
  small. Launch angle is unaffected; it is an angle and needs no scale.
- **Film so the ball is as large in frame as the flight allows.** This has
  moved from a nicety to a measurement requirement.

Two candidate causes were tested and **disproven**, which is worth recording so
they are not re-tried:

1. *The edge search stops at an interior dip.* It does not. Sampling the alpha
   profile across the ball on tee_06 gives a clean monotonic fall with a single
   0.5 crossing; searching outside-in returns the same radius as inside-out.
2. *The hue floor is too low, so skin is being tracked.* Skin IS being tracked
   on tee_06 — the 121-frame "flight" the app reported at 76.9 degrees is the
   hitter's leg, then shorts, then shoulder, confirmed frame by frame — but
   raising the hue floor from 18 to 20, 22 or 24 does not change it. The
   discriminator is something else.

The app's verdict on tee_06 read "measured 77 degrees, which is not a hit —
that is the ball going almost straight up. Whatever was tracked, it was not a
struck ball." That is the honest-measurement machinery working: it refused the
reading rather than reporting a swing.

- Date: 2026-08-30  Disagreement: 14% (37 px ball) / 43% (26 px ball) -> Pass? **NO**

### G0b — The two-distance check (no truth needed at all)

Film the same tee, same ball, same swing intent from **4.5 m and from 6 m**.
The reported exit velocities must agree within the same 8%. This catches a
scale error that varies with distance — which is what a wrong field of view, a
lens that switched to 0.5x, or a diameter being over-read by the compression
halo all look like — and it needs no stopwatch, no pacing and no reference
object.

- 4.5 m: ______ mph  6 m: ______ mph  difference: ______ % -> Pass? ______

### What changes about how you film

The gravity witness only appears if the ball is in frame long enough. On the
two field clips measured so far the flight lasted **79 ms and 146 ms**, and both
came back `NO_GRAVITY_CHECK` — the single most valuable framing change
available is to keep the ball in shot for **0.25 s or more**, which means
pulling back or aiming further down the line of flight. That one change turns
every swing into its own calibration check.

## G1 — Trackability

*Ball auto-tracked for ≥12 consecutive frames post-contact.*

| Setting | Threshold | Result (from batch_run) | Pass? |
|---------|-----------|-------------------------|-------|
| Tee / soft toss | ≥ 90% of clips | | |
| Field, live | ≥ 80% | | |
| Cage (camera inside) | ≥ 70% | | |
| Through net | none — expected fail | | n/a |

## G2 — Scale agreement (the no-radar accuracy check)

*Median disagreement between ball-diameter scale and drag-aware gravity scale,
outdoor clips with ≥0.25 s of tracked flight.*

- Threshold: **≤ 8%**, no systematic sign bias > 5%
- Result: ______ %  → Pass? ______
- Note whether the gravity check worked **per swing** or only as a session
  aggregate (line drives have little curvature in a short window): ______

## G3 — Fly-ball physics ground truth

*Per clip: `analyze_swing.py out/fly_NN.csv --flyball --hang T --carry-m D`.*

| Clip | Model hang vs stopwatch | Model carry vs paced | Pass (±15% / ±20%)? |
|------|-------------------------|----------------------|---------------------|
| fly_01 | | | |
| fly_02 | | | |
| fly_03 | | | |

## G4 — Repeatability

*The 5 identical-intent tee swings (`teeid_*`).*

- EV std-dev: ______ mph (≤ 3 mph) → Pass? ______
- LA std-dev: ______ ° (≤ 3°) → Pass? ______

## G5 — Audio trigger feasibility

*`check_audio_trigger.py` on ≥5 clips incl. cage.*

- Clips with contact impulse ≥ 15 dB over ambient: ____ / ____ (need ≥ 90%)

## Observations

(lighting, blur, cage flicker test result, occlusion comparison, anything odd)

-

## Decision rule

- **G0 fails → stop and fix the scale first.** Every other gate on this page
  reads through the scale, so a scale that is wrong makes G2, G3 and G4 measure
  the wrong thing while still producing numbers.
- **G1(tee) + G2 + G4 pass → GO** for Phases 1–2.
- G3 fails → proceed, but EV is labeled "relative/uncalibrated" until resolved.
- G1(cage, inside) fails → cage demoted to capture+replay only (documented
  limitation); outdoor path proceeds.
- Through-net failing is expected and is NOT a blocker — it becomes a hard
  setup rule: camera goes inside the cage.
- **G1(tee) fails → full stop** — rethink (shorter distance, brighter marker
  ball, different background) before any Swift is written.

## Verdict

- Date: ______
- Decision: GO / NO-GO / GO-outdoor-only
