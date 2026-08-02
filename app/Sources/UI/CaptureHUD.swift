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
///  * **State is carried three ways.** Frame colour *and* pattern *and* a word,
///    so it survives glare, distance and colour blindness.
///  * **The middle stays clear.** That band is where the hitter and the ball
///    are, and it is what the user is actually judging.

// MARK: - State

/// What the capture screen is doing, in strict precedence order. Deriving this
/// in one place matters: a HUD that lies about the state is worse than the
/// cluttered one it replaces.
enum HUDState: Equatable {
    case starting
    case interrupted
    case needsSetup
    case ready
    case armed
    case recording
    case analysing

    var word: String {
        switch self {
        case .starting: return "Wait"
        case .interrupted: return "Paused"
        case .needsSetup: return "Set up"
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
        case .needsSetup: return "viewfinder"
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
        case .needsSetup, .ready, .armed, .analysing: return Theme.yellow
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

// MARK: - Perimeter frame

/// The loudest state signal in the app, and it costs no interior space.
///
/// Colour alone is never the carrier: each state also has its own line weight
/// and pattern. Armed is a yellow/black hazard stripe rather than green —
/// pattern reads at a distance where hue has washed out, and it keeps the pass
/// green reserved for things that actually passed.
struct StateFrame: View {
    var state: HUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(style: strokeStyle)
                    .foregroundStyle(state.tint.opacity(state == .starting ? 0.4 : 0.9))
                    .opacity(state == .recording && !reduceMotion ? (pulse ? 1.0 : 0.55) : 1.0)
                brackets(in: geo.size)
            }
            .padding(10)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard state == .recording, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: state) { _, new in
            pulse = false
            guard new == .recording, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var lineWidth: CGFloat {
        switch state {
        case .starting: return 3
        case .needsSetup, .ready: return 5
        case .armed: return 7
        case .analysing, .interrupted: return 6
        case .recording: return 10
        }
    }

    private var strokeStyle: StrokeStyle {
        switch state {
        case .needsSetup:
            return StrokeStyle(lineWidth: lineWidth, dash: [16, 10])
        case .interrupted:
            return StrokeStyle(lineWidth: lineWidth, dash: [10, 8])
        case .armed:
            // Reads as a hazard stripe at distance without needing an image
            // paint: short dashes on a heavy line.
            return StrokeStyle(lineWidth: lineWidth, dash: [14, 8])
        default:
            return StrokeStyle(lineWidth: lineWidth)
        }
    }

    /// Chunky corner mass is the part that reads from twenty feet.
    private func brackets(in size: CGSize) -> some View {
        let leg: CGFloat = 64
        let w = lineWidth + 1
        return ZStack {
            ForEach(0..<4, id: \.self) { corner in
                Path { p in
                    let isRight = corner == 1 || corner == 2
                    let isBottom = corner >= 2
                    let x = isRight ? size.width - 10 : 10
                    let y = isBottom ? size.height - 10 : 10
                    p.move(to: CGPoint(x: x + (isRight ? -leg : leg), y: y))
                    p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + (isBottom ? -leg : leg)))
                }
                .stroke(state.tint.opacity(state == .starting ? 0.4 : 1.0),
                        style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }
    }
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
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 24, weight: .semibold))
                    Text(state.word.uppercased())
                        .font(Theme.label(12))
                        .tracking(1.0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(state.onTint)
                .frame(width: 74, height: 74)
                .background(state.tint)

                VStack(alignment: .leading, spacing: 0) {
                    if state.isLoud {
                        Text(state.word.uppercased())
                            .font(Theme.numeral(28))
                            .foregroundStyle(.white)
                        if let subline {
                            Text(subline)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.steel)
                        }
                    } else {
                        HStack(spacing: 5) {
                            Text(label.uppercased())
                                .font(Theme.label(10)).tracking(1.2)
                                .foregroundStyle(Theme.steel)
                            if let qualifier {
                                Text(qualifier.text.uppercased())
                                    .font(Theme.label(10)).tracking(0.8)
                                    .foregroundStyle(qualifier.color)
                            }
                        }
                        Text(value)
                            .font(Theme.numeral(value.count > 6 ? 20 : 36))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 178, height: 74, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.86))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
    var setting: String
    var onChipTap: () -> Void
    var settingMenu: AnyView

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
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
            Spacer(minLength: 0)
            settingMenu
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
