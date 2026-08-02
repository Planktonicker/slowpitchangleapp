// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// Camera setup, drawn **over** the capture screen's live preview.
///
/// It deliberately owns no camera of its own. It used to be a sheet with its
/// own `CameraPreview`, and two preview layers cannot share one session: the
/// second took the preview connection, and when the sheet closed that
/// connection died with it and left the capture screen permanently black.
/// Drawing over the existing preview removes the whole class of problem, and
/// it is what lets the user tap the ball *in the picture* — the overlay is not
/// modal, so touches reach the preview underneath.
///
/// What it asks for, in order:
///  1. Stand the tripod where the diagram shows (side-on, hitter in the box).
///  2. Tap the ball in the picture, once.
///  3. Arm.
///
/// Levelling is shown but never demanded: roll is corrected in the maths and
/// tilt is flagged, so a tripod on uneven grass still measures.
struct SetupOverlay: View {
    @EnvironmentObject private var model: AppModel

    /// Live measurement state, owned by `CaptureView` because the tap arrives
    /// on the preview it owns.
    @Binding var measuring: Bool
    @Binding var lastResult: BallMeasureResult?

    var onClose: () -> Void
    var onArm: () -> Void

    @State private var showDistanceEntry = false
    @State private var showTips = false

    private var wizard: PlacementWizard { model.wizard }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                framingGuide

                if isLandscape {
                    VStack(spacing: 10) {
                        topBar
                        levelBar
                        Spacer()
                    }
                    .padding(14)
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Spacer()
                            if wizard.showPlateMarkers { plateHint }
                            distanceCard
                            armButton
                        }
                        .frame(width: 340)
                        .padding(14)
                    }
                } else {
                    VStack(spacing: 10) {
                        topBar
                        levelBar
                        Spacer()
                        if wizard.showPlateMarkers { plateHint }
                        distanceCard
                        armButton
                    }
                    .padding(14)
                }

                if wizard.showPlateMarkers {
                    GeometryReader { markerGeo in
                        PlateMarkers(start: plateBinding(\.plateStart),
                                     end: plateBinding(\.plateEnd),
                                     size: markerGeo.size)
                    }
                }
            }
        }
        .sheet(isPresented: $showTips) { PlacementTipsView() }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .heavy))
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(spacing: 3) {
                Text("Set up the camera")
                    .font(Theme.label(15))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.white)
                // Proof the hitter detector is alive. Without this the user
                // has no way to know the pose gate works until a swing goes
                // silently unrecorded in the field.
                StatChip(text: model.capture.hitterPresent ? "Hitter detected ✓" : "Looking for hitter…",
                         color: model.capture.hitterPresent ? Theme.pass : Theme.steel)
            }
            .shadow(radius: 3)
            Spacer()
            Button {
                showTips = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .heavy))
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(Theme.yellow)
            }
        }
    }

    /// Where things should be in frame. Static template, no tracking — its job
    /// is to make "film it the same way every time" visual.
    private var framingGuide: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.yellow.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 2, dash: [10, 7]))
                    .frame(width: w * 0.30, height: h * 0.62)
                    .position(x: w * 0.24, y: h * 0.52)
                Text("HITTER")
                    .font(Theme.label(11)).tracking(2)
                    .foregroundStyle(Theme.yellow.opacity(0.8))
                    .position(x: w * 0.24, y: h * 0.18)

                Circle()
                    .strokeBorder(Theme.yellow.opacity(0.55),
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(width: 34, height: 34)
                    .position(x: w * 0.34, y: h * 0.66)
                Text("BALL")
                    .font(Theme.label(10)).tracking(1.5)
                    .foregroundStyle(Theme.yellow.opacity(0.8))
                    .position(x: w * 0.34, y: h * 0.735)
            }
        }
        // Critical: the whole point of the overlay is that taps reach the
        // preview underneath so the user can tap the ball.
        .allowsHitTesting(false)
    }

    /// Roll as a ball on a beam, tilt as a hint underneath. Advisory only —
    /// nothing here can stop you arming.
    private var levelBar: some View {
        VStack(spacing: 5) {
            ZStack {
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(height: 26)
                Capsule()
                    .strokeBorder(wizard.level.isLevel ? Theme.pass : .white.opacity(0.35),
                                  lineWidth: 1.5)
                    .frame(height: 26)
                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 2, height: 16)
                Circle()
                    .fill(wizard.level.isLevel ? Theme.pass : Theme.warn)
                    .frame(width: 18, height: 18)
                    .offset(x: max(-1, min(1, wizard.level.rollDeg / 8)) * 120)
                    .animation(.easeOut(duration: 0.12), value: wizard.level.rollDeg)
            }
            .frame(maxWidth: 280)

            Group {
                if !wizard.level.isAvailable || !wizard.level.hasReading {
                    StatChip(text: "Level unknown", color: Theme.steel)
                } else if wizard.level.isLevel {
                    StatChip(text: "Level ✓", color: Theme.pass)
                } else if !wizard.level.isTiltOK {
                    StatChip(text: wizard.level.tiltDeg > 0 ? "Aiming down — still fine" : "Aiming up — still fine",
                             color: Theme.warn)
                } else {
                    StatChip(text: "Slightly off level — corrected", color: Theme.warn)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var plateHint: some View {
        Text("Drag both handles onto the ends of the plate's front edge — the 43 cm side facing the pitcher.")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: wizard.plateStart) { _, _ in wizard.applyPlateMeasurement() }
            .onChange(of: wizard.plateEnd) { _, _ in wizard.applyPlateMeasurement() }
    }

    private var distanceCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Distance")
                    .font(Theme.label(12)).tracking(1)
                    .foregroundStyle(Theme.steel)
                Spacer()
                if let m = wizard.derivedDistanceM {
                    Text(String(format: "≈ %.1f m", m))
                        .font(Theme.numeral(24))
                        .foregroundStyle(wizard.isDistanceIdeal ? Theme.pass
                                         : (wizard.isDistanceAcceptable ? Theme.warn : Theme.fail))
                    if wizard.isDistanceIdeal {
                        StatChip(text: "Good", color: Theme.pass)
                    } else if wizard.isDistanceAcceptable {
                        StatChip(text: "Workable", color: Theme.warn)
                    } else {
                        StatChip(text: "Move", color: Theme.fail)
                    }
                } else {
                    Text("—")
                        .font(Theme.numeral(24))
                        .foregroundStyle(Theme.steel)
                }
            }

            instruction

            // The fallback is a first-class option, not a hidden one. There
            // may be no ball to hand, it may be too dark, or the ball may be
            // sitting on something its own colour — in every one of those cases
            // the user still needs a way to finish setup.
            HStack(spacing: 8) {
                Button { showDistanceEntry = true } label: {
                    Text("No ball? Type distance")
                }
                .buttonStyle(OutlineButtonStyle())

                Menu {
                    Button("Mark home plate instead") {
                        wizard.showPlateMarkers = true
                        wizard.applyPlateMeasurement()
                    }
                    if wizard.scaleSource != .none {
                        Button("Clear measurement", role: .destructive) { wizard.clearScale() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 44)
                }
                .buttonStyle(OutlineButtonStyle())
                .frame(width: 56)
            }
        }
        .padding(12)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        // Swallow taps: without this, tapping the card would fall through to
        // the preview and be read as "the ball is here".
        .contentShape(Rectangle())
        .alert("Distance from camera to hitter", isPresented: $showDistanceEntry) {
            TextField("metres", value: distanceEntryBinding, format: .number)
                .keyboardType(.decimalPad)
            Button("Use it") { wizard.applyManualDistance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Measure with a tape or pace it off — about 0.9 m per big step. 4.5–6 m is the sweet spot.")
        }
    }

    /// The one instruction that matters, and honest feedback on the last try.
    @ViewBuilder private var instruction: some View {
        if measuring {
            Label("Measuring…", systemImage: "circle.dotted.circle")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.yellow)
        } else if wizard.scaleSource == .ball, let d = wizard.lastBallDiameterPx {
            VStack(alignment: .leading, spacing: 3) {
                Label(String(format: "Ball found — %.0f px across", d),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.pass)
                Text("Tap the ball again any time to re-measure.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.steel)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Touch the ball on the screen", systemImage: "hand.tap.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.yellow)
                Text(failureText ?? "SwingLab needs one thing before it can measure a swing: how big the ball looks. A softball is 9.7 cm across, so one tap tells it both the scale and how far away you are — no tape measure.")
                    .font(.system(size: 11))
                    .foregroundStyle(failureText == nil ? Theme.steel : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says what actually went wrong. The old code flattened every failure
    /// into "couldn't find the ball", including the pixel-format bug that made
    /// every measurement impossible.
    private var failureText: String? {
        guard let result = lastResult else { return nil }
        switch result {
        case .noBallNearTap:
            return "Nothing ball-shaped there. Tap right on the middle of the ball."
        case .notAnEdge:
            return "That is a patch of colour, not a ball — no clear edge to measure. If the ball is on something the same colour, put it on the grass or hold it up against the sky."
        case .mergedWithBackground:
            return "The ball is blending into what it is sitting on. Move it onto a different-coloured surface, or hold it up against the sky."
        case .shadowed:
            return "Half the ball is in shadow. Move it into the light, or turn the phone so the sun is behind you."
        case .truncatedByFrame:
            return "The ball is cut off by the edge of the picture. Move it further into frame."
        case .noFrameYet:
            return "Camera is still starting — try again in a second."
        case .conversionFailed:
            return "Could not read that frame. Try again; if it keeps happening, restart the app."
        case .found:
            return nil
        }
    }

    private var armButton: some View {
        VStack(spacing: 6) {
            if let advice = wizard.topAdvisory {
                Text(advice.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(advice.level == .blocking ? Theme.warn : Theme.steel)
                    .multilineTextAlignment(.center)
            }
            Button(action: onArm) {
                Text(wizard.isArmingAllowed ? "Arm — let's hit" : "Arm")
            }
            .buttonStyle(SlabButtonStyle(fill: wizard.isArmingAllowed ? Theme.yellow : Theme.surface,
                                         textColor: wizard.isArmingAllowed ? .black : Theme.steel))
            .disabled(!wizard.isArmingAllowed)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var distanceEntryBinding: Binding<Double> {
        Binding(get: { wizard.manualDistanceM },
                set: { wizard.manualDistanceM = $0 })
    }

    private func plateBinding(_ keyPath: ReferenceWritableKeyPath<PlacementWizard, CGPoint>) -> Binding<CGPoint> {
        Binding(get: { wizard[keyPath: keyPath] },
                set: { wizard[keyPath: keyPath] = $0 })
    }
}

/// Two draggable handles and the line between them, in normalized coords.
struct PlateMarkers: View {
    @Binding var start: CGPoint
    @Binding var end: CGPoint
    var size: CGSize

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: point(start))
                path.addLine(to: point(end))
            }
            .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

            handle($start)
            handle($end)
        }
    }

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func handle(_ binding: Binding<CGPoint>) -> some View {
        Circle()
            .strokeBorder(Theme.yellow, lineWidth: 3)
            .background(Circle().fill(Theme.yellow.opacity(0.25)))
            .frame(width: 40, height: 40)
            .position(point(binding.wrappedValue))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        binding.wrappedValue = CGPoint(
                            x: max(0, min(1, value.location.x / size.width)),
                            y: max(0, min(1, value.location.y / size.height))
                        )
                    }
            )
    }
}

/// The tripod diagram, drawn rather than photographed so it works at night
/// and in any locale: where to stand, how far, how high.
struct PlacementTipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    diagram
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    tip("1", "Side-on, never behind",
                        "Stand the tripod square to the hitter, on their chest side — 3B side for a righty, 1B side for a lefty — so their body never blocks the ball.")
                    tip("2", "Five to seven big steps",
                        "That's 4.5–6 m. Closer and the ball leaves the frame too fast; further and it gets too small to measure.")
                    tip("3", "Lens at belt height",
                        "About 1.1 m up — the height where bat meets ball. Most tripods reach it near full extension.")
                    tip("4", "Tap the ball on screen",
                        "Put a ball down in frame and touch it on the picture. That one tap gives the app both the scale and how far away you are — no tape measure.")
                }
                .padding()
            }
            .background(Theme.black)
            .navigationTitle("Where the phone goes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Overhead view: hitter, ball flight, and the phone off to the side.
    private var diagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let hitter = CGPoint(x: w * 0.22, y: h * 0.5)
            let phone = CGPoint(x: w * 0.22, y: h * 0.88)

            var flight = Path()
            flight.move(to: hitter)
            flight.addLine(to: CGPoint(x: w * 0.95, y: h * 0.42))
            context.stroke(flight, with: .color(Theme.yellow),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

            var sight = Path()
            sight.move(to: phone)
            sight.addLine(to: hitter)
            context.stroke(sight, with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))

            context.fill(Path(ellipseIn: CGRect(x: hitter.x - 9, y: hitter.y - 9, width: 18, height: 18)),
                         with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: hitter.x + 16, y: hitter.y - 5, width: 10, height: 10)),
                         with: .color(Theme.yellow))
            context.fill(Path(roundedRect: CGRect(x: phone.x - 7, y: phone.y - 12, width: 14, height: 24), cornerRadius: 3),
                         with: .color(Theme.yellow))

            context.draw(Text("HITTER").font(Theme.label(10)).foregroundStyle(.white),
                         at: CGPoint(x: hitter.x, y: hitter.y - 22))
            context.draw(Text("BALL FLIGHT").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: w * 0.7, y: h * 0.32))
            context.draw(Text("PHONE").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: phone.x + 52, y: phone.y))
            context.draw(Text("ABOUT 5 M").font(Theme.label(9)).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: phone.x + 74, y: (phone.y + hitter.y) / 2))
        }
        .padding(10)
    }

    private func tip(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(Theme.numeral(18))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Theme.yellow, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .heavy))
                Text(body).font(.system(size: 13)).foregroundStyle(Theme.steel)
            }
        }
    }
}
