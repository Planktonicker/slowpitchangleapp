// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// The capture screen's heads-up display, built as a broadcast score bug.
///
/// The screen this replaces put eleven small readouts in two rails and left the
/// user to infer the state from them — the field report was "very clouded, I
/// cannot tell what is happening". The rules here are the opposite:
///
///  * **One fixed address.** State lives in one place, bottom-left, always the
///    same size and shape, so the eye learns one spot and checks it in a glance.
///  * **Stop rendering the normal case.** No "240fps" chip when it is 240, no
///    "hitter in frame" when there is one. The ribbon is empty when all is
///    well — which is what makes something appearing there mean anything.
///  * **State is carried by the bug alone.** An earlier version also drew a
///    dashed perimeter around the whole screen; it clipped at the edges, fought
///    the tab bar and read as noise rather than signal. One bold, solid, legible
///    tile beats a border that has to dodge every rounded corner and notch.
///  * **The middle stays clear.** That band is where the hitter and the ball
///    are, and it is what the user is actually judging.

// MARK: - State

/// What the capture screen is doing, in strict precedence order. Deriving this
/// in one place matters: a HUD that lies about the state is worse than the
/// cluttered one it replaces.
enum HUDState: Equatable {
    // No `needsSetup` case: setup stopped being a precondition when the
    // measurement stopped needing a distance, and a state no producer can
    // reach leaves branches that read as tunable and can never run.
    case starting
    case interrupted
    case ready
    case armed
    case recording
    case analysing

    var word: String {
        switch self {
        case .starting: return "Wait"
        case .interrupted: return "Paused"
        case .ready: return "Ready"
        case .armed: return "Armed"
        case .recording: return "Rec"
        case .analysing: return "Working"
        }
    }

    var symbol: String {
        switch self {
        case .starting: return "camera.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle.fill"
        case .armed: return "dot.radiowaves.left.and.right"
        case .recording: return "record.circle.fill"
        case .analysing: return "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .starting: return Theme.surface
        case .interrupted: return Theme.fail
        case .ready, .armed, .analysing: return Theme.yellow
        case .recording: return Theme.fail
        }
    }

    var onTint: Color {
        switch self {
        case .starting: return Theme.steel
        case .interrupted, .recording: return .white
        default: return .black
        }
    }

    /// True where the state word needs to be readable from the batter's box
    /// rather than from arm's length.
    var isLoud: Bool { self == .armed || self == .recording }
}

// MARK: - Score bug

/// State, at one fixed address. Tile carries the glyph and the word; the
/// readout carries the one number that matters in this state.
struct ScoreBug: View {
    var state: HUDState
    var label: String
    var value: String
    /// Optional qualifier beside the label, e.g. GOOD / OK / MOVE.
    var qualifier: (text: String, color: Color)?
    var subline: String?
    /// Shared with the buttons beside it. A row only reads as a row when every
    /// piece in it is the same height.
    var height: CGFloat = 60
    var onTap: () -> Void

    /// Narrowest this can be drawn with the readout still legible.
    ///
    /// Published because the control column above it is sized as a fraction
    /// of the screen, and a `maxWidth` on an ancestor cannot compress a
    /// stated `minWidth` — asking for less than this does not make the bug
    /// smaller, it makes it overhang the very edge the column exists to
    /// create. The caller takes the larger of the two.
    static func minWidth(height: CGFloat) -> CGFloat {
        tileWidth(height: height) + readoutMinWidth + readoutPadding * 2
    }

    /// Wider than tall: the tile has no horizontal padding, and at a bare
    /// square "WORKING" ran edge to edge and scaled itself down rather than
    /// fitting at the size it asks for.
    private static func tileWidth(height: CGFloat) -> CGFloat { max(height + 8, 64) }
    private static let readoutMinWidth: CGFloat = 116
    private static let readoutPadding: CGFloat = 10

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 19, weight: .semibold))
                    Text(state.word.uppercased())
                        .font(Theme.label(10))
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(state.onTint)
                .frame(width: Self.tileWidth(height: height), height: height)
                .background(state.tint)

                VStack(alignment: .leading, spacing: 0) {
                    if state.isLoud {
                        Text(state.word.uppercased())
                            .font(Theme.numeral(23))
                            .foregroundStyle(.white)
                        if let subline {
                            Text(subline)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.steel)
                                // Two lines, then truncate. The readout's
                                // height is pinned to the row, so a third line
                                // is not wrapped, it is clipped — and the
                                // longest real subline is a mode title plus
                                // "· no swings yet", which reaches three lines
                                // in the narrow column.
                                .lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 5) {
                            Text(label.uppercased())
                                .font(Theme.label(9)).tracking(1.1)
                                .foregroundStyle(Theme.steel)
                            if let qualifier {
                                Text(qualifier.text.uppercased())
                                    .font(Theme.label(9)).tracking(0.7)
                                    .foregroundStyle(qualifier.color)
                            }
                        }
                        Text(value)
                            .font(Theme.numeral(value.count > 6 ? 17 : 29))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Flexible, not fixed. The tile sits in a row with the action
                // buttons and, in portrait, above them — and a fixed width
                // left it stopping two thirds of the way across while
                // everything below it ran to the edge. A ragged right edge is
                // most of what made this screen look unconsidered. The minimum
                // keeps the readout from being squeezed to nothing when it
                // shares a landscape row; see `minWidth(height:)`.
                .frame(minWidth: Self.readoutMinWidth, maxWidth: .infinity,
                       minHeight: height, maxHeight: height, alignment: .leading)
                .padding(.horizontal, Self.readoutPadding)
                .background(.black.opacity(0.86))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.word). \(label) \(value)")
    }
}

// MARK: - Exception ribbon

/// Nothing here when everything is normal. That emptiness is the feature: it
/// is what lets a single amber chip mean "look at me".
struct ExceptionRibbon: View {
    var chips: [(text: String, symbol: String, color: Color)]
    var onChipTap: () -> Void
    /// Controls that are available in every state, pinned top-right. Anything
    /// that must never become unreachable belongs here rather than in the
    /// bottom row, which changes shape with the state.
    var trailing: AnyView
    /// Portrait puts the controls on their own line above the chips.
    var isLandscape: Bool

    var body: some View {
        // One row when there is width for one. In portrait there is not: the
        // controls take ~230 of a 361pt line, and the chips — which had the
        // lower layout priority, correctly, since a control squeezed to an
        // ellipsis has stopped being one — were left showing "⚠ 1…", three
        // times over. A chip that cannot say its number is not a smaller
        // warning, it is no warning at all.
        if isLandscape {
            HStack(alignment: .top, spacing: 6) {
                chipRow
                Spacer(minLength: 0)
                trailing
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) { Spacer(minLength: 0); trailing }
                chipRow
            }
        }
    }

    private var chipRow: some View {
        ChipFlow {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button(action: onChipTap) {
                    HStack(spacing: 4) {
                        Image(systemName: chip.symbol).font(.system(size: 11, weight: .bold))
                        if !chip.text.isEmpty {
                            Text(chip.text.uppercased())
                                .font(Theme.label(11))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(chip.color.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Left-aligned chips that wrap to a new line rather than shrink.
///
/// An `HStack` has one answer when its children do not fit — compress them —
/// and for a status chip that answer is wrong: the chip's whole content is a
/// number and a cause, and the first thing compression takes is the number.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    /// Negative on purpose. Each chip carries a 44pt touch target around a
    /// 26pt capsule, so stacking rows at their full height leaves an 18pt
    /// canyon between two pills. Pulling the rows together sets the visual
    /// gap instead, and the targets that then overlap belong to buttons that
    /// all do the same thing — open the status sheet — so a tap landing in
    /// the overlap is correct either way.
    var lineSpacing: CGFloat = -12

    private func layout(_ subviews: Subviews, width: CGFloat,
                        place: ((LayoutSubview, CGPoint, CGSize) -> Void)?) -> CGSize {
        var x: CGFloat = 0, y: CGFloat = 0
        var rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            place?(view, CGPoint(x: x, y: y), size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: max(widest, x - spacing), height: y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return layout(subviews, width: proposal.width ?? .infinity, place: nil)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        _ = layout(subviews, width: bounds.width) { view, origin, size in
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                       proposal: ProposedViewSize(size))
        }
    }
}

// MARK: - Seam meter

/// Contact level, drawn on the seam between video and chrome so it costs no
/// layout. "Past the notch" is the meaning; colour only reinforces it.
struct SeamMeter: View {
    var db: Double
    var thresholdDb: Double

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width
            let fraction = max(0, min(1, db / max(1, thresholdDb * 1.5)))
            let notch = full / 1.5
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(db >= thresholdDb ? Theme.pass : Theme.yellow)
                    .frame(width: full * fraction)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: notch)
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }
}
