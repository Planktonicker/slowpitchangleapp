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
    @State private var showSwings = false
    @State private var showSettings = false
    @State private var showTrends = false
    @State private var showValidation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        modePicker
                        startButton
                        // Always shown, empty or not. When it was conditional
                        // on having swings, a fresh install had no route to the
                        // history screen at all — and the history screen is
                        // where importing a clip lives, which is the one thing
                        // somebody with no swings yet is most likely to want.
                        library
                        if !model.swings.isEmpty { betweenSessions }
                        Spacer(minLength: 8)
                        footer
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(Theme.steel)
                    }
                }
            }
            // No NavigationStack wrappers: each of these already carries one,
            // and nesting them gives two title bars and a back button that
            // goes nowhere.
            .sheet(isPresented: $showSwings) { HistoryView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showTrends) { TrendsView() }
            .sheet(isPresented: $showValidation) { ValidationView() }
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

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW IS THE BALL COMING IN")
                .font(Theme.label(11)).tracking(1.3)
                .foregroundStyle(Theme.steel)
            ForEach(SessionMode.allCases) { m in
                Button { mode = m } label: {
                    HStack(spacing: 14) {
                        Image(systemName: m.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(m.blurb)
                                .font(.caption)
                                .foregroundStyle(Theme.steel)
                        }
                        Spacer()
                        Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(mode == m ? Theme.yellow : Theme.steel)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(mode == m ? Theme.yellow : .clear, lineWidth: 2))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
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
        Button { showSwings = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.swings.isEmpty
                         ? "Swings & imports"
                         : "\(model.swings.count) swing\(model.swings.count == 1 ? "" : "s") recorded")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(model.swings.isEmpty
                         ? "Import a clip you already filmed and measure it"
                         : "Review, export, re-measure, or import a clip")
                        .font(.caption).foregroundStyle(Theme.steel)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.steel)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// Trends and Validation, which are things you read BETWEEN rounds. They
    /// used to be tabs, which put them one tap from a hitter mid-session and
    /// four taps of clutter around the two screens that matter there.
    private var betweenSessions: some View {
        HStack(spacing: 12) {
            Button("Trends") { showTrends = true }
                .buttonStyle(OutlineButtonStyle())
            Button("Validation") { showValidation = true }
                .buttonStyle(OutlineButtonStyle())
        }
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
