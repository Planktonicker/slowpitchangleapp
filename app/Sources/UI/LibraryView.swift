// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Everything that is not the round you are hitting right now: the swings you
/// have recorded, the rounds you have finished, and your numbers over time.
///
/// One destination with three pages rather than three destinations. They were
/// three separate sheets off the start screen, which made them look like three
/// unrelated features and put a return trip to the start screen between any two
/// of them — you cannot look at a trend and then at the round that made it
/// without going back out and in again. They are three views of the same
/// history, so they are three pages of one screen.
///
/// Pages, not a plain `TabView`: the stock iPhone tab bar does not swipe, and
/// swiping between three adjacent views of the same data is the gesture people
/// try first.
///
/// Each page keeps its own `NavigationStack`, so its title, its toolbar and its
/// pushes all still work — which is why the switcher is a bar at the bottom
/// rather than a segmented control in a shared header. There is no shared
/// header to put one in without gutting all three screens.
struct LibraryView: View {
    enum Page: String, CaseIterable, Identifiable {
        case swings, rounds, trends
        var id: String { rawValue }
        var title: String {
            switch self {
            case .swings: return "Swings"
            case .rounds: return "Rounds"
            case .trends: return "Trends"
            }
        }
    }

    /// Which page to open on. The start screen's panel names the swing count,
    /// so that is where a tap on it should land; a caller with a different
    /// reason can say so.
    var start: Page = .swings
    @State private var page: Page = .swings

    var body: some View {
        TabView(selection: $page) {
            HistoryView(isModal: true).tag(Page.swings)
            RoundsView().tag(Page.rounds)
            TrendsView(isModal: true).tag(Page.trends)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // `safeAreaInset`, not an overlay. An overlay sits ON the last row of
        // a list and there is no way to scroll past it; an inset shortens the
        // scrollable area, which is what a tab bar is supposed to do.
        .safeAreaInset(edge: .bottom, spacing: 0) { switcher }
        .onAppear { page = start }
    }

    private var switcher: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.steel.opacity(0.22)).frame(height: 1)
            Picker("Section", selection: $page) {
                ForEach(Page.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(.bar)
    }
}
