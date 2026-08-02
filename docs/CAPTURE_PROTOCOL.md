# Capture protocol — Phase 0 validation footage

Goal: ~40 swings of 240fps footage across your three real settings, filmed
exactly the way the app will later film, so the Python pipeline can prove (or
disprove) the measurement approach before any app code exists.

## Equipment

- iPhone + tripod with phone mount, able to stand ~lens-at-waist height (~1.1 m)
- Tape measure (or practiced 0.9 m paces) for camera distance and carry distances
- The actual game balls — standard **30.5 cm circumference optic-yellow** slow-pitch softballs
- A strip of **fluorescent pink/orange tape** wrapped once around the bat barrel
  **at the sweet spot** (~10–15 cm from the barrel end). Placement matters twice:
  attack angle is measured at the tape, and the contact-offset ("undercut")
  reading assumes contact happens near the tape — put it where you actually
  hit the ball.
- Paper + pen for the clip log (template at the bottom) and a marker card to
  "slate" clips

## Camera settings (stock Camera app)

1. Settings → Camera → **Record Slo-mo → 1080p at 240 fps** (one-time).
2. Camera app → **Slo-mo** mode, **landscape** orientation, normal **1x wide**
   lens (do not let it switch to 0.5x/2x).
3. Before each round: **press-and-hold** on the hitting zone until "AE/AF Lock"
   appears — locks focus/exposure so the ball doesn't smear when a cloud passes.
4. Transfer clips via **AirDrop** (original quality). Do not trim/edit in
   Photos first — editing can re-encode and mangle the 240fps timing.

## Geometry (this becomes the app's placement wizard — film it the same way)

- Tripod **perpendicular to the line of play** — square to the direction the
  ball will travel, so the flight crosses the frame rather than running toward
  or away from the lens. This is a measurement requirement, not a preference: a
  ball flying at the camera is foreshortened, so its speed reads low and its
  angle is wrong (the pipeline flags this as `DEPTH_MOTION`). Level, **4.5–6 m**
  from the plate/tee. Measure the distance, write it in the log. Prefer 6 m if space
  allows (more flight stays in frame).
- Lens height ≈ contact height (**~1.1 m**).
- Stand the tripod on the side the hitter **faces** — **1B side for a
  right-hander**, 3B side for a left-hander. A right-hander bats from the 3B
  box and turns to face the plate, so filming from the 3B side films their
  back and their own body hides the bat at contact.
- Frame it so the plate/tee sits about **one-third from the edge** of the frame
  on the catcher side, leaving ~70% of the width for the outgoing ball.

## Slate every clip

Photos strips filenames, so: hold the marker card in front of the lens for
~1 s at the start of each clip with the log number on it ("7"), and keep the
paper log as the real metadata (setting, distance, notes).

## Once per location

- 3 s static clip of the plate with a **yardstick standing vertically** at the
  plate (backup scale reference).
- **Cage only:** 5 s static clip of the empty cage — we check it for LED
  flicker banding, which 240fps exposes badly and daylight doesn't have.

## Coverage matrix (~40 swings)

| Set | Clips | Notes |
|-----|-------|-------|
| Outdoor tee | 10 | includes the **repeatability five**: 5 swings where you try to hit the identical mid-height line drive — name these `teeid_01..05` |
| Outdoor soft toss | 10 | normal variety |
| Field, live pitching | 10 | mix of grounders/liners/flies — also proves the pipeline separates the inbound pitch from the outbound hit |
| Cage, camera **inside** | 10 | net as background only. If the tripod truly can't go inside, note it — that changes the app design |
| Cage, through the net | 3 | expected to fail; filmed so the failure is documented, not discovered later |
| Fly-ball ground truth | 3–5 | within the field session: clean flies where a helper watches the landing spot; **pace off plate-to-landing distance** and, if you can, time hang with a stopwatch. Name these `fly_01..` (they can double as `live_` swings) |
| Occlusion comparison | 2 | same tee swing filmed from the hitter's **closed** side, to quantify how much the body blocks |

## After filming

1. AirDrop everything into `spike/clips/`, rename per
   [clips/README.md](../spike/clips/README.md) (`tee_01.mov`, `cage_04.mov`, ...).
2. Run the pipeline — see README Quickstart step 4.
3. For any clip where auto-contact looks wrong in the debug video, redo it
   interactively: delete its CSV from `spike/out/`, then
   `python track_ball.py clips/<clip>.mov --fps 240` and mark the contact frame
   by hand.
4. Fill in [VALIDATION.md](VALIDATION.md).

## Paper log template

| # | Setting | Camera dist (m) | Lens height | Light | Carry (m, flies) | Hang (s) | Notes |
|---|---------|------------------|-------------|-------|-------------------|----------|-------|
| 1 | tee     | 6.0              | 1.1         | sun   |                   |          |       |
