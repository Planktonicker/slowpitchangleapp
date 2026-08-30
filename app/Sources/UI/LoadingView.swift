// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Shown while something slow is happening that cannot be made fast.
///
/// Two things in this app take real time and neither is a bug to be optimised
/// away. Opening the swing database reads and maps every stored record. Starting
/// capture negotiates a 240fps format with the camera hardware, which takes as
/// long as it takes — a second or two on a good day.
///
/// Both used to happen behind a screen that looked finished: a blank window at
/// launch, a black viewfinder on entering a round. A screen that looks ready and
/// does not respond reads as a broken app; the same wait behind a screen that
/// says what it is doing reads as a working one. So this says the specific
/// thing, not "Loading…" — when it does take a while, the hitter can tell
/// whether the wait is about their swings or about the camera.
struct LoadingView: View {
    var title: String
    var detail: String?

    var body: some View {
        ZStack {
            Theme.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("SWINGLAB")
                    .font(Theme.numeral(30))
                    .foregroundStyle(Theme.yellow)
                    .tracking(2)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.yellow)
                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.steel)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The same thing over a live screen, for a wait that ends with the view behind
/// it becoming usable rather than being replaced.
struct LoadingScrim: View {
    var title: String
    var detail: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().progressViewStyle(.circular).tint(Theme.yellow)
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.steel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)
                }
            }
        }
        .transition(.opacity)
    }
}
