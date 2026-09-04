// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Where the app opens: pick how the ball is arriving, then start hitting.
///
/// The app used to open on a live viewfinder with three buttons on it, one of
/// which had to be pressed first and was the smallest. That put a 240fps
/// capture session and a decision in front of somebody at the same moment, and
/// the decision lost. Here the camera is not even running yet — there is
/// nothing to get wrong, and exactly one thing to do.
///
/// The mode question is asked first because it is the one thing the app cannot
/// work out for itself, and it changes what the analysis should expect: off a
/// tee there is one ball path in the clip and anything opposing it is clutter;
/// off live pitching there are two and they meet at contact.
struct StartView: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: SessionMode = .live
    enum StartSheet: String, Identifiable {
        case library, settings
        var id: String { rawValue }
    }
    @State private var sheet: StartSheet?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        // Three panels, and there is no fourth. Mode, start,
                        // and everything that is not this session. The screen
                        // used to carry seven tappable rectangles — three mode
                        // cards, the slab, the library row and two outline
                        // buttons — which is a menu, not a decision, and the
                        // decision is the only thing this screen is for.
                        modePicker
                        startButton
                        // Always shown, empty or not. When it was conditional
                        // on having swings, a fresh install had no route to the
                        // history screen at all — and the history screen is
                        // where importing a clip lives, which is the one thing
                        // somebody with no swings yet is most likely to want.
                        library
                        Spacer(minLength: 8)
                        footer
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheet = .settings } label: {
                        Image(systemName: "gearshape").foregroundStyle(Theme.steel)
                    }
                }
            }
            // No NavigationStack wrappers: each of these already carries one,
            // and nesting them gives two title bars and a back button that
            // goes nowhere.
            // ONE sheet modifier. Stacking four on a view is not something
            // SwiftUI reliably honours — the later ones win and the earlier
            // ones silently do nothing, which presents as a button that does
            // not respond and nothing in the code to explain it.
            //
            // `isModal` on the first three: presented as sheets there is no tab
            // bar to leave by, and these screens had no Done button of their
            // own — a swipe-down was the only way out and nothing said so.
            .sheet(item: $sheet) { which in
                switch which {
                case .library:  LibraryView()
                case .settings: SettingsView(isModal: true)
                }
            }
        }
        .tint(Theme.yellow)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SWINGLAB")
                .font(Theme.numeral(34))
                .foregroundStyle(Theme.yellow)
                .tracking(2)
            Text("Set the phone side-on, then hit.")
                .font(.subheadline)
                .foregroundStyle(Theme.steel)
        }
    }

    /// One panel, not one per mode.
    ///
    /// Three radio cards spent the top half of the screen restating a question
    /// whose answer is the same on most days — and made the three modes look
    /// like three things to weigh up rather than one setting with a value. A
    /// menu says the same thing in a line and puts the choice one tap away,
    /// which is the right price for a decision that is usually already made.
    ///
    /// The question stays *inside* the panel. Dropped, this stops reading as a
    /// decision and starts reading as a preference someone else set.
    private var modePicker: some View {
        Menu {
            // A `Picker` rather than three `Button`s: it draws the tick beside
            // the current mode itself, so the menu says which one is selected
            // without a second source of truth for that.
            Picker("How is the ball coming in", selection: $mode) {
                ForEach(SessionMode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(m)
                }
            }
        } label: {
            ModeCard(mode: mode)
        }
    }

    private var startButton: some View {
        VStack(spacing: 10) {
            Button("Start session") { model.startSession(mode: mode) }
                .buttonStyle(SlabButtonStyle(size: 19, verticalPadding: 20))
            Text("Next: frame the hitter and tap the ball once. The camera does not start until then.")
                .font(.caption)
                .foregroundStyle(Theme.steel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var library: some View {
        LibraryPanel(swingCount: model.swings.count) { sheet = .library }
    }

    /// The standing caveat, on the screen every session starts from.
    ///
    /// It is here rather than buried in an About box because the project's own
    /// rule (`docs/BIOMECHANICS.md`) is that a number nobody can stand behind
    /// must never look like every other number — and right now that applies to
    /// all of them. `docs/VALIDATION.md` is empty. When it is not, this line
    /// changes; until then it stays where it cannot be missed.
    private var footer: some View {
        Text("Nothing here is validated yet. The tracker follows the ball, but no reading has been checked against a known truth — treat every number as provisional.")
            .font(.caption2)
            .foregroundStyle(Theme.steel.opacity(0.8))
    }
}

/// The mode panel's face, split out from the `Menu` that wraps it.
///
/// Its own type because `ImageRenderer` does not draw a `Menu`'s label, and
/// this is the one panel on the screen whose layout is worth looking at
/// without a phone. Rendering the card directly is the whole picture minus the
/// menu's own chrome.
struct ModeCard: View {
    var mode: SessionMode

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("HOW IS THE BALL COMING IN")
                    .font(Theme.label(10)).tracking(1.2)
                    .foregroundStyle(Theme.steel)
                Text(mode.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(mode.blurb)
                    .font(.caption).foregroundStyle(Theme.steel)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.yellow)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        // Outlined, unlike the panel below it. This one is the only thing on
        // the screen holding a value, and the outline is what says so.
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.yellow.opacity(0.75), lineWidth: 1.5))
        .foregroundStyle(.white)
    }
}

/// The third panel: one row, one destination.
///
/// It used to be a row plus two outline buttons, and the buttons appeared only
/// once there were swings — so the route to a round you had already started was
/// invisible on precisely the screen you would look for it from, the first time
/// you looked. Swings, rounds and trends are three views of the same history,
/// so they are three pages behind one row rather than three rectangles on the
/// screen you start a session from. See `LibraryView`.
struct LibraryPanel: View {
    var swingCount: Int
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(swingCount == 0
                         ? "Swings & imports"
                         : "\(swingCount) swing\(swingCount == 1 ? "" : "s") recorded")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    // Names all three pages, because this row is now the only
                    // thing on the screen that says they exist.
                    Text(swingCount == 0
                         ? "Import a clip, or look at past rounds and trends"
                         : "Review and export, past rounds, trends")
                        .font(.caption).foregroundStyle(Theme.steel)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Theme.steel)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
