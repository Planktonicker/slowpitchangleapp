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

Launch the app. Allow camera and microphone when asked. The setup screen
("Set up the camera") opens by itself whenever no ball has been measured yet.

### B1 — The hitter detector
Point the phone at a person (or yourself in a mirror), a few metres away.

**Check:** the chip under the title flips to **"Hitter detected ✓"** and a
yellow **skeleton** draws over the person.
- Stays "Looking for hitter…" → Settings tab → **Camera orientation** →
  try **"Right (90°)"**, then each other option. One of them will light it up;
  tell Claude which one worked, because Auto should have.

### B2 — The ball detector (this is the one that has been failing)
Put a softball on a chair across the room, 4–6 m away. Tap it **on the screen**.

**Check:** the ring where you tapped turns **green** and the card collapses to
one Distance row: **"≈ x.x m"** with a chip — "Good" (4.5–6 m), "Workable"
(3.5–8.5 m), or "Move". Tap the Distance row to expand it and see
**"Ball found — N px across"**. (Chips render in CAPITALS on screen.)
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
Tap **"2 · Arm"**. **Step into the camera's view** and clap hard once —
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
3. Setup opens itself (or tap **"SET UP"**, top right).
4. **Horizon line first, outline second.** A dashed line runs across the
   picture — that is where level actually falls. Aim the phone until it sits in
   the green band and reads **"LEVEL ✓"**. Off the bottom of the screen means
   you are aiming up; off the top, aiming down.

   Do this *before* worrying about the outline. The outline can be matched
   perfectly from a phone lying in the grass aimed upward — backing up and
   tilting fits a person into it just as well as standing it at belt height —
   so an outline that fits proves nothing on its own.
5. Match the scene to the batter outline: hitter where the figure stands, ball
   on the tee circle. **If the outline is red**, it is telling you it is not a
   valid target from where the phone is; the red banner across it says which
   fault to fix. Only a **yellow** outline is worth matching.
6. Hitter steps in → **"Hitter detected ✓"**.
7. Ball on the tee → **tap it on screen** → **"Ball found"**, distance chip
   **"Good"**.
8. A **"Lens 1.1 m up ✓"** chip now appears beside the level chip — the app has
   worked out how high the phone actually is, from the hitter's feet, the
   distance and the tilt. Amber means it is far from the 1.1 m the outline
   assumes. Raise or lower the tripod, but **keep it level**: aiming up to
   compensate for a short tripod costs far more than the low camera does.
9. Close setup (X) → tap **"2 · Arm"**.

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

| Situation | Send |
|---|---|
| Import failed or succeeded (Part C) | The copied diagnostics report — every time |
| Colour verdict | + the 3 exported PNGs |
| Tap-to-measure keeps failing (B2) | Screenshot of the card incl. the grey line |
| Capture behaves oddly | Screenshot of the Status sheet |
| Numbers look wrong | Screenshot of the swing card + the CSV row |

One change at a time. Reports over guesses, every time.
