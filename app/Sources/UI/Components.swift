// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// A single big number with its unit and label.
struct MetricTile: View {
    var label: String
    var value: String
    var unit: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colour.opacity(0.18), in: Capsule())
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
        case .some(true): return .green
        case .some(false): return .red
        case nil: return .secondary
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
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
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
                .font(.caption)
                .foregroundStyle(.green)
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
