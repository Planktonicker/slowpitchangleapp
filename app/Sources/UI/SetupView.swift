// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

/// One-screen camera setup, on the live preview the whole time.
///
/// The old flow was a four-step wizard with an ARKit surveying step in the
/// middle — accurate, but it fought the capture session for the camera and
/// asked the user to think like an operator. This screen asks for exactly
/// three things a layman can do while looking at the picture:
///
///  1. Stand the tripod where the diagram shows (side-on, hitter in the box).
///  2. Level it until the bar goes green.
///  3. Tap the ball once so the app can measure the distance itself.
///
/// Everything is derived — the ball is 3.82 in, the lens angle is known, so
/// one tap yields scale AND distance with no tape measure and no AR.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var wizard: PlacementWizard { model.wizard }

    @State private var measuring = false
    @State private var measureFailed = false
    @State private var showDistanceEntry = false
    @State private var showTips = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: model.capture.session)
                    .ignoresSafeArea()

                framingGuide

                if isLandscape {
                    // Landscape is how the phone sits on the tripod: keep the
                    // middle of the frame clear and park the work on the
                    // right, level strip along the top.
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
        .preferredColorScheme(.dark)
        .onAppear { wizard.startSensors() }
        .sheet(isPresented: $showTips) { PlacementTipsView() }
        .alert("Couldn't find the ball", isPresented: $measureFailed) {
            Button("Try again") {}
            Button("Mark the plate instead") { wizard.showPlateMarkers = true }
        } message: {
            Text("Make sure the yellow ball is sitting still in frame — on the tee works best — and that nothing else bright yellow is visible.")
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .heavy))
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            Spacer()
            Text("Set up the camera")
                .font(Theme.label(15))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.white)
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

    /// Where things should be in frame: hitter fills the tall box on one
    /// side, ball/plate sits at the marker. Static template, no tracking —
    /// its job is to make "film it the same way every time" visual.
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
        .allowsHitTesting(false)
    }

    /// Roll shown as a sliding bar — like balancing a ball on a beam — with
    /// tilt as a hint underneath. Green means stop fiddling.
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
                if wizard.level.isLevel {
                    StatChip(text: "Level ✓", color: Theme.pass)
                } else if !wizard.level.isTiltOK {
                    StatChip(text: wizard.level.tiltDeg > 0 ? "Aim higher" : "Aim lower",
                             color: Theme.warn)
                } else {
                    StatChip(text: "Level the tripod", color: Theme.warn)
                }
            }
        }
    }

    private var plateHint: some View {
        Text("Drag both handles onto the ends of the plate's front edge — the 17-inch side facing the pitcher.")
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
                if let ft = wizard.derivedDistanceFt {
                    Text(String(format: "≈ %.0f ft", ft))
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

            HStack(spacing: 8) {
                Button {
                    measureBall()
                } label: {
                    Label(measuring ? "Measuring…" : "Tap the ball",
                          systemImage: "circle.dotted.circle")
                }
                .buttonStyle(SlabButtonStyle())
                .disabled(measuring)

                Menu {
                    Button("Mark home plate") {
                        wizard.showPlateMarkers = true
                        wizard.applyPlateMeasurement()
                    }
                    Button("Type the distance") { showDistanceEntry = true }
                    if wizard.scaleSource != .none {
                        Button("Clear measurement", role: .destructive) { wizard.clearScale() }
                    }
                } label: {
                    Text("Other")
                        .frame(width: 74)
                }
                .buttonStyle(OutlineButtonStyle())
            }

            if wizard.scaleSource == .ball, let d = wizard.lastBallDiameterPx {
                Text(String(format: "Found the ball — %.0f px across. Distance is worked out from its real 3.82 in size.", d))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.steel)
            } else if wizard.scaleSource == .none {
                Text("Put the ball on the tee (or anywhere still in frame) and tap the ball. The app measures it and works the distance out itself.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.steel)
            }
        }
        .padding(12)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        .alert("Distance from camera to hitter", isPresented: $showDistanceEntry) {
            TextField("feet", value: distanceEntryBinding, format: .number)
                .keyboardType(.decimalPad)
            Button("Use it") { wizard.applyManualDistance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Measure with a tape or pace it off — about 3 ft per big step. 15–20 ft is the sweet spot.")
        }
    }

    private var armButton: some View {
        VStack(spacing: 6) {
            if let reason = wizard.blockingReason {
                Text(reason)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.capture.lockExposureAndFocus()
                model.arm()
                dismiss()
            } label: {
                Text(wizard.isArmingAllowed ? "Arm — let's hit" : "Arm")
            }
            .buttonStyle(SlabButtonStyle(fill: wizard.isArmingAllowed ? Theme.yellow : Theme.surface,
                                         textColor: wizard.isArmingAllowed ? .black : Theme.steel))
            .disabled(!wizard.isArmingAllowed)
        }
    }

    // MARK: - Helpers

    private func measureBall() {
        measuring = true
        model.capture.measureBall(detector: model.settings.detector) { diameter in
            measuring = false
            if let diameter {
                wizard.applyBallMeasurement(diameterPx: diameter)
            } else {
                measureFailed = true
            }
        }
    }

    private var distanceEntryBinding: Binding<Double> {
        Binding(get: { wizard.manualDistanceFt },
                set: { wizard.manualDistanceFt = $0 })
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
                    tip("2", "Six to seven big steps",
                        "That's 15–20 ft. Closer and the ball leaves the frame too fast; further and it gets too small to measure.")
                    tip("3", "Lens at belt height",
                        "About 3½ ft up — the height where bat meets ball. Most tripods reach it near full extension.")
                    tip("4", "Hitter in the box, ball on the mark",
                        "Match the dashed guides on the camera screen. The hitter fills the tall box; leave the rest of the frame empty for the ball to fly through.")
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

            // Ball flight
            var flight = Path()
            flight.move(to: hitter)
            flight.addLine(to: CGPoint(x: w * 0.95, y: h * 0.42))
            context.stroke(flight, with: .color(Theme.yellow),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

            // Sight line, perpendicular to the flight
            var sight = Path()
            sight.move(to: phone)
            sight.addLine(to: hitter)
            context.stroke(sight, with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))

            // Hitter
            context.fill(Path(ellipseIn: CGRect(x: hitter.x - 9, y: hitter.y - 9, width: 18, height: 18)),
                         with: .color(.white))
            // Ball
            context.fill(Path(ellipseIn: CGRect(x: hitter.x + 16, y: hitter.y - 5, width: 10, height: 10)),
                         with: .color(Theme.yellow))
            // Phone
            context.fill(Path(roundedRect: CGRect(x: phone.x - 7, y: phone.y - 12, width: 14, height: 24), cornerRadius: 3),
                         with: .color(Theme.yellow))

            context.draw(Text("HITTER").font(Theme.label(10)).foregroundStyle(.white),
                         at: CGPoint(x: hitter.x, y: hitter.y - 22))
            context.draw(Text("BALL FLIGHT").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: w * 0.7, y: h * 0.32))
            context.draw(Text("PHONE").font(Theme.label(10)).foregroundStyle(Theme.yellow),
                         at: CGPoint(x: phone.x + 52, y: phone.y))
            context.draw(Text("6–7 BIG STEPS").font(Theme.label(9)).foregroundStyle(.white.opacity(0.7)),
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
