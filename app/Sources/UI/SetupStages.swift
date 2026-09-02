// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// The pieces of the setup screen, one per stage.
///
/// Split out of `SetupOverlay` because that file had grown to 1142 lines by
/// accretion — every field trip added an indicator — and ended up drawing the
/// camera's tilt six different ways at once. The rule here is one instrument
/// per stage: the horizon line and the roll beam belong to LEVEL, the outline
/// and the sampling counter to HITTER, and the summary rows to ARM.

// MARK: - Header

/// Close, where you are, mirror, help. No title: the stepper says where you are
/// better than a heading does, and the "Hitter detected" chip that used to live
/// here is now a row on the Ready stage, where it is read as a check before
/// arming rather than as decoration.
struct SetupHeader: View {
    var stage: PlacementWizard.SetupStage
    var onSelect: (PlacementWizard.SetupStage) -> Void
    var onClose: () -> Void
    var onMirror: () -> Void
    var onHelp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            circleButton("xmark", tint: .white, action: onClose)
            Spacer(minLength: 0)
            StageStepper(stage: stage, onSelect: onSelect)
            Spacer(minLength: 0)
            circleButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                         tint: .white, size: 13, action: onMirror)
            circleButton("questionmark", tint: Theme.yellow, action: onHelp)
        }
    }

    private func circleButton(_ symbol: String, tint: Color, size: CGFloat = 15,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .heavy))
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(tint)
        }
    }
}

/// Three tappable segments. Tappable because the stages are ordered but not
/// locked — somebody who wants to re-level after measuring should not have to
/// walk backwards through the screen to do it.
struct StageStepper: View {
    var stage: PlacementWizard.SetupStage
    var onSelect: (PlacementWizard.SetupStage) -> Void

    var body: some View {
        HStack(spacing: 6) {
            segment(.level, "1 LEVEL")
            segment(.hitter, "2 HITTER")
            segment(.ready, "3 ARM")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func segment(_ which: PlacementWizard.SetupStage, _ title: String) -> some View {
        let isDone = which.rawValue < stage.rawValue
        let isCurrent = which == stage
        let tint: Color = isCurrent ? Theme.yellow : (isDone ? Theme.pass : Theme.steel)
        return Button { onSelect(which) } label: {
            HStack(spacing: 3) {
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .black))
                }
                Text(title).font(Theme.label(10)).tracking(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isCurrent ? tint.opacity(0.18) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level

/// Roll as a ball on a beam.
///
/// Coloured by roll alone, deliberately **not** by `isLevel`. That property
/// latches tilt as well, so colouring the beam with it would make the beam a
/// second tilt reading — and the horizon line drawn on the picture is already
/// the tilt reading. One instrument, one quantity.
struct RollBeam: View {
    var rollDeg: Double
    var isRollOK: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.55))
                .frame(height: 26)
            Capsule()
                .strokeBorder(isRollOK ? Theme.pass : .white.opacity(0.35), lineWidth: 1.5)
                .frame(height: 26)
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 2, height: 16)
            Circle()
                .fill(isRollOK ? Theme.pass : Theme.warn)
                .frame(width: 18, height: 18)
                .offset(x: max(-1, min(1, rollDeg / 8)) * 120)
                .animation(.easeOut(duration: 0.12), value: rollDeg)
        }
        .frame(maxWidth: 280)
        .allowsHitTesting(false)
    }
}

/// One line and one button. The angle is not repeated here: it is on the
/// horizon line, drawn where level actually falls in the picture, which is the
/// same reading in the units the eye is already using.
struct LevelStagePanel: View {
    var isLevel: Bool
    var onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aim so the dashed line sits in the green band, and keep the ball on the beam's centre mark.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.steel)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onNext) {
                Text(isLevel ? "Next" : "Skip")
            }
            .buttonStyle(SlabButtonStyle(fill: isLevel ? Theme.pass : Theme.surface,
                                         textColor: isLevel ? .black : Theme.steel,
                                         size: 16, verticalPadding: 12))
        }
    }
}

// MARK: - Hitter

/// The height the whole hitter measurement is scaled against.
///
/// Asked for once, and kept in Settings rather than per swing: the app has no
/// athlete identity anywhere, so a per-hitter profile would be a new concept
/// invented for one number.
struct HitterHeightRow: View {
    @Binding var heightCm: Double?

    @State private var entry = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        if let height = heightCm, !editing {
            settledRow(height)
        } else {
            entryRow
        }
    }

    private func settledRow(_ height: Double) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "Height %.0f cm", height))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button("Edit") {
                entry = String(format: "%.0f", height)
                editing = true
                focused = true
            }
            .buttonStyle(OutlineButtonStyle(verticalPadding: 6, cornerRadius: 9))
            .frame(width: 78)
        }
    }

    private var entryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Height").font(Theme.label(12)).foregroundStyle(Theme.steel)
                TextField("175", text: $entry)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(width: 68)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 7)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                Text("cm").font(.system(size: 13)).foregroundStyle(Theme.steel)
                Button("Use") { commit() }
                    .buttonStyle(OutlineButtonStyle(verticalPadding: 6, cornerRadius: 9))
                    .frame(width: 70)
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(Theme.fail)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { commit() }
            }
        }
    }

    /// Only once something has been typed. A range warning shown against an
    /// empty field is telling somebody off for not having started.
    private var warning: String? {
        guard !entry.isEmpty, parsed == nil else { return nil }
        let range = HitterScale.heightCmRange
        return String(format: "Between %.0f and %.0f cm.", range.lowerBound, range.upperBound)
    }

    private var parsed: Double? {
        guard let value = Double(entry.replacingOccurrences(of: ",", with: ".")) else { return nil }
        guard HitterScale.heightCmRange.contains(value) else { return nil }
        return value
    }

    private func commit() {
        guard let value = parsed else { return }
        heightCm = value
        editing = false
        focused = false
    }
}

/// What the hitter stage is doing, in one line of plain words.
struct HitterStateLine: View {
    var state: PlacementWizard.HitterScaleState

    var body: some View {
        Label(Self.text(for: state), systemImage: Self.symbol(for: state))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Self.tint(for: state))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func text(for state: PlacementWizard.HitterScaleState) -> String {
        switch state {
        case .needHeight:      return "Enter the hitter's height above"
        case .landscapeNeeded: return "Turn the phone sideways to measure from the hitter"
        case .noHitter:        return "Looking for the hitter…"
        case .notUpright(.knees):      return "Stand up straight — knees locked"
        case .notUpright(.leaning):    return "Stand tall, don't lean"
        case .notUpright(.outOfFrame): return "Whole body in frame, head to feet"
        case .sampling(let accepted, let needed):
            return "Hold still… \(accepted) of \(needed)"
        case .locked:          return "Measured ✓"
        }
    }

    private static func symbol(for state: PlacementWizard.HitterScaleState) -> String {
        switch state {
        case .locked:     return "checkmark.circle.fill"
        case .sampling:   return "circle.dotted.circle"
        case .needHeight: return "textformat.123"
        default:          return "figure.stand"
        }
    }

    private static func tint(for state: PlacementWizard.HitterScaleState) -> Color {
        switch state {
        case .locked:   return Theme.pass
        case .sampling: return Theme.yellow
        default:        return Theme.steel
        }
    }
}

/// The measured distance and how good it is.
struct DistanceResultRow: View {
    var distanceM: Double
    var sourceLabel: String?
    var isIdeal: Bool
    var isAcceptable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "≈ %.1f m", distanceM))
                .font(Theme.numeral(22))
                .foregroundStyle(isIdeal ? Theme.pass : (isAcceptable ? Theme.warn : Theme.fail))
            if let sourceLabel {
                Text("from " + sourceLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.steel)
            }
            Spacer(minLength: 0)
            StatChip(text: chip, color: isIdeal ? Theme.pass : (isAcceptable ? Theme.warn : Theme.fail))
        }
    }

    private var chip: String {
        if isIdeal { return "Good" }
        return isAcceptable ? "Workable" : "Move"
    }
}

/// The tap-the-ball path, kept whole because it still has to work: there may be
/// no hitter in frame, or the height may be somebody else's.
struct BallSubMode: View {
    var measuring: Bool
    var diameterPx: Double?
    var isRough: Bool
    var failureText: String?
    var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if measuring {
                Label("Measuring…", systemImage: "circle.dotted.circle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.yellow)
            } else if let diameterPx {
                found(diameterPx)
            } else {
                prompt
            }
            if let report {
                // Deliberately terse and technical: its job is to make a
                // rejection diagnosable from a photo of the screen, instead of
                // another round of guessing at which threshold was too tight.
                Text(report)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.steel.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func found(_ diameterPx: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(String(format: "Ball found — %.0f px across", diameterPx),
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.pass)
            if isRough {
                // Measured from the mask rather than the image edge, which
                // reads the compression halo and over-states the size.
                Text("Rough — too little contrast to find the exact edge. Better light will sharpen it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
            }
            Text("Tap the ball again any time to re-measure.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.steel)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Touch the ball on the screen", systemImage: "hand.tap.fill")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.yellow)
            Text(failureText ?? "Put a ball where you are going to hit it — on the tee — and touch it on screen. A softball is 9.7 cm across, so that one tap gives both the scale and how far away the camera is. It can sit anywhere in frame as long as it is still and not against something its own colour.")
                .font(.system(size: 11))
                .foregroundStyle(failureText == nil ? Theme.steel : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Ready

/// One fact per row, with the same verdict the Status sheet would give.
struct SummaryRow: View {
    var label: String
    var value: String
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.label(11)).tracking(1)
                .foregroundStyle(Theme.steel)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Layout

/// How tall the stage panel is, so the framing guide can keep its captions out
/// from under it in portrait.
struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The two panels that need the wizard

/// Stage 2. The height, then whichever measurement is in use, then the way on.
///
/// `@ObservedObject` rather than reached through `AppModel`: the wizard
/// publishes at the pose model's rate while this panel is on screen, and
/// republishing that through the app model would invalidate every tab.
struct HitterStagePanel: View {
    @ObservedObject var wizard: PlacementWizard
    @Binding var heightCm: Double?
    var measuring: Bool
    /// Already turned into words by the overlay, so this panel does not have to
    /// know the detector's result type.
    var failureText: String?
    var isRoughBall: Bool
    var detectorReport: String?
    var onTypeDistance: () -> Void
    var onBack: () -> Void
    var onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HitterHeightRow(heightCm: $heightCm)
            methodBody
            navRow
        }
    }

    @ViewBuilder private var methodBody: some View {
        switch wizard.distanceMethod {
        case .hitter: hitterBody
        case .ball:   ballBody
        case .plate:  plateBody
        }
    }

    @ViewBuilder private var hitterBody: some View {
        if wizard.scaleSource != .none, let distance = wizard.derivedDistanceM {
            DistanceResultRow(distanceM: distance,
                              sourceLabel: wizard.distanceSourceLabel,
                              isIdeal: wizard.isDistanceIdeal,
                              isAcceptable: wizard.isDistanceAcceptable)
            Button("Re-measure") { wizard.remeasureHitter() }
                .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
        } else {
            HitterStateLine(state: wizard.hitterScaleState)
        }
    }

    @ViewBuilder private var ballBody: some View {
        BallSubMode(measuring: measuring,
                    diameterPx: wizard.scaleSource == .ball ? wizard.lastBallDiameterPx : nil,
                    isRough: isRoughBall,
                    failureText: failureText,
                    report: detectorReport)
        Button("Done") { wizard.distanceMethod = .hitter }
            .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
    }

    @ViewBuilder private var plateBody: some View {
        // The geometry matters and is easy to get backwards. A side-on camera
        // sees the plate's front edge END-ON — it points at the lens — so the
        // pixels between its corners are depth, not 43 cm. The span that runs
        // across the picture is front edge to rear point.
        Text("Pinch to zoom. Put one handle on the plate's front edge — the side facing the pitcher, seen end-on, where both corners meet — and the other on the point facing the catcher. 43 cm front to point.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.steel)
            .fixedSize(horizontal: false, vertical: true)
        if let distance = wizard.derivedDistanceM, wizard.scaleSource == .plate {
            DistanceResultRow(distanceM: distance,
                              sourceLabel: wizard.distanceSourceLabel,
                              isIdeal: wizard.isDistanceIdeal,
                              isAcceptable: wizard.isDistanceAcceptable)
        }
        // Without this, plate mode had no exit at all: clearing the measurement
        // never cleared the markers.
        Button("Done") { wizard.distanceMethod = .hitter }
            .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
    }

    private var navRow: some View {
        HStack(spacing: 8) {
            Button("Back") { onBack() }
                .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
            methodMenu
            Button(wizard.scaleSource == .none ? "Skip" : "Next") { onNext() }
                .buttonStyle(SlabButtonStyle(
                    fill: wizard.scaleSource == .none ? Theme.surface : Theme.yellow,
                    textColor: wizard.scaleSource == .none ? Theme.steel : .black,
                    size: 15, verticalPadding: 10))
        }
    }

    /// A `Menu` of plain `Button`s, never a `Picker`. These are actions with
    /// side effects — one of them takes over the preview's touches — and a
    /// picker presents them as a setting that can be browsed.
    private var methodMenu: some View {
        Menu {
            Button("Measure from hitter height") { wizard.remeasureHitter() }
            Button("Tap the ball instead") { wizard.distanceMethod = .ball }
            Button("Mark home plate instead") {
                wizard.distanceMethod = .plate
                wizard.applyPlateMeasurement()
            }
            Button("Type a distance") { onTypeDistance() }
            if wizard.scaleSource != .none {
                Button("Clear measurement", role: .destructive) { wizard.clearScale() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 40)
        }
        .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
        .frame(width: 52)
    }
}

/// Stage 3. Everything the swing about to be recorded will be stamped with,
/// then ARM.
struct ReadyStagePanel: View {
    @ObservedObject var wizard: PlacementWizard
    /// Proof the pose gate is alive on this hitter in this light, which is the
    /// question setup exists to answer. It used to be a chip in the header,
    /// where it was decoration; here it is the last check before arming.
    var hitterPresent: Bool
    var onArm: () -> Void
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            levelRow
            hitterRow
            distanceRow
            heightRow
            advisory
            armButton
            Button("Back") { onBack() }
                .buttonStyle(OutlineButtonStyle(verticalPadding: 8, cornerRadius: 10))
        }
    }

    private var levelRow: some View {
        let summary = wizard.tiltSummary
        let tint: Color
        switch summary.ok {
        case .some(true):  tint = Theme.pass
        case .some(false): tint = Theme.warn
        case .none:        tint = Theme.steel
        }
        return SummaryRow(label: "Level", value: summary.text, tint: tint)
    }

    private var hitterRow: SummaryRow {
        SummaryRow(label: "Hitter",
                   value: hitterPresent ? "detected ✓" : "not seen",
                   tint: hitterPresent ? Theme.pass : Theme.steel)
    }

    private var distanceRow: SummaryRow {
        guard let distance = wizard.derivedDistanceM else {
            return SummaryRow(label: "Distance", value: "not set — skipped", tint: Theme.steel)
        }
        let source = wizard.distanceSourceLabel.map { " · " + $0 } ?? ""
        let tint: Color = wizard.isDistanceIdeal
            ? Theme.pass : (wizard.isDistanceAcceptable ? Theme.warn : Theme.fail)
        return SummaryRow(label: "Distance",
                          value: String(format: "%.1f m", distance) + source,
                          tint: tint)
    }

    private var heightRow: SummaryRow {
        guard let height = wizard.lensHeightEstimateM else {
            return SummaryRow(label: "Lens height", value: "—", tint: Theme.steel)
        }
        let ok = wizard.isLensHeightOK == true
        return SummaryRow(label: "Lens height",
                          value: String(format: "%.1f m up", height) + (ok ? " ✓" : ""),
                          tint: ok ? Theme.pass : Theme.warn)
    }

    @ViewBuilder private var advisory: some View {
        if let advice = wizard.topAdvisory {
            Text(advice.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(advice.level == .warning ? Theme.warn : Theme.steel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Never disabled. Nothing on this screen blocks arming — see
    /// `isArmingAllowed` — and a greyed button beside a list of advisories is
    /// how a user learns the advisories are the thing stopping them.
    private var armButton: some View {
        Button(action: onArm) {
            Text("Arm — let's hit")
        }
        .buttonStyle(SlabButtonStyle(size: 18, verticalPadding: 15))
    }
}
