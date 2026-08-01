# Contributing to SwingLab

Thanks for looking. A few things about this project are unusual, so it's worth
reading this before opening a pull request.

## The state of things

Phase 0 is **not finished**. The measurement core works on synthetic footage
and has never been run on a real ball. Until `docs/VALIDATION.md` is filled in
from real swings and the outdoor-tee gate passes, the useful contributions are
the ones that help answer *does this work at all* — not new features.

Most valuable right now:

- real footage results, and the clips behind them
- a venue where tracking or the audio trigger fails, with the clip attached
- build errors on a real Mac and iPhone (nothing here has been compiled yet)

## The one rule that matters

`spike/sla_common.py` is the single source of truth for every piece of
tracking and physics maths. The Swift in `app/Sources/Core/` is a port of it,
and `app/Tests/ParityTests.swift` fails if the two disagree.

So if you're changing any of that maths:

1. Change the **Python** first.
2. Regenerate the golden vectors:
   ```
   python spike/gen_parity_fixtures.py
   ```
3. Make the matching change in Swift.
4. Run both `python spike/synth_test.py` (must print `ALL PASS`) and the Xcode
   tests (`Cmd-U`).
5. Include the regenerated `app/Tests/Fixtures/parity.json` in your PR, and say
   in the description which numbers moved and why.

A PR that changes Swift maths without the Python, or that edits `parity.json`
by hand to make a test pass, will be sent back. Those fixtures are the only
thing keeping the two implementations honest.

### Two pieces of maths that look wrong and are not

Both cost real debugging. Please don't "simplify" them:

- **The drag-aware gravity scale** in `solve_gravity_scale`. A softball flies
  at roughly its terminal velocity (~30 m/s), so drag is comparable to gravity.
  The naive `scale = g / vertical_acceleration_in_pixels` is 20-40% wrong.
  Root selection is nearest-to-hint, not `min()` — there is a fixture that
  catches exactly that mistake.
- **Sub-pixel ball diameter** by the matte-fraction method along the
  motion-blur-free minor axis. Colour-threshold contours over-read the
  compression halo around the ball by about 6%, and that lands directly in
  exit velocity.

## Style

Match the file you're editing. Comments explain *why*, especially where a
choice looks odd — that convention is the reason the two findings above
survived being ported.

Every source file carries an SPDX header. New files need one:

```swift
// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.
```

## Never commit

Video files, clips, or anything with a person in it. `.gitignore` covers the
usual extensions, but check `git status` before committing — footage is easy to
add by accident and effectively impossible to remove from public history.

Nor the generated `app/SwingLab.xcodeproj` or `app/SwingLab-Info.plist`: both
come from `app/project.yml`, which is the single source of truth for the build.

## Licensing of contributions

SwingLab is licensed under the **GNU Affero General Public License v3.0 only**
(see `LICENSE`).

By opening a pull request you agree to two things:

1. Your contribution is licensed to the project and to everyone else under
   AGPL-3.0-only, on the same terms as the rest of the work.
2. You additionally grant the maintainer a perpetual, worldwide,
   irrevocable, royalty-free right to license your contribution under other
   terms, including proprietary ones.

Point 2 exists for a practical reason, and it's only fair to say so plainly.
The plan is to ship SwingLab through TestFlight and possibly the App Store,
and GPL-family terms sit badly with App Store redistribution. As sole
copyright holder the maintainer can distribute the work under any terms; the
moment a contribution arrives under AGPL alone, that stops being true for the
whole codebase. The grant keeps dual-licensing possible.

If you would rather not grant point 2, please say so in the PR. The change can
still be discussed and reimplemented independently — better that than an
unclear licensing position later.

You must also have the right to make the contribution in the first place: it
must be your own work, or work you are permitted to relicense. Don't paste in
code from a project under an incompatible license.

## Conduct

See `CODE_OF_CONDUCT.md`.
