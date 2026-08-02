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
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}
