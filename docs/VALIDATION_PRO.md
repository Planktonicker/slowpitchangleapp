# SwingLab Pro validation — go/no-go record

The Pro counterpart to `docs/VALIDATION.md`, in the same shape and for the
same reason: cheap gates first, each one stopping the spending when it fails,
and a decision rule at the bottom that says what may be built next.

Fill this in as the tests in `docs/PRO_FIELD_GUIDE.md` are run. Nothing in
`app/SourcesPro/` beyond the scaffold should be written while GP1 is blank.

> [!WARNING]
> Every row below is empty. No two-phone footage has been measured. The
> synthetic rehearsal (GP0) passes, which proves the code, not the rig.

## What the whole ladder is trying to establish

A two-camera measurement has three things that can be wrong and only one
number that catches all three at once.

The three: **where the cameras are** (calibration), **when each frame
happened** (sync), and **whether the maths is right** (triangulation). The
one number: **gravity**. A ball in free flight accelerates at 9.80665 m/s²,
this is true regardless of scale, needs no reference object, no radar and no
tape, and it cannot be recovered from a rig whose geometry, clock or algebra
is wrong. So the ladder is built around getting a ball to fall in front of
two phones and asking what the reconstruction thinks gravity is.

That also makes Pro's scale *independent of the ball's apparent diameter* —
which matters, because `VALIDATION.md`'s G0 found that measurement is 11%
low on a 37 px ball and 43% low on a 26 px one, and is why single-camera
exit velocity is currently untrustworthy. Pro's scale is the tripod
separation. If GP1 passes, Pro can report a speed the one-camera path
cannot.

## GP0 — Synthetic rehearsal (no hardware, run it before every field trip)

```
cd spike && python multiview_lab.py --selftest
```

Renders two encoded clips of a drag-accurate dropped ball from a known 90°
rig with a deliberate 370 ms clock offset, then runs the identical pipeline
real footage will run.

- Recovered clock offset: **369.3 ms** vs 370 truth (**0.7 ms**)
- Recovered gravity: **9.976 m/s²** (**+1.7%**)
- Reprojection: 0.71 px median, 100% coverage
- Date last run: 2026-08-31 → Pass? **YES**

`python synth_multiview.py` is the deeper version — 25 checks including
hand-derived geometry, clock fitting through a heavy-tailed network, and the
error budget behind the accuracy table. Also passing.

## GP1 — The two-phone drop test (the G0 of Pro; do this first)

*Two phones ~90° apart, tape-measured, a ball dropped from head height. The
reconstruction must recover gravity.* Procedure: `PRO_FIELD_GUIDE.md` test 1.

| Drop | separation measured | tracked span, both views | reconstructed \|g\| | error | Pass (≤5%)? |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

- Median error: ______ % → Pass? ______
- Do the three agree with each other within 3%? ______

**Why 5%:** below it the scale is good enough that a reported speed rests on
the tape measure rather than on hope. The synthetic rehearsal reaches 1.7%
with a perfect rig, so most of the 5% is budget for real tape work and real
detection noise.

## GP2 — Sync agreement

*From the same clips as GP1 — no extra filming.* The geometric solve and the
audio correlation are independent witnesses of the same offset.

- Geometric offset: ______ ms, reprojection ______ px
- Audio offset (if the export kept audio): ______ ms
- Disagreement: ______ ms → Pass (≤40 ms)? ______

40 ms is deliberately loose: the two phones stand at different distances
from the clap and the tool does not correct for sound travel (~2.9 ms per
metre of path difference). This gate catches a **wrong pairing** — two clips
of different events — not sub-frame error. Sub-frame sync is what the P1
bench measures, on-device, later.

## GP3 — Horizontal motion and spray

*Procedure: `PRO_FIELD_GUIDE.md` test 2, a tossed ball.*

- Gravity still within 5% with the ball moving horizontally: ______ → Pass?
- Spray angle reported, and it matches the direction actually thrown: ______
- Horizontal distance travelled vs paced/measured: ______ → within 10%?

Spray is the first metric in the whole project that a single side-on camera
cannot produce at any confidence. It is also unvalidated against anything
but eyesight at this stage, which is what this row is for.

## GP4 — A struck ball, cross-checked three ways

*Procedure: `PRO_FIELD_GUIDE.md` test 3, tee swings.*

| Swing | 3D EV | phone A's own 2D EV | phone B's own 2D EV | 3D LA | spread |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |

- 3D EV vs the two 2D readings: ______ → do the 2D readings sit high, as
  G0's diameter finding predicts they should? ______
- **This is the row that would confirm the diameter bug from the other
  side**: if the 3D speed is consistently ~11% below the one-camera speed at
  the same ball size, two independent methods agree on the size of the
  error, and `_subpixel_minor_diameter` has its answer.

## GP5 — Repeatability, and the graduation rule

*The five identical-intent swings from GP4.*

- 3D EV std-dev: ______ mph (target ≤3) → Pass? ______
- 3D LA std-dev: ______ ° (target ≤3) → Pass? ______

**Glazier's rule, which governs every metric Pro ever ships:** a number
graduates from "experimental" only when its measurement error is smaller
than the athlete's own swing-to-swing variability — specifically when
SEM ≤ 0.5 × the between-swing SD. Both numbers get shown together, always.
A metric that cannot pass this stays labelled experimental no matter how
good it looks.

## Observations

(lighting, how hard the tape measuring actually was, whether tripods moved,
anything odd)

-

## Decision rule

- **GP1 fails → stop.** Everything else reads through the rig geometry. A
  wrong rig produces smooth, plausible, wrong 3D and nothing downstream will
  notice.
- **GP1 + GP2 pass → the offline lab is trustworthy**, and P1 (on-device
  clock sync) is worth building.
- **GP3 passes → spray angle is real**, and worth surfacing.
- **GP4 passes → Pro can report a speed the single-phone path cannot**, and
  P3's reconstruction core is worth porting to Swift.
- GP5 fails → metrics ship as trends only, never as session-to-session
  deltas.
- **Any gate passing on one clip is not a pass.** `VALIDATION.md`'s own G0
  entry says it: one clip is not grounds for changing a number that
  everything depends on.

## Verdict

- Date: ______
- Decision: GO / NO-GO / GO-with-limits
