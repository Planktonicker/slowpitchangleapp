# Mac setup — from zero to running on your iPhone

Everything you need on the MacBook, in order. §1–3 are enough for Phase 0
(the Python validation spike). §4–7 matter from Phase 1 on, when there is an
app to build onto your iPhone.

---

## 1. Install the basics

1. **Xcode** (free, big download ~10 GB): App Store → search "Xcode" → Get.
   Open it once after installing and accept the license / let it install
   components. (Phase 0 only needs it for Python via its command-line tools,
   but you'll want the download done before Phase 1.)
2. **Command-line tools** (if Terminal ever says they're missing):
   ```
   xcode-select --install
   ```
3. **Homebrew** (package manager) — paste in Terminal:
   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
   then follow its "Next steps" lines to add brew to your PATH.
4. **Tools we use**:
   ```
   brew install xcodegen ffmpeg
   ```
   - `xcodegen` — generates the Xcode project from `app/project.yml` (Phase 1+)
   - `ffmpeg` — only needed for the audio-trigger check script (optional)

## 2. Get the repo

```
git clone https://github.com/Planktonicker/slowpitchangleapp.git
cd slowpitchangleapp
```

## 3. Python spike environment (Phase 0)

```
cd spike
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python synth_test.py
```

The last command renders a synthetic 240fps clip with known launch angle /
exit velocity and runs the full pipeline on it. It must end with
**`ALL PASS`** — if it does, your install works and every later script will
run. (Each new Terminal window: `source .venv/bin/activate` again first.)

---

## 4. One-time iPhone preparation (Phase 1+)

1. Plug the iPhone into the Mac with a cable. Tap **Trust** on the phone.
2. Enable **Developer Mode**: Settings → Privacy & Security → Developer Mode
   → on → restart phone. (If the switch isn't visible yet, it appears after
   the first time Xcode tries to install an app on the phone.)

## 5. Generate and open the Xcode project (Phase 1+)

The `.xcodeproj` is not in git — you generate it:

```
cd app
xcodegen generate
open SwingLab.xcodeproj
```

Re-run `xcodegen generate` any time `project.yml` changes (git pull etc.);
just re-opening Xcode is enough for plain Swift-file changes.

## 6. Free signing with your Apple ID

In Xcode:

1. Xcode menu → Settings → Accounts → **+** → add your Apple ID (a normal
   free one works; no paid account needed yet).
2. Click the blue project icon (top of left sidebar) → target **SwingLab**
   → **Signing & Capabilities** tab:
   - check **Automatically manage signing**
   - Team: select your name — "**(Personal Team)**"
   - if the bundle identifier collides, change the prefix to anything
     personal, e.g. `com.<yourname>.swinglab`.

## 7. Build to the phone

1. Top toolbar device menu: pick your iPhone (not a Simulator — the camera
   code needs real hardware).
2. Press **Run** (▶). First install: the phone shows "Untrusted Developer" —
   fix on the phone at Settings → General → VPN & Device Management → your
   Apple ID → Trust. Run again.

### The 7-day rule (until TestFlight)

Free-account provisioning expires after **7 days** — the app icon stays but
the app won't open. Fix: plug in and press Run in Xcode again (takes a
minute; data on the phone is kept). This annoyance disappears in Phase 3
when the $99/yr Apple Developer account + TestFlight replace cable installs.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen`; new Terminal window |
| "Untrusted Developer" on phone | Settings → General → VPN & Device Management → Trust |
| Xcode: "failed to prepare device" | Unlock the phone, reconnect cable, let it finish "Preparing" |
| App stopped opening after a week | 7-day rule — re-Run from Xcode (§7) |
| `synth_test.py` fails to import cv2 | you're not in the venv: `source .venv/bin/activate` |
