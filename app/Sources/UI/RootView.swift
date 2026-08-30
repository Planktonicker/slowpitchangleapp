// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Two states, not five tabs: either a round is in progress or it is not.
///
/// The app used to open straight onto a live 240fps viewfinder with five tabs
/// under it, and the thing that had to happen first — setting the camera up —
/// was the smallest control on the busiest screen. Now the camera does not
/// exist until somebody has said what they are about to do, and while they are
/// doing it the app shows them two screens instead of five.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.capture

    enum Tab: Hashable { case capture, history, settings }

    var body: some View {
        Group {
            if model.isInSession {
                sessionTabs
            } else {
                StartView()
            }
        }
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
        // Always land on the viewfinder when a round starts, whatever tab the
        // last one ended on.
        .onChange(of: model.isInSession) { _, inSession in
            if inSession { tab = .capture }
        }
        .sheet(item: $model.finishedSession) { summary in
            SessionSummaryView(summary: summary) { model.finishedSession = nil }
                .environmentObject(model)
        }
        // A safe-area inset, not an overlay. The banner draws on top of
        // whatever is showing, so every screen it can cover has to move out of
        // its way — and an overlay does not tell them to. Guessing the offset
        // instead does not work either: the banner's height depends on how long
        // the message is, and a fixed step-down that is right for one line
        // covers the exception chips and the setup overlay's close button when
        // it wraps to two. This reserves the height the banner actually
        // measures, so both screens step down by exactly the right amount.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        // Hosted here rather than on the importing screen, because there are
        // three ways in now — the Files picker, the Photos picker, and the
        // history sheet on the start screen — and all of them dismiss
        // themselves before the analysis starts.
        .alert("That is a long clip",
               isPresented: Binding(get: { model.longClipPrompt != nil },
                                    set: { if !$0 { model.longClipPrompt = nil } }),
               presenting: model.longClipPrompt) { prompt in
            Button("Measure it anyway") {
                model.longClipPrompt = nil
                model.beginAnalysis(of: prompt.url)
            }
            Button("Cancel", role: .cancel) { model.longClipPrompt = nil }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var sessionTabs: some View {
        TabView(selection: $tab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(Tab.capture)

            HistoryView()
                .tabItem { Label("This round", systemImage: "list.bullet") }
                .tag(Tab.history)

            // Trends and Validation are not in the round's tab bar. Both are
            // read between sessions, neither has an answer that changes while
            // you are standing at the plate, and on the field they were two
            // taps of clutter around the two screens that matter. They live on
            // the start screen instead.
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
