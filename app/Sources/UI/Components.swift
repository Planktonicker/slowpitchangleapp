// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UIKit

/// A single scoreboard number with its unit and label. Loud on purpose —
/// these get read from twenty feet away in sunlight.
struct MetricTile: View {
    var label: String
    var value: String
    var unit: String
    var tint: Color = Theme.yellow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(Theme.label(10))
                .tracking(1.2)
                .foregroundStyle(Theme.steel)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.numeral(38))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(unit)
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.steel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pass/fail/unknown badge for a validation gate.
struct GateBadge: View {
    var passes: Bool?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colour.opacity(0.2), in: Capsule())
            .overlay(Capsule().strokeBorder(colour.opacity(0.7), lineWidth: 1))
            .foregroundStyle(colour)
    }

    private var text: String {
        switch passes {
        case .some(true): return "PASS"
        case .some(false): return "FAIL"
        case nil: return "—"
        }
    }

    private var colour: Color {
        switch passes {
        case .some(true): return Theme.pass
        case .some(false): return Theme.fail
        case nil: return Theme.steel
        }
    }
}

/// One confidence flag, with the plain-language reason behind it.
struct FlagChip: View {
    var flag: SwingFlag
    @State private var showExplanation = false

    var body: some View {
        Button {
            showExplanation.toggle()
        } label: {
            Text(flag.rawValue.replacingOccurrences(of: "_", with: " ").lowercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.warn.opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.warn)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showExplanation) {
            Text(flag.explanation)
                .font(.callout)
                .padding()
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// One capture-condition flag — the camera's state rather than the
/// measurement's. Same look as `FlagChip`, different source.
struct CaptureFlagChip: View {
    var flag: CaptureFlag
    @State private var showExplanation = false

    var body: some View {
        Button {
            showExplanation.toggle()
        } label: {
            Text(flag.shortLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.steel.opacity(0.22), in: Capsule())
                .foregroundStyle(Theme.steel)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showExplanation) {
            Text(flag.explanation)
                .font(.callout)
                .padding()
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Confidence summary for a swing: either "high" or the flags that spoiled it.
///
/// Two independent sources. `flags` come from the measurement itself and are
/// pinned to the Python reference; `captureFlags` describe the conditions the
/// camera was in. Levelling stopped blocking capture, so the second group is
/// what keeps an off-level reading honest rather than merely absent.
struct ConfidenceRow: View {
    var flags: [SwingFlag]
    var captureFlags: [CaptureFlag] = []

    var body: some View {
        if flags.isEmpty && captureFlags.isEmpty {
            Label("High confidence", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.pass)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { chips }
                VStack(alignment: .leading, spacing: 4) { chips }
            }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(flags, id: \.self) { FlagChip(flag: $0) }
        ForEach(captureFlags, id: \.self) { CaptureFlagChip(flag: $0) }
    }
}

/// Transient message bar.
///
/// Opaque, not tinted glass. It sits over the live camera preview, and a 15%
/// wash let the video and the HUD chips read straight through it — the top of
/// the capture screen became an unreadable pile. It also clears itself: a
/// warning that has to be dismissed by hand is a warning that stays on screen
/// covering the picture long after it stopped being news. Errors stay, because
/// those the user has to actually see.
struct BannerView: View {
    var banner: AppModel.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
            Text(banner.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Theme.steel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.8), lineWidth: 1.5))
        .frame(maxWidth: 620)
        .padding(.horizontal, 12)
        // The whole bar dismisses, not a 12pt glyph. It lives over a camera
        // preview whose taps mean "measure the ball here", so it has to be
        // easy to get rid of and impossible to miss.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .task(id: banner.id) {
            guard banner.kind != .error else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return Theme.yellow
        case .warning: return Theme.warn
        case .error: return Theme.fail
        }
    }
}

/// Wraps an array of file URLs for the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
