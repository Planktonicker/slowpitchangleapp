# Phase 0 validation — go/no-go record

Fill this in after running the pipeline on your footage (`batch_run.py`
prints most of these numbers directly). Phase 1 app code starts only when
the decision rule at the bottom says GO.

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

*Per clip: `analyze_swing.py out/fly_NN.csv --flyball --hang T --carry-ft D`.*

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
