# Getting SwingLab onto a phone, and keeping it there

Two separate problems that are easy to confuse:

1. **Installing without a cable** — free, works today, five minutes.
2. **Stopping the app expiring** — costs $99/year, and there is no way around it.

## 1. Wireless install from Xcode (free)

One-time pairing, over a cable:

1. Plug the iPhone into the Mac and trust it.
2. On the phone: **Settings → Privacy & Security → Developer Mode → on**, then
   restart when it asks. (iOS 16+. It only appears once the phone has been
   plugged into Xcode at least once.)
3. In Xcode: **Window → Devices and Simulators → Devices**, select the iPhone,
   tick **Connect via network**.
4. Unplug. A globe appears next to the phone in the run-destination menu.

From then on ⌘R installs over Wi-Fi. Both machines have to be on the same
network — a phone on cellular, or a Mac on a different VLAN, will not be found.

If it stops appearing: unpair (right-click the device → Unpair) and redo the
cable step. That is the usual fix and it is quicker than diagnosing it.

## 2. How long the app survives

This is the part that bites, and it has nothing to do with cables.

| Signing with | Profile lasts | Then |
|---|---|---|
| **Free Apple ID** (Personal Team) | **7 days** | The app refuses to launch. Re-run from Xcode to refresh it. |
| **Apple Developer Program** ($99/yr) | **1 year** | Nothing, for a year. |

The free tier also caps you at 3 sideloaded apps on the device and 10 new App
IDs per week. For a phone that lives on a tripod at a field once a week, the
seven-day expiry is the thing that will actually stop you — you will drive
somewhere, open the app, and find it dead.

**If you are testing this for more than a couple of weeks, pay the $99.** There
is no free path to a long-lived build; Apple removed it deliberately.

## 3. TestFlight (needs the paid account)

The proper answer to "keep it in testing": builds install through the TestFlight
app, over the air, with no Mac in the loop at all. Useful the moment anyone
other than you is swinging.

Setup, once:

1. **App Store Connect → Apps → +** → new app. Bundle ID must match
   `com.swinglab.SwingLab` (register it first at *Certificates, Identifiers &
   Profiles → Identifiers*).
2. Xcode: select **Any iOS Device (arm64)** as the destination →
   **Product → Archive** → **Distribute App → TestFlight & App Store**.
3. In App Store Connect → **TestFlight → Internal Testing**, add yourself (up to
   100 people on your team). Internal builds skip App Review and are installable
   within minutes of processing.

Then, per build:

- **Bump `CURRENT_PROJECT_VERSION` in `app/project.yml`** and re-run
  `xcodegen generate`. Every upload needs a build number App Store Connect has
  not seen before; a repeat is rejected after the upload finishes, which wastes
  the whole cycle.
- `MARKETING_VERSION` is the human version (`0.1.0`) and only needs bumping when
  you want it to change.

Things that will otherwise trip you up:

- **Export compliance** — already answered. `ITSAppUsesNonExemptEncryption:
  false` is set in `project.yml`, because the app makes no network requests at
  all. Without it TestFlight asks on every single upload.
- **App icon** — required. Already in `app/Resources/Assets.xcassets`.
- **Builds expire after 90 days.** Upload a new one; nothing else is needed.
- The app is AGPL-3.0. Distributing your own build through TestFlight is fine;
  if you ever ship it publicly, the licence obligations apply.

## What NOT to bother with

- **Ad-hoc / enterprise distribution** — needs the same paid account, more
  setup, and buys nothing over TestFlight for a project this size.
- **Third-party sideloading tools** that re-sign a free-tier build every seven
  days. They work, and they are a moving target that breaks on iOS updates,
  usually at a field with no laptop.
