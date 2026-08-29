// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UIKit

/// The import report, with one job beyond being read: getting off the phone.
///
/// A clip is hundreds of megabytes and cannot be sent anywhere. This is a few
/// hundred bytes of the same information — which stage of the pipeline saw
/// what — and it is the artefact that makes a failure diagnosable by somebody
/// who is not holding the phone. So Copy and Share are the primary actions,
/// not an afterthought at the bottom.
struct DiagnosticsView: View {
    let report: String
    /// The clip this report came from, when it is still around. Offered here
    /// because this sheet is where somebody is already looking at a failure and
    /// wondering what the camera actually saw.
    var clipURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showFrames = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    // Monospaced and unwrapped: the report is a small table,
                    // and reflowing it turns aligned columns into prose.
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Theme.black)
            .navigationTitle("Clip diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(SlabButtonStyle(size: 15))

                    ShareLink(item: report) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OutlineButtonStyle())

                    if clipURL != nil {
                        Button { showFrames = true } label: {
                            Label("Frames", systemImage: "photo.stack")
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
            .sheet(isPresented: $showFrames) {
                if let clipURL { FramePickerView(clipURL: clipURL) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
