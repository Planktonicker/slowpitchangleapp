// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Pro's one extra question before the app you already know: one phone or
/// two? Solo hands over to the entire existing SwingLab — same screens, same
/// pipeline, byte-for-byte behavior — which is the point: every Solo session
/// on this target is a regression test of the shared tree. Linked is the
/// multi-phone mode, arriving in the order docs/SWINGLAB_PRO.md lays out.
struct ProRootView: View {
    @ObservedObject var model: AppModel
    @State private var mode: Mode? = nil

    enum Mode: Hashable { case solo, linked }

    var body: some View {
        switch mode {
        case .solo:
            RootView().environmentObject(model)
        case .linked:
            ProLinkedPlaceholderView { mode = nil }
        case nil:
            chooser
        }
    }

    private var chooser: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 6) {
                Text("SwingLab Pro")
                    .font(.largeTitle.bold())
                Text("One swing, measured from two phones.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Button {
                    mode = .solo
                } label: {
                    modeLabel(title: "Solo",
                              subtitle: "The full single-phone SwingLab you already trust.",
                              systemImage: "iphone")
                }

                Button {
                    mode = .linked
                } label: {
                    modeLabel(title: "Linked (2 phones)",
                              subtitle: "Sync a second phone for true 3D. In development.",
                              systemImage: "iphone.and.arrow.left.and.arrow.right")
                }
            }
            .padding(.horizontal, 24)

            Spacer()
            Text("Linked capture ships in stages — see docs/SWINGLAB_PRO.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
    }

    private func modeLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
    }
}

/// Honest about what exists: the linked mode is a ladder of proofs, not a
/// switch to flip, and this screen names the rungs so nobody mistakes a
/// scaffold for a feature. Replaced by the real link-setup flow in P4.
struct ProLinkedPlaceholderView: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Linked capture is not built yet")
                .font(.title2.bold())
            Text("It arrives in proven stages, each with a gate it must pass first:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stage("P1", "Clock sync between two phones — bench-proven to about a millisecond.")
                stage("P2", "Calibration: the phones learn where they stand, using the ball itself.")
                stage("P3", "3D reconstruction, validated against known geometry and gravity.")
                stage("P4", "The linked session: pair, arm, swing, results on the master phone.")
                stage("P5", "Rotation metrics — labelled experimental until field-validated.")
            }
            .font(.subheadline)

            Text("The design, budgets and gates live in docs/SWINGLAB_PRO.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Back") { done() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .tint(Theme.yellow)
        .preferredColorScheme(.dark)
    }

    private func stage(_ tag: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tag)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
            Text(text)
        }
    }
}
