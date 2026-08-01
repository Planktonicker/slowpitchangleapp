# SwingLab app — build it, then take it to the field

The app captures at 240fps, detects contact by sound, analyses the swing on
the device and shows launch angle and exit velocity within a couple of
seconds. It also keeps every clip, so anything that looks wrong can be re-run
against the Python reference later.

> **Status: unproven on real footage.** The measurement core is the validated
> Phase 0 pipeline, ported to Swift and pinned to it by tests. What has never
> been tested is the *capture* half — a real ball, real light, a real cage. The
> app is the instrument you use to find that out, not evidence that it works.

---

## 1. Build and install

Prerequisites are in [MAC_SETUP.md](MAC_SETUP.md) §1 and §4-7 — Xcode, an
Apple ID, XcodeGen, and Developer Mode on the phone.

```
cd app
xcodegen generate
open SwingLab.xcodeproj
```

Then in Xcode: select your iPhone as the destination, set **Signing &
Capabilities → Team** to your Personal Team, and press Run.

Re-run `xcodegen generate` whenever `app/project.yml` changes or files are
added. Editing existing Swift files needs only a rebuild.

Remember the 7-day rule: free provisioning expires after a week and the app
stops opening. Plug in and Run again.

### Run the tests

`Cmd-U` in Xcode, or:

```
cd app
xcodebuild test -scheme SwingLab -destination 'platform=iOS Simulator,name=iPhone 15'
```

`ParityTests` compares the Swift measurement core against golden vectors
generated from `spike/sla_common.py`. If you change either side:

```
python spike/gen_parity_fixtures.py    # regenerate app/Tests/Fixtures/parity.json
```

and run the tests again. A failure means Swift and Python have drifted apart —
that is the whole point of them.

---

## 2. Set the camera up

Same geometry as [CAPTURE_PROTOCOL.md](CAPTURE_PROTOCOL.md), except the app
checks it instead of trusting you.

1. Tripod perpendicular to the line of play, on the hitter's **open** side,
   lens at roughly contact height.
2. Open the app, **Capture** tab, tap **Placement**.
3. **Level** — get the bubble green. Roll is fed into the maths as a
   correction, so a small error is survivable. Tilt is not: a camera pointing
   up or down turns the flight into a projection.
4. **Distance** — aim the cross at the plate or tee. 15-20 ft, preferring 20.
   Without ARKit, switch to manual entry and use the tape.
5. **Plate scale** — drag the two handles onto the ends of home plate's front
   edge (the 17 in one facing the pitcher). The app compares what it measures
   against what the distance and lens geometry predict. This is a third scale
   estimate, independent of the ball and of gravity, and it catches a wrong
   distance before you hit anything.
6. **Ready** — tap **Lock focus and exposure** aimed at the hitting zone, then
   **Arm**.

Arming is blocked until level, distance and plate scale all pass. That is
deliberate: every number is scaled from pixels, so a camera that moved between
sessions silently changes the readings.

## 3. Hit

Pick the **setting** from the menu at the top right before each round — it
matters. The prefixes match the Python's naming convention, and the validation
gates are computed per setting:

| Setting | Use for |
|---|---|
| Outdoor tee | The gate that decides the project (G1) |
| Tee (repeatability) | The five identical-intent swings (G4) |
| Soft toss | Normal variety |
| Field, live pitching | Also proves the pitch is separated from the hit |
| Cage (camera inside) | The main computer-vision risk |
| Cage (through net) | Expected to fail — recorded so it is documented |
| Fly ball | Ones where you pace off the landing spot (G3) |

Then just hit. The app hears contact, keeps the three-quarters of a second
before it and a second and a half after, and analyses. Numbers appear at the
bottom of the Capture screen.

If the trigger cannot hear contact — some cages are hopeless — use **Manual**.
Manual clips are recorded as such, so gate G5 stays honest.

Watch the **dropped frames** counter. Anything above zero means the capture
missed frames, which corrupts the constant frame interval every measurement
rests on. Stop and restart the app if it climbs.

## 4. Fly balls (gate G3)

On a clean fly, have someone watch where it lands. Pace off the distance and
time the hang with a stopwatch. Open the swing in **Swings**, type both into
the Ground truth section. The app runs the measured launch angle and exit
velocity through the drag model and shows how far off the prediction is —
±15% on hang, ±20% on carry.

This is the closest thing to a radar gun available, and it costs nothing.

## 5. Read the verdict

The **Validation** tab is `VALIDATION.md` computed live from what you have
captured: G1 per setting, G2 scale agreement, G3 fly balls, G4 repeatability,
G5 trigger reliability, and the go/no-go verdict from the decision rule.

Fill the numbers into `docs/VALIDATION.md` when you get home. Export from the
**Swings** tab produces three files:

- `summary_*.csv` — the same columns `spike/batch_run.py` writes, so device
  numbers can be diffed directly against Python numbers from the same clips
- `swinglab_*.csv` — everything the app knows, including placement and ground truth
- `validation_*.txt` — the scoreboard as text

## 6. When a number looks wrong

The clips are still on the phone. Two ways back to solid ground:

**Re-analyze on the device.** Open the swing, and either re-run with current
settings (after retuning the colour range) or re-run without Vision to see
what the reference detector alone makes of it.

**Re-analyze on the Mac** — the referee. Copy the clip and its track CSV off
the phone (Finder → iPhone → Files → SwingLab, or the share sheet), then:

```
cd spike
python analyze_swing.py out/tee_01.csv --flyball --hang 4.1 --carry-ft 185
python track_ball.py clips/tee_01.mov --debug-video --fps 240
```

The track CSV the app exports is byte-compatible with the format
`analyze_swing.py` reads, so the Python will re-derive the numbers from the
device's own tracking. If the two disagree, the port is wrong — and
`ParityTests` should have caught it, so that is worth reporting.

---

## What the app does and does not do

**Ported faithfully from the reference, and tested:**

- the drag-aware gravity scale solve — a softball flies at roughly its
  terminal velocity, so the naive `g / vertical_acceleration` is 20-40% wrong
- sub-pixel ball diameter by the matte-fraction method along the blur-free
  minor axis — colour-threshold contours over-read the compression halo and
  put ~6% straight into exit velocity
- track association, outbound-track selection, the confidence flags, and the
  drag flight model

**New in the app, and unproven:**

- 240fps capture, the compressed pre-roll ring, and the audio trigger
- the placement wizard
- Vision's `VNDetectTrajectoriesRequest` as a locator. It is good at "a small
  object flew along a parabola, here" but tells us nothing about apparent ball
  size, and ball size is half the scale cross-check. So Vision narrows the
  search and the ported detector does all the measuring. If Vision finds
  nothing, the detector sweeps the whole frame instead.
- bat attack angle from the barrel tape. One camera, side on, over a few
  milliseconds — indicative, not a swing plane. True 3D needs two synced
  cameras and is deferred to v2.
