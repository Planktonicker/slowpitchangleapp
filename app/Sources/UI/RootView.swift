// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.capture

    enum Tab: Hashable { case capture, history, trends, validation, settings }

    var body: some View {
        TabView(selection: $tab) {
            CaptureView()
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(Tab.capture)

            HistoryView()
                .tabItem { Label("Swings", systemImage: "list.bullet") }
                .tag(Tab.history)

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(Tab.trends)

            ValidationView()
                .tabItem { Label("Validation", systemImage: "checkmark.seal") }
                .tag(Tab.validation)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
        // A safe-area inset, not an overlay. The banner draws on top of
        // whatever tab is showing, so every screen it can cover has to move out
        // of its way — and an overlay does not tell them to. Guessing the
        // offset instead does not work either: the banner's height depends on
        // how long the message is, and a fixed step-down that is right for one
        // line covers the exception chips and the setup overlay's close button
        // when it wraps to two. This reserves the height the banner actually
        // measures, so both screens step down by exactly the right amount.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}
