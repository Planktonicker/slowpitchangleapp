# SwingLab Pro — what to film, and what to send

The two-phone app does not exist yet. The **3D measurement** does, and it can
be tested right now with two phones, a tape measure and no Xcode: film the
same event twice, send both clips, and `spike/multiview_lab.py` aligns them,
triangulates, and checks the answer against physics.

Work down this page in order. Each test is cheap and each one is a gate: if
it fails, the next one cannot mean anything, so stop and send what you have.

> [!IMPORTANT]
> **Do test 1 before test 3, even though test 3 is the interesting one.**
> A dropped ball has a known answer — 9.81 m/s² — and a swing does not. If
> the drop test is wrong, a swing measured by the same rig is wrong in a way
> nothing in the output would reveal.

## Why this is worth an afternoon

`docs/VALIDATION.md` records that the one-camera exit velocity is currently
**11% high on a big ball and 43% high on a small one**, because the scale
comes from the ball's apparent diameter and that measurement degrades as the
ball shrinks in frame.

Two cameras do not use the ball's diameter at all. Their scale is **the
distance between the tripods**, which is a tape measure. So this rig can
produce a trustworthy speed on footage where the single-phone path currently
cannot — and the drop test proves it before you believe any of it.

---

## What you need

- 2 iPhones that shoot 1080p 240fps, and 2 tripods
- 2 softballs (one sits still, one moves)
- A tape measure that reaches ~10 m
- Something to mark one spot on the ground: a cone, a cap, a batting tee
- Bright daylight

---

## Test 1 — the two-phone drop test

### Set up

1. **Mark one spot.** Everything is measured from here. If you have a tee,
   put a ball on it at the mark — that is the **reference ball** and it must
   not move for the whole clip. Measure the height of its middle off the
   ground. No tee? Rest it on the ground and tell me "on the ground".

2. **Phone A — exactly as you already film.** Side-on, perpendicular to the
   line of play, **6 m** from the mark, lens about **1.1 m** and **level**,
   1080p 240fps, **1× lens only** (never 0.5× or 2×), autofocus and exposure
   locked on the mark.

3. **Phone B — about 90° around from A.** Same 6 m, same height, same
   settings, aimed at the same mark.

   **For tests 1 and 2 nothing is hit**, so put B wherever a clean 90° is
   convenient. Read the safety section before test 3 — the placement has to
   change once a bat is involved.

4. **Measure five things**, tape flat **on the ground**, tripod base to
   tripod base — never a diagonal up to a lens:

   | | |
   |---|---|
   | A's tripod → the mark | ____ m |
   | B's tripod → the mark | ____ m |
   | A's tripod → B's tripod | ____ m |
   | A's lens height (ground to lens, vertical) | ____ m |
   | B's lens height | ____ m |

   *Sanity check: at 6 m each and a true 90°, the third number should be
   about **8.5 m**. If it comes out near 6 m your phones are only 60° apart;
   near 10 m they are ~110°. Anywhere in 8–9 m is ideal.*

### Film

5. Start **both** phones recording in slo-mo. Order does not matter and the
   gap between them does not matter — the tool works out the offset. It
   recovers a deliberate 370 ms offset to within a millisecond on synthetic
   clips.
6. Stand near the mark and **clap once, hard.** (A free bonus check if the
   audio survives the export. Nothing breaks if it doesn't.)
7. **Drop** the second ball from as high as you can reach, right beside the
   mark, and let it fall all the way to the ground. **Do not throw it.**
8. Stop both recordings.

**The one thing that can waste the trip:** the falling ball must be visible
in *both* frames for at least **0.20 s** — about 20 cm of fall. A drop from
head height gives 0.59 s, so you have plenty of margin, but only if the fall
path is inside both pictures. Check both previews before you drop.

Do it **three times** so we can see whether the answer repeats.

### Getting the clips to me

Send the **originals**, not a re-export. AirDrop to a Mac, or Finder with a
cable. The share-sheet "export" path renders slow-motion down to 30fps, and
a 240fps clip measured as 30fps is wrong by a factor of eight.

You don't have to verify that yourself — **the tool measures the real frame
rate from the file and reports it**, so if a clip came through wrong we'll
see it in the first line of the report.

Put them anywhere I can reach: Google Drive works (I can pull them directly),
or any shared link.

### What to tell me

Paste this filled in:

```
DROP TEST — <date>
clip A file:            <name>
clip B file:            <name>
A tripod → mark:        ____ m
B tripod → mark:        ____ m
A tripod → B tripod:    ____ m
A lens height:          ____ m
B lens height:          ____ m
Standing behind A looking at the mark, B is on my:   LEFT / RIGHT
Reference ball height:  ____ m   (or "on the ground", or "none")
Phones:                 A = <model>,  B = <model>
Format:                 1080p 240fps slo-mo?   yes / no
```

That is everything. I find the reference ball in the frames myself; you do
not need pixel coordinates.

### What comes back

A stage-by-stage report that names the stage that failed, if one did:

```
  [ok ] A decode: 812 frames, 1920x1080, 239.76 fps measured
  [ok ] A track:  119 frames over 0.558 s, straightness 0.97
  [ok ] rig:      separation 90.0 deg
  [ok ] sync (geometry): B's clock reads +369.3 ms vs A; median reprojection 0.71 px
  [ok ] triangulate: 105 of 105 instants (100% coverage)

  gravity  |a| = 9.976 m/s^2 vs 9.807 (+1.7%)
```

**Gravity is the whole test.** Within 5% and the geometry, the sync and the
triangulation are all working on real footage — and the scale is then good
enough to trust a speed. Outside 5% and it is almost always a tape
measurement, a wrong field of view for that phone, or a tripod that moved.

---

## Where phone B goes once you start hitting

**Never downrange.** Think of the hitter at the centre of a clock with the
ball flying out toward 12. Camera A is side-on at 3 (or 9). Ninety degrees
from A is either **12 — straight down the flight path**, or **6 — straight
back**, which is where foul tips and the backswing go. Both are places a
phone gets hit.

Put B at about **5 o'clock instead** (or 7, if A is at 9): behind the
hitter's back and off to the side. That is **60° of separation** from A —
the bottom of the useful band, but genuinely usable, and it clears both the
batted ball and the straight-back foul zone.

```
                 12  ball flies out
                     ✗ never here
        9                          3   camera A (side-on, as you film now)
                     ✗ not straight back
                  6      5  ← camera B  (~60° from A, behind and to the side)
```

Two reasons this is the right compromise rather than a grudging one:

- **B's real job is the body, not the ball.** From behind, the hips and
  shoulders lie across the frame instead of edge-on, which is exactly the
  view that makes rotation measurable. A already has the ball covered from
  the side, which is the best angle for flight.
- **60° still works.** The error budget puts depth accuracy at 90° roughly
  twice as good as at 30°; 60° sits close to the good end, and losing a
  little of that is worth not repairing a phone.

If you would rather keep a full 90° for test 3, put a screen in front of B.
Do not rely on being able to duck.

**Re-measure the five distances after moving B.** It takes two minutes and
the whole scale rides on them.

---

## Test 2 — a thrown ball (only after test 1 passes)

Same rig, nothing re-measured. Instead of dropping the ball, **toss it
gently across** the space so it arcs through both views.

This adds the thing a drop cannot test: horizontal motion, and therefore
**spray angle** — the left/right direction that one side-on camera can never
see. Gravity must still read 9.81.

Three tosses. Same message format, say "TOSS TEST".

---

## Test 3 — an actual swing

Only after 1 and 2 pass. Same rig, same measurements, and now hit off a tee
at the mark.

- Tee at the mark, so the contact point is where the rig is calibrated.
- **Both** phones must see the ball for ≥0.20 s after contact. This is the
  hard part outdoors and it is the same lesson `VALIDATION.md` already
  records for one camera: pull back rather than crop in.
- Clap before each swing.
- Five swings, same intent, so we get repeatability as well as a number.

What we get: exit velocity that never touches the ball-diameter measurement,
launch angle, **and spray angle** — plus, per swing, each phone's own
single-camera reading as an independent cross-check. Three numbers that
agree is evidence; disagreement is a flag.

Body and rotation metrics are **not** in this path yet. Those need the pose
tracker, which lives on the phone, not in these scripts — that is P3 in
`docs/SWINGLAB_PRO.md`.

---

## If something goes wrong

Send the report and the clips; the failing stage names itself. The usual
suspects, in order:

| The report says | It usually means |
|---|---|
| `decode: ... 30.00 fps measured` | an exported render, not the original |
| `track: no usable chain` | the ball was never followed in that view — too small, too far, too dark, or out of frame |
| `rig: those three distances cannot form a triangle` | one tape measurement is wrong |
| `rig: separation 42 deg — OUTSIDE the band` | move a tripod further round |
| `sync: no offset made the two views consistent` | the clips may not overlap in time, or the rig numbers are wrong |
| gravity off by more than 5% | tape measurement, field of view, or a tripod that moved |

Nothing here is a failure of the afternoon. Every one of those lines is a
measurement of what to change, which is the entire point of doing the cheap
test first.
