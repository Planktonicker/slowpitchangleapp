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
            ProLinkedView { mode = nil }
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

/// Honest about what exists. P1 is real and testable — the sync bench below
/// runs on two phones today. The rest are named so nobody mistakes a
/// scaffold for a feature.
struct ProLinkedView: View {
    let done: () -> Void
    @State private var showBench = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Linked capture")
                .font(.title2.bold())

            Button {
                showBench = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync bench").font(.headline)
                        Text("P1 — pair two phones, measure the clock offset, check it against a clap.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.10)))
            }

            Text("Still to come, each gated on the one before:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stage("P2", "Calibration: the phones learn where they stand, using the ball itself.")
                stage("P3", "3D reconstruction on the phone, validated against gravity.")
                stage("P4", "The linked session: pair, arm, swing, results on the master phone.")
                stage("P5", "Rotation metrics — labelled experimental until field-validated.")
            }
            .font(.subheadline)

            Text("Today the 3D maths runs offline on a Mac: spike/multiview_lab.py, with docs/PRO_FIELD_GUIDE.md for what to film.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Back") { done() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showBench) { SyncBenchView() }
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
