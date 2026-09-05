# Field guide — from a fresh build to a measured swing

Follow this in order. Every button name in quotes is the exact text on screen.
Each part ends with a check: if the check fails, the guide says exactly what to
do — usually "copy something and send it", never "fiddle until it works".

Where we are: the app runs, but **ball detection has never succeeded on real
footage**. Parts A–C are the path to fixing that. Parts D–E are the session
routine once it works.

---

## Part A — Put the latest build on the phone (5 min, at home)

1. Quit Xcode completely (⌘Q).
2. Open Terminal and paste:

   ```
   cd ~/slowpitchangleapp && git pull && cd app && xcodegen generate && open SwingLab.xcodeproj
   ```

   (If the folder lives elsewhere, `find ~ -name "project.yml" -path "*slowpitch*" 2>/dev/null` prints where.)
3. In Xcode, click the device menu at the top (next to the ▶) and pick your
   phone — it is listed by its **name**, not "iPhone".
4. Press **⌘R**. Wait for the app to appear on the phone.

**Check:** the app launches on the phone.
- Red errors in Xcode → copy them all, paste to Claude. Do not try to fix them.
- "Signing for SwingLab requires a development team" → click the blue
  **SwingLab** project icon (left sidebar) → **SwingLab** target →
  **Signing & Capabilities** → pick your team under Team. Press ⌘R again.

---

## Part B — Prove every detector indoors (10 min, before any field trip)

Launch the app. Allow camera and microphone when asked. The setup screen opens
by itself on a first run only; after that it is the **SET UP** button, top
right.

### B1 — The hitter detector
Point the phone at a person (or yourself in a mirror), a few metres away.

**Check:** a yellow **skeleton** draws over the person, and the **ARM** stage
(3, in the stepper) shows **Hitter — detected ✓**.
- Stays "Looking for hitter…" → Settings tab → **Camera orientation** →
  try **"Right (90°)"**, then each other option. One of them will light it up;
  tell Claude which one worked, because Auto should have.

### B2a — Distance from the hitter (the default, no ball needed)
On the **HITTER** stage (2 in the stepper), type the hitter's height in cm once,
then stand in frame, side-on, **standing tall with your knees straight**.

**Check:** the panel counts "Hold still… 3 of 5", then chimes and shows
**"≈ x.x m · from hitter height"** with a chip — GOOD (4.5–6 m), WORKABLE
(3.5–8.5 m) or MOVE.
- "Stand up straight — knees locked" or "Stand tall, don't lean" → it is
  refusing a crouch on purpose. A batting stance shortens the measured span by
  7–12%, which would read as a camera a third of a metre out.
- "Turn the phone sideways to measure" → portrait cannot measure this. Rotate.
- Nothing counts → the pose is not being found; see B1.

### B2b — The ball detector (the alternative, and the one that has been failing)
Only if you want it: **"…"** → **Tap the ball instead**. Put a softball on a
chair 4–6 m away and tap it **on the screen**.

**Check:** the ring where you tapped turns **green** and the panel reads
**"Ball found — N px across"**.
- Ring stays amber and a message appears → **the message is the instruction**.
  Do what it says ("move it onto a different-coloured surface", "move it into
  the light", …) and tap again.
- Fails repeatedly → below the message is a small grey monospaced line (e.g.
  `seed24c · d 104px · fill 0.79 · rays 14/16 …`). Screenshot the card and send
  it to Claude. **Do not start moving the colour sliders in Settings** — that
  line says which gate rejected it, and guessing fights the diagnosis.

### B3 — The trigger
**Close setup first (the X, top left)** — the bar and the status tile only
exist on the main screen. Then watch the thin bar just above the bottom buttons
and **clap hard** near the phone.

**Check:** the bar jumps past the small white notch.
- Nothing moves → tap the black status tile (bottom-left) → **Status** sheet →
  **Trigger** section shows "Contact level" live. If it never moves on a clap,
  screenshot that sheet and send it.

### B4 — The whole chain
Tap **"Arm"**. **Step into the camera's view** and clap hard once —
the trigger deliberately ignores sounds when nobody has been in frame for
~1.5 s, so a clap from behind the phone is eaten and "N ignored" counts up
(that is the gate working, not a bug).

**Check:** the button flashes red **"Stop"** (recording), then a swing card
appears saying **"No ball track in that clip"** — CORRECT for a clap: it proves
trigger → record → analyse runs end to end. Tap "Stop" to disarm.
- No recording, "N ignored" climbing → you were out of frame. Either step in,
  or for this test flip Settings → Trigger → "Only trigger with a person in
  frame" off (and back on after).

When B1–B4 all pass, the app's machinery works. What remains unproven is
detection on *real footage* — Part C.

---

## Part C — Fix ball detection with one real clip (the current blocker)

You need one slow-motion clip of one swing, in the Photos app. Film it with the
stock Camera in **Slo-mo** (Settings → Camera → Record Slo-mo → **1080p at 240 fps**),
side-on, 4–6 m away — or use footage you already have.

1. In SwingLab: **Swings** tab → the **⤓ icon** (top right) →
   **"From Photos (keeps 240fps)"**. Allow photo access. Pick the clip.
   - Never use "From Files" for slow-motion — that route hands over a 30fps
     render and every speed comes out 8× wrong.
2. Wait through "Measuring the clip…".
3. A sheet titled **"Clip diagnostics"** opens by itself. Read two lines:
   - the `clip` line: the frame rate is **measured from the clip's own frame
     timing**, so it reads whatever you actually filmed — 240, 200, 198.94 —
     and the word after it says where the number came from. `(measured)` is
     what you want. If the container disagreed, the next line says so; that is
     normal for slow motion and nothing to fix.
     - If it says **30 fps (measured)**, the file really is 30 fps: you filmed
       in normal video, or exported the slow-motion *edit*. Re-film in Slo-mo
       and import with **"From Photos"**.
     - There is no frame-rate preset to choose any more. The override in
       Settings → Analysis is off by default and should stay off.
   - the `verdict` line at the bottom. Find it in this table:

| verdict says | meaning | what you do |
|---|---|---|
| "clean run." | **Detection worked.** | Check the banner's numbers are sane, then go to Part D. Send Claude the report anyway — first success is worth recording. |
| "the ball's colour is outside the HSV window…" | Ball's colour isn't what the detector expects in this light | Tap **"Frames"** on the sheet → scrub to the ball sitting still → "Use current" on Frame 1 → mid-flight ball on Frame 2 → hitter on Frame 3 → **"Export 3 frames"** → **"Share 3 PNGs"** → send PNGs + the copied report to Claude |
| "colour matched but nothing passed the size and shape gates…" | Colour fine, geometry gates wrong | Copy report → send to Claude. No frames needed yet |
| "candidates were found but never linked into a flight…" | Something ball-coloured everywhere confuses tracking | Frames: one mid-flight frame + report → Claude |
| "…metadata read fine but not one frame decoded…" | Hardware decoder was busy | Close other camera apps, force-quit SwingLab, retry the import once. Still failing → report to Claude |
| "a track was built but analysis rejected it…" | Detection fine, physics rejected it | Copy report → Claude |
| "measured, but off a short track — treat the number as provisional." | Worked, but on few frames — numbers shaky | Copy report → Claude; don't move on from Part C on this alone |
| "clip could not be decoded at all" | File unreadable (format/corrupt), not a busy decoder | Re-import via "From Photos"; still failing → report → Claude |

4. **Always tap "Copy" and paste the whole report to Claude**, success or
   failure. It is a few hundred bytes and it is the only evidence that matters.

**The rule for this whole part: change one thing at a time, and only what the
report or Claude said to change.** The report exists so nobody has to guess.

---

## Part D — Calibrate the trigger at each venue (2 min, once per venue)

The default (15 dB) is a test gate, not a good threshold — too high for a quiet
garden, too low for a cage.

1. At the venue, phone on the tripod: **Settings** → **"Calibrate at this venue"**.
2. Tap **"Start — stay quiet"**. Say nothing for 5 seconds.
3. When it says **"Now hit 3 balls"**: three NORMAL swings, not your hardest —
   it sets the threshold from the *quietest* one.
4. Read the verdict chip:
   - **"Clear"** → tap **"Use N dB"**. Done.
   - **"Workable"** → tap "Use N dB", but expect an occasional missed swing —
     keep the MANUAL button in mind.
   - **"Too noisy"** → do not fight it: no threshold can work here. Use
     **MANUAL** to capture at this venue.

---

## Part E — A capture session, start to finish

### Setting up (once per session)
1. Tripod **side-on** to the swing, on the side the hitter **faces**
   (1B side for a right-hander), **4.5–6 m** from the plate — five big steps.
2. Phone **landscape**, roughly level. Open SwingLab.
3. Setup opens itself on a first run (otherwise tap **"SET UP"**, top right).
   It runs in three stages — the stepper at the top says which one you are on,
   and the segments are tappable if you want to go back.
4. **Stage 1, LEVEL.** A dashed line runs across the picture — that is where
   level actually falls. Aim the phone until it sits in the green band and
   reads **"LEVEL ✓"**, and keep the ball on the roll beam's centre mark. Off
   the bottom of the screen means you are aiming up; off the top, aiming down.

   Do this *before* worrying about the outline. The outline can be matched
   perfectly from a phone lying in the grass aimed upward — backing up and
   tilting fits a person into it just as well as standing it at belt height —
   so an outline that fits proves nothing on its own. **Next** goes green when
   the phone is level; **Skip** is always there.
5. **Stage 2, HITTER.** Type the hitter's height once, in centimetres. The
   hitter steps into the box facing the phone and **stands tall** — knees
   straight, no lean — until it **chimes**. The panel counts "Hold still… 3 of
   5"; if it says "Stand up straight" or "Stand tall, don't lean" it is
   refusing to measure a crouch, which would read as a camera a third of a
   metre further away than it is.

   You should then see **"≈ 5.2 m · from hitter height"** and a **Good** chip.
   Check it against a tape to the hitter's feet once — expect within about 5%.

   No hitter to hand? The **…** menu has: tap the ball (9.7 cm), mark home
   plate, type a distance, and clear. For the plate, **pinch to zoom** first —
   put one handle on the **front edge** (the side facing the pitcher, seen
   end-on, where the two corners meet) and the other on the **point** facing
   the catcher. That span is 43 cm and it runs across the picture; the front
   edge itself points at the lens and cannot be measured. Expect the plate
   reading to be roughly 0.7 m *less* than the hitter reading, because the
   camera is on the open side and the hitter stands behind the plate.
6. Match the scene to the batter outline: hitter where the figure stands, ball
   on the tee circle. **If the outline is red**, it is telling you it is not a
   valid target from where the phone is. Only a **yellow** outline is worth
   matching, and it is a picture rather than a check either way.
7. **Stage 3, ARM.** Four rows: Level, Hitter (**detected ✓** is the proof the
   pose gate will let your swings through), Distance and where it came from,
   and Lens height — the app has worked out how high the phone actually is,
   from the hitter's feet, the distance and the tilt. Amber means it is far
   from the 1.1 m the outline assumes. Raise or lower the tripod, but **keep it
   level**: aiming up to compensate for a short tripod costs far more than the
   low camera does.
8. Tap **ARM**. It is never blocked; anything you skipped is stamped on the
   swing instead.

### Each swing
Hit. The app records by itself and the swing card appears in a few seconds with
**Launch** and **Exit velo**.

### Seeing what was actually tracked

Numbers cannot tell you the detector spent a clip following a stripe of grass.
The picture can.

Open the swing (Swings → tap it) → **"Play with tracking overlaid"**. The clip
plays full screen with everything the app measured drawn on it:

- **green circle** — the ball, at the diameter that was measured. If the circle
  is visibly bigger or smaller than the ball under it, the scale is wrong, and
  so is the exit velocity.
- **yellow path** — the whole flight. A parabola is a hit. A line running along
  the ground, or a scribble sitting in one place, is the detector tracking
  something that is not the ball.
- **yellow skeleton** — the hitter, at this frame. Limbs are only drawn between
  joints the model was confident about, so a missing arm is a real gap and
  explains a missing body measurement.
- **amber rings** — balls the detector FOUND and the pipeline then discarded.
  An amber ring on the ball means it was seen; the question is why it was
  dropped, not why it was missed.
- **grey dashed box** — the region actually searched. Anything outside it was
  never examined at all, so a ball out there is not a detection failure,
  it is a search that never went near it.

### "No struck ball identified"

When the app cannot find a flight it can stand behind, it now says so instead
of reporting a number. The swing is still saved — the numbers on it are useful
evidence for WHY it failed — but they are labelled as a diagnostic, not a
measurement, and the import banner will not quote them at you.

Clearing it takes one tap: open the swing, **"Point at the ball"**, touch the
ball on any frame. The flag clears when the flight is followed from your tap.

### When it tracks the wrong thing: point at the ball

Some clips are genuinely ambiguous to a computer. A phone low in the grass can
give seventy ball-coloured blobs per frame, and the app then has to guess which
of several hundred candidate tracks is the hit. Every automatic rule has a
failure case: the longest track is the pitch hanging in frame, the fastest
short one is noise, the roundest blob is a leaf.

You can settle it in one tap.

**Play with tracking overlaid → "Wrong thing tracked? Point at the ball"**.
Scrub to any frame where you can see the ball clearly, tap it, and the app
follows the flight outward from that point — forwards and backwards — using
physics rather than guesswork. It then re-measures.

The tap is remembered, so re-analysing (after setting the horizon, say) keeps
following the ball you pointed at.

Two honest outcomes worth knowing:

- **"nothing was detected there"** means the ball was not *found* in that
  frame, which is a different problem from the wrong track being chosen — fix
  the colour window or the framing, not the selection.
- If you tap something that isn't the ball, it will faithfully track that. It
  does what you point at.

### The camera wasn't level — fixing it after the fact

A clip **this app filmed** records its own tilt from the phone's motion sensor
and corrects for it automatically, at any angle. A clip from the stock Camera
app records nothing of the sort, so an imported swing starts out assuming a
level camera — and nobody hand-holding a phone is level.

In **"Play with tracking overlaid"**, tap **"Camera wasn't level? Set the
horizon"**. Drag the green line onto the real horizon — the tree line, the far
fence, wherever the ground meets the sky — and it reads back the angle the
phone was pointing at. Then **"Re-measure with this tilt"**.

Roughly right is genuinely enough. The correction is smooth in the angle with
no cliff, so a horizon placed a few degrees out lands far closer to the truth
than pretending the camera was level. It is worth doing even for a clip that
looks nearly level.

Two things to know:

- Set **Settings → Analysis → "Imported clip lens (FOV)"** to match what you
  filmed on — 68° for the normal 1× camera, about 100° for 0.5×, about 40° for
  2× or 3×. Without a lens angle there is no focal length, and the tilt
  correction needs both.
- **Camera height needs no correcting.** A level camera sees the same geometry
  from the grass as from a tripod — the ball just rides higher in the picture.
  Only *tilt* costs accuracy, which is why aiming a short tripod upward is
  worse than leaving it low and level.

Those three cases are what "it didn't detect the ball" splits into, and they
need opposite fixes: nothing drawn at all means the colour or size gates
rejected it (Settings → Ball colour / Ball size); an amber ring means the
track builder or the flight-corridor filter dropped it; outside the box means
the search was aimed wrong.

Step frame by frame with the arrows. The readout says `no ball this frame`
wherever the tracker lost it, which is what turns "it failed" into "it failed
here".

### Is it capturing correctly? Three checks
- **Numbers plausible?** Launch angle between −10° and 50°, exit velo roughly
  60–140 km/h (40–90 mph). Wildly outside → screenshot the card → Claude.
- **Any amber chips on the card?** Tap the **chip itself** — each one pops up
  what it means.
  A flagged number is a labelled number, not a wrong one — but flags on *every*
  swing mean something systematic; send a screenshot.
- **Chips at the top of the screen?** "N ignored" climbing means the hitter
  gate is eating triggers. If the app has seen NO hitter at all since arming,
  after ~20 s it offers **"Trust the audio trigger"** — take it. If "N ignored"
  keeps climbing *without* that offer, flip Settings → Trigger → "Only trigger
  with a person in frame" off yourself (those swings get flagged, which is
  fine). "N dropped" means the phone is struggling — close other apps, let it
  cool.

### Captures nothing at all?
Clap test (B3). Bar moves but no capture → Status sheet → is "Ignored — no
hitter" climbing? Bar doesn't move → recalibrate (Part D) or use **MANUAL**.

### After the session
Swings tab → any swing → replay and details. Share icon exports everything as
CSV. Sessions where something felt wrong: export and send the CSV row along
with what you saw.

---

## What to send Claude, and when

**The one that matters most, and it is one file for a whole session:**

> Swings → **Select** → tick every swing from the session → the **share icon**
> (top right, the box with the arrow out of it) → AirDrop, Files or Mail.

That writes a single `diagnostics_<n>swings_<date>.json` carrying, for every
swing you ticked: the report, the ball track, the flags, the camera angles and
the detector's own trace. It is tens of kilobytes. It replaces sending clips
one at a time, and — this is the point — it goes into `spike/corpus/`, where
it stays. Clips sent as `.mov` attachments are looked at once and gone; a
bundle in the corpus is replayed against every future change to the pipeline,
forever, in a second.

**Say what actually happened, per swing.** A clip nobody has labelled can show
that behaviour changed between two builds; it can never say which build was
right, and only you know. Two words each is enough:

> `live_48 no swing · live_49 no swing · live_51 hit, grounder to the left ·
>  live_52 hit, line drive`

Right now the corpus holds four sessions' worth of confirmed **no-swings** and
not one confirmed **hit**. Everything the pipeline has learned lately is a way
of saying "no", checked only against clips whose answer is "no". **A handful of
swings you can vouch for as real hits is worth more than another twenty clips.**

Everything else, unchanged:

| Situation | Send |
|---|---|
| Import failed or succeeded (Part C) | The copied diagnostics report — every time |
| Colour verdict | + the 3 exported PNGs |
| Tap-to-measure keeps failing (B2) | Screenshot of the card incl. the grey line |
| Capture behaves oddly | Screenshot of the Status sheet |
| Numbers look wrong | Screenshot of the swing card + the CSV row |
| A clip the trigger missed entirely | The `.mov` — nothing on the phone recorded it, so the bundle has nothing to carry |

One change at a time. Reports over guesses, every time.

### One caveat about the bundle

To keep it small the phone trims each trace to the candidates within **±0.5 s
of contact**. That is the part any question about the ball is actually about,
and it is enough for almost everything. It is not enough when the question is
"what else was moving elsewhere in the clip" — for that, send the `.mov` too
and it gets re-detected in full.
