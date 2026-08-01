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

/// Confidence summary for a swing: either "high" or the flags that spoiled it.
struct ConfidenceRow: View {
    var flags: [SwingFlag]

    var body: some View {
        if flags.isEmpty {
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
    }
}

/// Transient message bar.
struct BannerView: View {
    var banner: AppModel.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(banner.text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(tint)
        .padding(.horizontal)
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
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
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
