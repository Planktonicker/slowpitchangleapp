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
                model.settings.hitterOnLeft.toggle()
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(size: 13, weight: .heavy))
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
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

    /// A picture of the shot to set up, rather than an abstraction.
    ///
    /// This replaces a dashed rectangle labelled HITTER and a small circle
    /// labelled BALL, which told you where two things belonged without ever
    /// saying which way the hitter faced or which way the ball went — so it
    /// could be matched exactly while still filming the wrong shot.
    ///
    /// The geometry it draws is not a style choice. Launch angle and exit
    /// velocity are measured from the ball's path across the image, so the
    /// flight has to run ACROSS the frame, not toward or away from the lens:
    /// a ball flying at the camera is foreshortened, reads slow, and gets
    /// flagged for depth motion. Hence hitter near one edge, tee in front of
    /// them, and most of the frame left empty for the ball to travel through.
    private var framingGuide: some View {
        GeometryReader { geo in
            guideDrawing(in: geo.size)
        }
        // Critical: the whole point of the overlay is that taps reach the
        // preview underneath so the user can tap the ball.
        .allowsHitTesting(false)
    }

    /// Deliberately a plain function rather than a `@ViewBuilder` body: it
    /// declares local helpers and returns explicitly, neither of which a result
    /// builder allows.
    private func guideDrawing(in size: CGSize) -> some View {
        let w = size.width, h = size.height
        let isLandscape = w > h
        let flip = model.settings.hitterOnLeft ? 1.0 : -1.0
        // Mirror about the centre when the hitter works the other way.
        func px(_ nx: Double) -> Double { (0.5 + (nx - 0.5) * flip) * w }
        func py(_ ny: Double) -> Double { ny * h }
        func pt(_ nx: Double, _ ny: Double) -> CGPoint { CGPoint(x: px(nx), y: py(ny)) }

        // The outline is sized from the real optics, so standing the hitter
        // inside it *is* the distance check: if they fit, the camera is about
        // 5 m away. Guessing a fraction of the screen instead would be wrong
        // by a factor of two between portrait and landscape, because filling
        // the screen crops a different amount of the sensor in each.
        let figureH = batterHeightFraction(isLandscape: isLandscape,
                                           screenAspect: w / max(1, h))
        let figureW = figureH * BatterOutline.aspect * (h / max(1, w))
        let footY = 0.90
        let headY = footY - figureH
        let centreX = 0.24
        // Contact happens around belt height, a little over half way up.
        let ballY = footY - figureH * 0.46
        let teeX = centreX + BatterOutline.aspect * figureH * (h / max(1, w)) * 0.62

        return ZStack {
            BatterOutline()
                .stroke(Theme.yellow.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: figureW * w, height: figureH * h)
                .scaleEffect(x: flip, y: 1, anchor: .center)
                .position(pt(centreX, (headY + footY) / 2))
                .shadow(color: .black.opacity(0.55), radius: 4)

            // Tee and ball, in front of the hitter at contact height.
            Path { p in
                p.move(to: pt(teeX, footY))
                p.addLine(to: pt(teeX, ballY + 0.012))
            }
            .stroke(Theme.yellow.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            Circle()
                .strokeBorder(Theme.yellow, lineWidth: 2.5)
                .frame(width: 0.042 * min(w, h), height: 0.042 * min(w, h))
                .position(pt(teeX, ballY))

            // Where the ball goes — the whole reason the frame is composed
            // this way, and the thing the old guide never said.
            Path { p in
                p.move(to: pt(teeX + 0.05, ballY - 0.01))
                p.addQuadCurve(to: pt(0.93, ballY - 0.30),
                               control: pt(teeX + 0.32, ballY - 0.24))
            }
            .stroke(Theme.yellow.opacity(0.75),
                    style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
            Path { p in
                p.move(to: pt(0.865, ballY - 0.325))
                p.addLine(to: pt(0.93, ballY - 0.30))
                p.addLine(to: pt(0.872, ballY - 0.262))
            }
            .stroke(Theme.yellow,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            guideLabel("STAND HERE", at: pt(centreX, footY + 0.045))
            guideLabel("FACING THE CAMERA", at: pt(centreX, footY + 0.078), small: true)
            guideLabel("TEE", at: pt(teeX, footY + 0.045), small: true)
            guideLabel("BALL FLIES THIS WAY", at: pt(0.70, ballY - 0.37))
        }
    }

    /// How tall a 1.75 m hitter standing 5 m away actually appears, as a
    /// fraction of screen height.
    ///
    /// The preview fills the screen, which crops the sensor differently in each
    /// orientation: in portrait the screen's long axis spans the camera's full
    /// horizontal field of view, while in landscape the screen's *width* spans
    /// it and the visible vertical angle is narrowed by the screen's aspect
    /// ratio. The same person is therefore about a third of the height in
    /// portrait and roughly two thirds in landscape — a fixed fraction would be
    /// wrong in one of them, and the outline would quietly teach the wrong
    /// distance.
    private func batterHeightFraction(isLandscape: Bool, screenAspect: Double) -> Double {
        let targetDistanceM = 5.25      // middle of the 4.5-6 m window
        let hitterHeightM = 1.75
        let fov = model.capture.fieldOfViewDeg
        guard fov > 5 else { return isLandscape ? 0.62 : 0.30 }

        let horizontalHalf = fov * .pi / 360
        let visibleVerticalHalf = isLandscape
            ? atan(tan(horizontalHalf) / max(0.1, screenAspect))
            : horizontalHalf
        let visibleMetres = 2 * targetDistanceM * tan(visibleVerticalHalf)
        guard visibleMetres > 0.1 else { return isLandscape ? 0.62 : 0.30 }
        return min(0.80, max(0.15, hitterHeightM / visibleMetres))
    }

    private func guideLabel(_ text: String, at point: CGPoint,
                            small: Bool = false) -> some View {
        Text(text)
            .font(Theme.label(small ? 9 : 11))
            .tracking(1.4)
            .foregroundStyle(Theme.yellow.opacity(small ? 0.7 : 0.9))
            .shadow(color: .black.opacity(0.9), radius: 3)
            .position(point)
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
                if case .some(.found(let m)) = lastResult, !m.subpixelRefined {
                    // Measured from the mask rather than the image edge, which
                    // reads the compression halo and over-states the size.
                    Text("Rough — too little contrast to find the exact edge. Better light will sharpen it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warn)
                }
                Text("Tap the ball again any time to re-measure.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.steel)
                detectorReport
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Touch the ball on the screen", systemImage: "hand.tap.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.yellow)
                Text(failureText ?? "Put a ball where you are going to hit it — on the tee — and touch it on screen. A softball is 9.7 cm across, so that one tap gives both the scale and how far away the camera is. It can sit anywhere in frame as long as it is still and not against something its own colour.")
                    .font(.system(size: 11))
                    .foregroundStyle(failureText == nil ? Theme.steel : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                detectorReport
            }
        }
    }

    /// Exactly what the shape gates measured. Deliberately terse and technical:
    /// its job is to make a rejection diagnosable from a photo of the screen,
    /// instead of another round of guessing at which threshold was too tight.
    @ViewBuilder private var detectorReport: some View {
        if let report = model.capture.lastMeasureReport {
            Text(report)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.steel.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
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

/// The batter, traced as a vector so it stays crisp at any size and can be
/// tinted and mirrored without shipping image assets.
///
/// Front-on stance with the hands on one side and the bat cocked over the
/// shoulder — which is what the camera actually sees from the side the hitter
/// faces, the position `CAPTURE_PROTOCOL.md` asks for. Drawn as several
/// subpaths (body, head, cap, arms, hands, bat) rather than one silhouette:
/// stroked outlines of overlapping parts read far better at guide opacity over
/// live video than a single traced boundary.
struct BatterOutline: Shape {
    /// Width ÷ height of the figure, including the raised bat.
    static let aspect = 0.45

    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()

        // --- torso and legs, one closed outline ---
        path.move(to: p(0.375, 0.195))
        path.addLine(to: p(0.275, 0.235))          // left shoulder
        path.addLine(to: p(0.255, 0.330))
        path.addLine(to: p(0.250, 0.480))          // waist
        path.addLine(to: p(0.235, 0.565))          // hip
        path.addCurve(to: p(0.105, 0.870),         // outside of the front leg
                      control1: p(0.200, 0.700), control2: p(0.130, 0.780))
        path.addLine(to: p(0.070, 0.935))
        path.addCurve(to: p(0.180, 0.965),         // front shoe
                      control1: p(0.010, 0.995), control2: p(0.095, 1.000))
        path.addCurve(to: p(0.375, 0.610),         // inside of the front leg
                      control1: p(0.235, 0.855), control2: p(0.315, 0.690))
        path.addCurve(to: p(0.520, 0.860),         // inside of the back leg
                      control1: p(0.440, 0.690), control2: p(0.490, 0.780))
        path.addLine(to: p(0.560, 0.940))
        path.addCurve(to: p(0.680, 0.935),         // back shoe
                      control1: p(0.640, 1.000), control2: p(0.730, 0.985))
        path.addCurve(to: p(0.545, 0.565),         // outside of the back leg
                      control1: p(0.630, 0.860), control2: p(0.575, 0.700))
        path.addLine(to: p(0.530, 0.480))
        path.addLine(to: p(0.545, 0.330))
        path.addLine(to: p(0.565, 0.235))          // right shoulder
        path.addLine(to: p(0.470, 0.195))
        path.closeSubpath()

        // Belt, which is also where contact happens.
        path.move(to: p(0.252, 0.495))
        path.addQuadCurve(to: p(0.528, 0.495), control: p(0.390, 0.535))

        // --- head, cap crown and brim ---
        path.addEllipse(in: CGRect(x: rect.minX + 0.340 * rect.width,
                                   y: rect.minY + 0.028 * rect.height,
                                   width: 0.170 * rect.width,
                                   height: 0.175 * rect.height))
        path.move(to: p(0.345, 0.108))             // cap band
        path.addLine(to: p(0.508, 0.108))
        path.move(to: p(0.345, 0.112))             // brim, toward the pitcher
        path.addCurve(to: p(0.240, 0.140),
                      control1: p(0.290, 0.108), control2: p(0.248, 0.120))
        path.addLine(to: p(0.348, 0.145))

        // --- arms to the hands, both across the body ---
        path.move(to: p(0.290, 0.245))
        path.addQuadCurve(to: p(0.135, 0.330), control: p(0.205, 0.290))
        path.move(to: p(0.555, 0.252))
        path.addCurve(to: p(0.150, 0.345),
                      control1: p(0.430, 0.320), control2: p(0.260, 0.360))

        // --- hands ---
        path.addEllipse(in: CGRect(x: rect.minX + 0.062 * rect.width,
                                   y: rect.minY + 0.298 * rect.height,
                                   width: 0.088 * rect.width,
                                   height: 0.072 * rect.height))

        // --- bat, cocked up over the shoulder ---
        path.move(to: p(0.027, 0.313))
        path.addLine(to: p(0.373, 0.012))
        path.addQuadCurve(to: p(0.427, 0.078), control: p(0.435, 0.010))
        path.addLine(to: p(0.063, 0.357))
        path.addQuadCurve(to: p(0.027, 0.313), control: p(0.020, 0.360))
        path.closeSubpath()

        return path
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

                    tip("1", "Side-on to the flight, never behind",
                        "Square to the ball's flight, on the side the hitter FACES — first-base side for a right-hander, third-base side for a left-hander. Behind them their own body hides the bat at contact.")
                    tip("2", "Five to seven big steps",
                        "That's 4.5–6 m. Closer and the ball leaves the frame too fast; further and it gets too small to measure.")
                    tip("3", "Lens at belt height",
                        "About 1.1 m up — the height where bat meets ball. Most tripods reach it near full extension.")
                    tip("4", "Tap the ball on screen",
                        "Put a ball on the tee — where contact will actually happen — and touch it on the picture. That one tap gives both the scale and the distance. Measure it at the hitting spot: the scale is only right at that distance, so a ball held near the lens would set the wrong one.")
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
                         at: CGPoint(x: hitter.x, y: hitter.y - 24))
            context.draw(Text("faces the phone").font(Theme.label(8)).foregroundStyle(.white.opacity(0.7)),
                         at: CGPoint(x: hitter.x + 4, y: hitter.y - 12))
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
