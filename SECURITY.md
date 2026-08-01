# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

Use GitHub's private reporting: go to the **Security** tab of this repository
and choose **Report a vulnerability**. That opens a channel visible only to
the maintainer.

Please include what you were doing, what happened, and — if you have one — a
minimal way to reproduce it. You will get an acknowledgement within about a
week. This is a personal project maintained in spare time, so please don't
expect a same-day response.

If a report is confirmed, the fix and an advisory go out together. You will be
credited unless you'd rather not be.

## Supported versions

Only the tip of the default branch. There are no released versions and no
backports.

## What is in scope

The code in this repository: the iOS app under `app/` and the Python
reference implementation under `spike/`.

Things worth reporting:

- a way for one device's swing data or clips to reach another device or any
  network endpoint — the app is designed to send nothing, so any egress at all
  is a bug
- a path traversal or injection through an imported clip, a track CSV, or a
  settings value
- a crash reachable from a malformed video file that looks exploitable rather
  than merely a crash
- anything that writes outside the app's own container

## What is out of scope

- **Measurement accuracy.** The numbers are unvalidated by design at this
  stage — see `docs/VALIDATION.md`. Wrong readings are a correctness matter,
  so please open a normal issue with the clip and its track CSV attached.
- Crashes on deliberately corrupt video that are plainly just crashes.
- Anything requiring a jailbroken device or physical access to an unlocked
  phone.
- Reports produced solely by a scanner, with no working reproduction.

## Data handling, for context

SwingLab stores everything locally: clips in the app's Documents directory,
measurements in a local SwiftData store. It has no accounts, no analytics, no
crash reporting and no network code — it never opens a socket.

File sharing is deliberately enabled (`UIFileSharingEnabled`) so clips and
CSVs can be pulled off with Finder or the Files app. Anything in the app's
Documents directory is therefore visible to anyone with access to the unlocked
device or an unencrypted device backup. Clips are video of whoever was in
frame; treat them the way you'd treat any other video on your phone.
