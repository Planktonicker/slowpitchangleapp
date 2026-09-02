// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import ImageIO
import SwiftUI

/// Camera setup, drawn **over** the capture screen's live preview.
///
/// It deliberately owns no camera of its own. It used to be a sheet with its
/// own `CameraPreview`, and two preview layers cannot share one session: the
/// second took the preview connection, and when the sheet closed that
/// connection died with it and left the capture screen permanently black.
/// Drawing over the existing preview removes the whole class of problem, and
/// it is what lets the user touch the picture — the overlay is not modal, so
/// touches reach the preview underneath.
///
/// Three stages, in order, each skippable:
///
///  1. **Level** — put the dashed horizon in the green band.
///  2. **Hitter** — stand tall in the box; the distance measures itself.
///  3. **Arm** — read the four rows and go.
///
/// One instrument per stage is the rule that shrank this file. Tilt used to be
/// drawn six ways at once — a roll beam, a chip, a red box on the outline, the
/// outline's own colour, the horizon line's label, and an advisory — all of
/// them true, all of them the same reading, and together the noise that made
/// the screen unusable in both orientations.
struct SetupOverlay: View {
    @EnvironmentObject private var model: AppModel
    /// Held directly rather than reached through `model`, so a 10 Hz level
    /// reading invalidates this overlay and nothing else in the app.
    @ObservedObject var capture: CaptureController
    @ObservedObject var wizard: PlacementWizard

    /// Live measurement state, owned by `CaptureView` because the tap arrives
    /// on the preview it owns.
    @Binding var measuring: Bool
    @Binding var lastResult: BallMeasureResult?

    var onClose: () -> Void
    var onArm: () -> Void

    @State private var showDistanceEntry = false
    @State private var showTips = false
    /// Measured, not assumed: the panel grows with whichever stage is showing,
    /// and in portrait the framing guide's captions have to stay above it.
    @State private var panelHeight: CGFloat = 0

    /// Width of the landscape control column. Named because the framing guide
    /// has to know it too — it draws around the panel, not under it.
    private static let panelWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
        .sheet(isPresented: $showTips) { PlacementTipsView() }
        .onPreferenceChange(PanelHeightKey.self) { height in
            panelHeight = height
        }
        // Two readings off the one pose. The feet close out the camera-height
        // estimate; the whole skeleton is what the distance is measured from.
        // Ankles rather than the pose's bounding box: the box grows a margin
        // around the silhouette and would put the "ground" several centimetres
        // below the feet, which at 5 m is tens of centimetres of height error.
        .onChange(of: capture.skeleton) { _, joints in
            if let feet = Self.feetFraction(from: joints,
                                            orientation: capture.visionOrientation) {
                wizard.noteHitterFeet(feet)
            }
            wizard.noteSkeleton(joints, hitterPresent: capture.hitterPresent)
        }
        .alert("Distance from camera to hitter", isPresented: $showDistanceEntry) {
            TextField("metres", value: distanceEntryBinding, format: .number)
                .keyboardType(.decimalPad)
            Button("Use it") { wizard.applyManualDistance() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Measure with a tape or pace it off — about 0.9 m per big step. 4.5–6 m is the sweet spot.")
        }
    }

    private func content(in size: CGSize) -> some View {
        let isLandscape = size.width > size.height
        return ZStack {
            guides(in: size, isLandscape: isLandscape)
            controls(in: size, isLandscape: isLandscape)
        }
    }

    // MARK: - What is drawn on the picture

    @ViewBuilder
    private func guides(in size: CGSize, isLandscape: Bool) -> some View {
        // Nothing to guide against until there is a picture. The camera takes a
        // moment to configure, and drawing a batter, a flight arrow and a
        // horizon band over the void reads as a broken app rather than a
        // starting one — especially as the phone is usually flat on a table
        // while it starts, so the steep tilt it would warn about is real,
        // correctly measured, and about nothing the user is doing.
        if capture.status == .running {
            if showsHorizon {
                HorizonGuide(
                    tiltDeg: wizard.level.hasReading ? wizard.level.tiltDeg : nil,
                    visibleVerticalHalfDeg: CameraPose.visibleVerticalHalfAngleDeg(
                        horizontalFovDeg: capture.fieldOfViewDeg,
                        isLandscape: isLandscape,
                        screenAspect: Double(size.width / max(1, size.height))),
                    toleranceDeg: wizard.level.tiltToleranceDeg,
                    correctableMaxDeg: SLA.tiltCorrectableMaxDeg)
            }
            // Hidden while the plate is being marked: the guide is a SwiftUI
            // overlay and does not travel with the preview's zoom transform, so
            // at 3x it would be a picture of the wrong framing laid over the
            // right one.
            if wizard.distanceMethod != .plate {
                FramingGuide(fov: capture.fieldOfViewDeg,
                             isLandscape: isLandscape,
                             screenAspect: Double(size.width / max(1, size.height)),
                             hitterOnLeft: model.settings.hitterOnLeft,
                             hitterHeightM: outlineHitterHeightM,
                             rightInset: rightInset(in: size, isLandscape: isLandscape),
                             topInset: topInset(in: size),
                             bottomInset: bottomInset(in: size, isLandscape: isLandscape),
                             outlineValid: outlineIsValid)
                    .equatable()
            }
        } else {
            startingUpCard
        }
    }

    /// The horizon line is the ONLY tilt reading on this screen, so it appears
    /// exactly where tilt is the question: always while levelling, on the hitter
    /// stage only if the camera has drifted out of tolerance, and never on the
    /// summary or while the plate is being marked.
    private var showsHorizon: Bool {
        guard wizard.distanceMethod != .plate else { return false }
        switch wizard.stage {
        case .level:  return true
        case .hitter: return !wizard.level.isTiltOK
        case .ready:  return false
        }
    }

    /// The outline is drawn for ONE camera: level, at contact height. Match it
    /// from anywhere else and it is decoration wearing the clothes of an
    /// instruction — see `CameraPose` for why two constraints cannot pin down
    /// three unknowns. Only judged on the stage where somebody is standing in
    /// it; elsewhere a red figure would be scolding nobody.
    private var outlineIsValid: Bool {
        guard wizard.stage == .hitter else { return true }
        return CameraPose.outlineIsValid(
            tiltDeg: wizard.level.hasReading ? wizard.level.tiltDeg : nil,
            tiltToleranceDeg: wizard.level.tiltToleranceDeg,
            lensHeightM: wizard.lensHeightEstimateM)
    }

    /// The figure is drawn at the size THIS hitter appears, not a generic 1.75 m
    /// one. Falling back to 1.75 keeps it a picture rather than nothing at all
    /// before a height has been typed.
    private var outlineHitterHeightM: Double {
        model.settings.hitterHeightCm.map { $0 / 100 } ?? 1.75
    }

    private var startingUpCard: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Theme.yellow)
            Text("Starting the camera…")
                .font(Theme.label(13)).tracking(1.1)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    // MARK: - Insets the guide draws around

    private func rightInset(in size: CGSize, isLandscape: Bool) -> Double {
        guard isLandscape else { return 0 }
        return Double((Self.panelWidth + 28) / max(1, size.width))
    }

    /// Points, not a fraction of each axis: it is the same stack of controls in
    /// both orientations, and a fraction of a 393 pt landscape height is a very
    /// different thing from a fraction of an 852 pt portrait one. Taller on the
    /// level stage, which is the only one carrying the roll beam.
    private func topInset(in size: CGSize) -> Double {
        let points: CGFloat = wizard.stage == .level ? 100 : 66
        return Double(points / max(1, size.height))
    }

    /// Zero in landscape: the panel is a column down one side there, and the
    /// guide already dodges it with `rightInset`. In portrait it is a card
    /// across the full width, and the guide's captions were being drawn
    /// underneath it, showing through the translucency as text printed twice.
    private func bottomInset(in size: CGSize, isLandscape: Bool) -> Double {
        guard !isLandscape else { return 0 }
        // The panel hugs its content up to the cap, so the drawn height is the
        // smaller of the two — reserving the full content height for a panel
        // that is scrolling would push the guide's captions off the screen.
        let drawn = min(panelHeight, size.height * Self.portraitPanelFraction)
        return Double((drawn + 14) / max(1, size.height))
    }

    /// Most of the lower half is available to the panel, but never more: the
    /// picture above it is the thing being set up.
    private static let portraitPanelFraction: CGFloat = 0.55

    // MARK: - Controls

    @ViewBuilder
    private func controls(in size: CGSize, isLandscape: Bool) -> some View {
        if isLandscape {
            // The column sits on whichever side the ball flies toward, because
            // that is the side the guide leaves empty. Pinned to the right it
            // buried the batter, the tee and both captions the moment the guide
            // was mirrored.
            // Top-aligned: with the panel hugging its content, centring it left
            // it floating halfway down the column, unmoored from the header it
            // belongs with.
            HStack(alignment: .top, spacing: 0) {
                if model.settings.hitterOnLeft {
                    instrumentColumn
                    stagePanel(maxHeight: size.height - 28).frame(width: Self.panelWidth)
                } else {
                    stagePanel(maxHeight: size.height - 28).frame(width: Self.panelWidth)
                    instrumentColumn
                }
            }
            .padding(14)
        } else {
            VStack(spacing: 10) {
                header
                if wizard.stage == .level { rollBeam }
                Spacer(minLength: 0)
                stagePanel(maxHeight: size.height * Self.portraitPanelFraction)
            }
            .padding(14)
        }
    }

    private var instrumentColumn: some View {
        VStack(spacing: 10) {
            header
            if wizard.stage == .level { rollBeam }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        SetupHeader(stage: wizard.stage,
                    onSelect: { stage in wizard.go(to: stage) },
                    onClose: onClose,
                    onMirror: { model.settings.hitterOnLeft.toggle() },
                    onHelp: { showTips = true })
    }

    private var rollBeam: some View {
        RollBeam(rollDeg: wizard.level.rollDeg, isRollOK: wizard.level.isRollOK)
    }

    /// Scrolls, because the ball sub-mode's diagnostic report can be several
    /// lines and a landscape phone is 390 pt tall.
    ///
    /// Sized to its CONTENT, capped — not merely capped. A `ScrollView` takes
    /// every point of height it is offered, so `maxHeight` alone made a
    /// two-line panel a black slab over half the picture, which is the picture
    /// the user is trying to frame. `panelHeight` is the measured height of the
    /// content inside, so this hugs it until the content genuinely needs the
    /// cap, and only then starts scrolling. No feedback loop: the content's
    /// height depends on the panel's WIDTH, which this does not touch.
    private func stagePanel(maxHeight: CGFloat?) -> some View {
        let cap = maxHeight ?? .greatestFiniteMagnitude
        // nil for the first frame only, before the preference has been read —
        // pinning it to zero would flash an invisible panel instead.
        let height: CGFloat? = panelHeight > 0 ? min(panelHeight, cap) : nil
        return ScrollView {
            stageContent
                .padding(12)
                .background(panelHeightReader)
        }
        .frame(height: height)
        // Nearly opaque, not 0.65. The framing guide is drawn behind it, and at
        // 0.65 the guide's captions read straight through the body copy, which
        // looked like the text had been printed twice.
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        // Swallow taps: without this, tapping the panel would fall through to
        // the preview and be read as "the ball is here".
        .contentShape(Rectangle())
    }

    private var panelHeightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch wizard.stage {
        case .level:
            LevelStagePanel(isLevel: wizard.level.isLevel,
                            onNext: { wizard.advance() })
        case .hitter:
            HitterStagePanel(wizard: wizard,
                             heightCm: hitterHeightBinding,
                             measuring: measuring,
                             failureText: failureText,
                             isRoughBall: isRoughBall,
                             detectorReport: capture.lastMeasureReport,
                             onTypeDistance: { showDistanceEntry = true },
                             onBack: { wizard.back() },
                             onNext: { wizard.advance() })
        case .ready:
            ReadyStagePanel(wizard: wizard,
                            hitterPresent: capture.hitterPresent,
                            onArm: onArm,
                            onBack: { wizard.back() })
        }
    }

    // MARK: - Helpers

    private var hitterHeightBinding: Binding<Double?> {
        Binding(get: { model.settings.hitterHeightCm },
                set: { model.settings.hitterHeightCm = $0 })
    }

    private var distanceEntryBinding: Binding<Double> {
        Binding(get: { wizard.manualDistanceM },
                set: { wizard.manualDistanceM = $0 })
    }

    /// Measured from the mask rather than the image edge, which reads the
    /// compression halo and over-states the size.
    private var isRoughBall: Bool {
        if case .some(.found(let m)) = lastResult { return !m.subpixelRefined }
        return false
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

    /// Where the hitter's feet sit in the capture buffer, from the live pose,
    /// as a fraction from the top of the *upright* picture.
    ///
    /// Both ankles when both are seen, because a side-on hitter's rear ankle is
    /// often the occluded one and averaging is steadier than picking; either
    /// alone otherwise. `nil` with no ankles at all — the height estimate is
    /// better absent than guessed off a hip.
    ///
    /// The orientation argument is not optional politeness. `deviceSkeleton`
    /// hands back **buffer** coordinates, and the buffer is landscape-native
    /// whichever way the phone is held, so "down the buffer" is only "down in
    /// the world" for one of the two landscape orientations. Filming
    /// landscape the other way up inverts it, and in portrait the buffer's y
    /// axis runs sideways across the world, where a foot position says nothing
    /// about height at all. Ignoring this would not produce a slightly wrong
    /// height — it would produce a confident one, upside down.
    static func feetFraction(from joints: [PoseJoint: CGPoint]?,
                             orientation: CGImagePropertyOrientation) -> Double? {
        guard let joints else { return nil }
        let ankles: [CGPoint] = [joints[.leftAnkle], joints[.rightAnkle]].compactMap { $0 }
        guard !ankles.isEmpty else { return nil }
        let mean = ankles.reduce(0.0) { $0 + Double($1.y) } / Double(ankles.count)
        // Through the shared helper rather than a second orientation table of
        // its own. The joints are already normalized, so the picture is one
        // unit across and one unit high.
        guard let upright = CameraPose.uprightBufferPoint(
            CGPoint(x: 0, y: mean), orientation: orientation,
            width: 1, height: 1) else { return nil }
        return Double(upright.y)
    }
}
