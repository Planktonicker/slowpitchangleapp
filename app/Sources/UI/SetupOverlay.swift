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
    /// The panel covers the picture, and the picture is the thing being set
    /// up. Collapsing it leaves the header — which still carries the distance
    /// and its verdict — and hands the frame back.
    @State private var cardCollapsed = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                // Nothing to guide against until there is a picture.
                //
                // The camera takes a moment to configure, and until it does the
                // preview is black — at which point drawing the batter, the
                // flight arrow, the horizon band and a red "AIM LEVEL FIRST"
                // banner over the void reads as a broken app rather than a
                // starting one. The phone is usually flat on a table while it
                // starts, so the steep tilt it warns about is real, correctly
                // measured, and about nothing the user is doing.
                if capture.status == .running {
                    // Drawn UNDER the framing guide on purpose: the guide is
                    // the instruction and the horizon is the condition that
                    // instruction assumes, so the batter is drawn over it
                    // rather than sliced by it.
                    HorizonGuide(
                        tiltDeg: wizard.level.hasReading ? wizard.level.tiltDeg : nil,
                        visibleVerticalHalfDeg: CameraPose.visibleVerticalHalfAngleDeg(
                            horizontalFovDeg: capture.fieldOfViewDeg,
                            isLandscape: isLandscape,
                            screenAspect: Double(geo.size.width / max(1, geo.size.height))),
                        toleranceDeg: wizard.level.tiltToleranceDeg,
                        correctableMaxDeg: SLA.tiltCorrectableMaxDeg)

                    // The guide is drawn into the part of the frame the panels
                    // do not cover. Without this the ball-flight arrow and its
                    // label ran straight under the distance card in landscape,
                    // so the one thing the guide exists to say was the one
                    // thing hidden.
                    framingGuide(
                        // Only while the card is open. Collapsed, the column is
                        // a header and a button in the bottom corner, and
                        // fencing off 45% of the width for it shrank the flight
                        // arrow to a stub.
                        rightInset: isLandscape && !cardCollapsed
                            ? Double((Self.panelWidth + 28) / max(1, geo.size.width)) : 0,
                        // Height of the top control block, so the flight arc
                        // passes under the bubble level instead of through it.
                        topInset: Double(Self.topBlockHeight(isLandscape: isLandscape)
                                         / max(1, geo.size.height)),
                        bottomInset: bottomInset(in: geo.size, isLandscape: isLandscape))
                } else {
                    startingUpCard
                }

                if isLandscape {
                    VStack(spacing: 10) {
                        topBar
                        levelBar
                        Spacer()
                    }
                    .padding(14)
                    // The column sits on whichever side the ball flies toward,
                    // because that is the side the guide leaves empty. Pinned
                    // to the right it buried the batter, the tee and both
                    // captions the moment the guide was mirrored.
                    HStack(spacing: 0) {
                        if model.settings.hitterOnLeft { Spacer(minLength: 0) }
                        VStack(spacing: 10) {
                            Spacer()
                            if wizard.showPlateMarkers { plateHint }
                            distanceCard
                            armButton
                        }
                        .frame(width: Self.panelWidth)
                        .padding(14)
                        if !model.settings.hitterOnLeft { Spacer(minLength: 0) }
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
        // The third leg of the camera-height estimate. Ankles rather than the
        // pose's bounding box: the box grows a margin around the silhouette
        // and would put the "ground" several centimetres below the feet, which
        // at 5 m is tens of centimetres of height error.
        .onChange(of: capture.skeleton) { _, joints in
            if let feet = Self.feetFraction(from: joints,
                                            orientation: capture.visionOrientation) {
                wizard.noteHitterFeet(feet)
            }
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

    /// Width of the landscape control column. Named because the framing guide
    /// has to know it too — it draws around the panel, not under it.
    private static let panelWidth: CGFloat = 300

    /// Shown in place of the whole guide while the session comes up.
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

    /// Fraction of the frame the bottom controls cover.
    ///
    /// Zero in landscape: the panels are a column down one side there, and the
    /// guide already dodges them with `rightInset`. In portrait they are the
    /// distance card and the arm button stacked across the full width, which
    /// is most of the lower half — and the guide's own captions were being
    /// drawn underneath them, showing through the panel's translucency as
    /// upside-down-looking text mixed into the body copy.
    private func bottomInset(in size: CGSize, isLandscape: Bool) -> Double {
        guard !isLandscape else { return 0 }
        // Card (collapsed or open) plus the arm slab plus padding, in points
        // for the same reason `topBlockHeight` is: a fraction of a landscape
        // height is a very different thing from a fraction of a portrait one.
        let points: CGFloat = cardCollapsed ? 170 : 330
        return Double(points / max(1, size.height))
    }

    /// Vertical space the close/title/level block occupies at the top. Points,
    /// not a fraction: it is the same stack of controls in both orientations,
    /// and a fraction of a 393pt landscape height is a very different thing
    /// from a fraction of an 852pt portrait one.
    private static func topBlockHeight(isLandscape: Bool) -> CGFloat {
        // 14 padding + 44 top bar + 10 spacing + 26 beam + 20 chip + slack.
        isLandscape ? 124 : 132
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
                StatChip(text: capture.hitterPresent ? "Hitter detected ✓" : "Looking for hitter…",
                         color: capture.hitterPresent ? Theme.pass : Theme.steel)
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
    private func framingGuide(rightInset: Double, topInset: Double,
                              bottomInset: Double) -> some View {
        GeometryReader { geo in
            guideDrawing(in: geo.size, rightInset: rightInset,
                         topInset: topInset, bottomInset: bottomInset)
        }
        // Critical: the whole point of the overlay is that taps reach the
        // preview underneath so the user can tap the ball.
        .allowsHitTesting(false)
    }

    /// Deliberately a plain function rather than a `@ViewBuilder` body: it
    /// declares local helpers and returns explicitly, neither of which a result
    /// builder allows.
    ///
    /// `rightInset` and `topInset` are the fractions of the frame the control
    /// panels cover. Everything the guide draws stays out of them, so nothing
    /// has to be nudged by hand when a panel changes size.
    private func guideDrawing(in size: CGSize, rightInset: Double,
                              topInset: Double, bottomInset: Double) -> some View {
        let w = size.width, h = size.height
        let isLandscape = w > h
        let flip = model.settings.hitterOnLeft ? 1.0 : -1.0
        // Mirror about the centre when the hitter works the other way.
        func px(_ nx: Double) -> Double { (0.5 + (nx - 0.5) * flip) * w }
        func py(_ ny: Double) -> Double { ny * h }
        func pt(_ nx: Double, _ ny: Double) -> CGPoint { CGPoint(x: px(nx), y: py(ny)) }

        // Both the size AND the height in frame come from the real optics, so
        // standing the hitter inside the outline *is* the distance check.
        // Guessing either would be wrong by a factor of two between portrait
        // and landscape, because filling the screen crops a different amount of
        // the sensor in each.
        let g = guideGeometry(isLandscape: isLandscape, screenAspect: w / max(1, h))
        let figureH = g.heightFraction
        let figureW = figureH * BatterOutline.aspect * (h / max(1, w))
        // Where a standing hitter's feet actually land, not where a panel
        // leaves room. An earlier version picked this from the panel layout and
        // switched between two values, so the whole guide jumped down the
        // screen the moment the distance card collapsed. The panels are drawn
        // over the guide instead — that is what the z-order is for.
        let footY = g.footFraction
        let headY = footY - figureH
        let centreX = 0.22
        // Contact happens around belt height, a little over half way up.
        let ballY = footY - figureH * 0.46
        let teeX = centreX + figureW * 0.62
        // Where the flight arrow may run. `rightInset` keeps it clear of the
        // control column; `topInset` keeps the arc from climbing through the
        // bubble level, which a bare 0.10 screen-top floor did not.
        let flightEndX = min(0.93, 1 - rightInset - 0.04)
        let arrowTopY = max(topInset + 0.03, ballY - (isLandscape ? 0.30 : 0.22))

        // The outline is drawn for ONE camera: level, at contact height. Match
        // it from anywhere else and it is decoration wearing the clothes of an
        // instruction — see `CameraPose` for why two constraints cannot pin
        // down three unknowns. When the pose is wrong the guide goes red and
        // says so, because a confident yellow figure over a phone lying in the
        // grass is how the first real clip got filmed.
        let valid = CameraPose.outlineIsValid(
            tiltDeg: wizard.level.hasReading ? wizard.level.tiltDeg : nil,
            tiltToleranceDeg: wizard.level.tiltToleranceDeg,
            lensHeightM: wizard.lensHeightEstimateM)
        let ink = valid ? Theme.yellow : Theme.fail

        return ZStack {
            BatterOutline()
                .foregroundStyle(ink.opacity(0.9))
                .frame(width: figureW * w, height: figureH * h)
                .scaleEffect(x: flip, y: 1, anchor: .center)
                .position(pt(centreX, (headY + footY) / 2))
                .shadow(color: .black.opacity(0.55), radius: 4)

            // Tee and ball, in front of the hitter at contact height.
            Path { p in
                p.move(to: pt(teeX, footY))
                p.addLine(to: pt(teeX, ballY + 0.012))
            }
            .stroke(ink.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            Circle()
                .strokeBorder(ink, lineWidth: 2.5)
                .frame(width: 0.042 * min(w, h), height: 0.042 * min(w, h))
                .position(pt(teeX, ballY))
            // One short word, clear of the artwork. "BALL ON TEE" was long
            // enough to reach back across the batter's shoulder, and below the
            // ball is where the hitter's caption goes — that pair collided into
            // "STAND HERETEE".
            guideLabel("BALL", at: pt(teeX, ballY - 0.075), small: true, ink: ink)

            // Where the ball goes — the whole reason the frame is composed
            // this way, and the thing the old guide never said.
            Path { p in
                p.move(to: pt(teeX + 0.05, ballY - 0.01))
                p.addQuadCurve(to: pt(flightEndX, arrowTopY),
                               control: pt(teeX + (flightEndX - teeX) * 0.55,
                                           arrowTopY + 0.06))
            }
            .stroke(ink.opacity(0.75),
                    style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
            // Arrowhead in points, not in fractions of each axis. Fractions
            // are stretched by the screen's own aspect, which in landscape
            // turned the head into a flat wedge.
            Path { p in
                let tip = pt(flightEndX, arrowTopY)
                let a = 0.032 * min(w, h)
                p.move(to: CGPoint(x: tip.x - flip * a * 1.15, y: tip.y - a * 0.5))
                p.addLine(to: tip)
                p.addLine(to: CGPoint(x: tip.x - flip * a * 0.85, y: tip.y + a * 1.05))
            }
            .stroke(ink,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            // Tucked under the arrowhead, a third of the way along rather than
            // halfway. Halfway and low put it inside the control column once
            // the column was allowed to be short, and above the arc put it on
            // the level bar; between the two is the one band that is clear in
            // every orientation and both panel states.
            guideLabel("BALL FLIES THIS WAY",
                       at: pt(teeX + (flightEndX - teeX) * 0.35, arrowTopY + 0.06),
                       ink: ink)

            // Two short lines rather than one long one. A single 30-character
            // caption centred on the batter — who stands near the edge, which
            // is the whole point of the framing — ran off the side of the
            // screen in portrait, and nothing clips or wraps a positioned Text.
            VStack(spacing: 1) {
                Text("STAND HERE")
                    .font(Theme.label(11)).tracking(1.4)
                Text("FACING CAMERA")
                    .font(Theme.label(9)).tracking(1.2)
                    .opacity(0.8)
            }
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(0.9), radius: 3)
            // Clamped above the bottom panel. The FIGURE is never moved to fit
            // — its size and position are the distance check, and shifting it
            // would quietly change what the user is calibrating against — but
            // the caption is only a caption, so it rides up onto the legs
            // rather than disappearing behind a translucent card and reading
            // through the body text underneath it.
            .position(pt(centreX,
                         min(footY + 0.045, 1 - bottomInset - 0.02)))

            // The one line that would have saved the first field trip. It sits
            // ON the guide rather than in the advisory list, because the guide
            // is what the user is looking at while they move the tripod.
            // Only when the tilt is past what the rectifier can undo. A camera
            // aiming up six degrees is a corrected camera, not a broken one,
            // and shouting AIM LEVEL FIRST at it in red — over an outline, a
            // horizon band, a flight arrow and a distance card — was both
            // wrong and most of the noise on this screen.
            if !valid, showsHardWarning {
                Text(invalidGuideReason)
                    .font(Theme.label(10)).tracking(1.1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    // Width before padding, or the background sizes itself to
                    // the unwrapped line and the text spills out of it.
                    .frame(maxWidth: w * 0.66)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.fail.opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
                    // Centred, not on the batter: mirroring the guide would
                    // otherwise swing this off the side of the screen, and it
                    // is a message about the whole shot rather than about the
                    // figure it sits above.
                    .position(x: w * 0.5,
                              y: CGFloat(py(max(topInset + 0.07, headY - 0.06))))
            }
        }
    }

    /// Whether the placement is bad enough to say so loudly.
    ///
    /// The bar moved when tilt stopped being a requirement. Inside
    /// `tiltCorrectableMaxDeg` the track is warped back to a level view before
    /// anything is measured and the reading is exact under a pinhole model —
    /// measured error at 20 degrees of tilt is about a degree of launch angle,
    /// and zero once the rectifier has run. That is not a red banner; it is a
    /// correction the app makes silently and records. Past the correctable
    /// range it is, because there the lens's own distortion takes over and
    /// nothing downstream can undo it.
    private var showsHardWarning: Bool {
        let level = wizard.level
        return level.hasReading && abs(level.tiltDeg) > SLA.tiltCorrectableMaxDeg
    }

    /// Why the outline is not a target right now, worst cause first.
    ///
    /// Tilt outranks height because it is both the more damaging fault and the
    /// one people cause while trying to fix the other: a tripod that will not
    /// reach belt height invites aiming the phone up, which trades a harmless
    /// error for a real one.
    private var invalidGuideReason: String {
        let level = wizard.level
        if level.hasReading, abs(level.tiltDeg) > SLA.tiltCorrectableMaxDeg {
            return String(format: "AIMING %.0f° %@ — TOO STEEP TO CORRECT\nBRING IT CLOSER TO LEVEL",
                          abs(level.tiltDeg), level.tiltDeg > 0 ? "DOWN" : "UP")
        }
        if let h = wizard.lensHeightEstimateM {
            return String(format: "LENS IS %.1f M UP, OUTLINE IS DRAWN FOR 1.1 M\n%@ — BUT KEEP IT LEVEL",
                          h, h < CameraPose.idealLensHeightM ? "RAISE THE TRIPOD" : "LOWER THE TRIPOD")
        }
        return "OUTLINE NOT VALID FOR THIS CAMERA POSITION"
    }

    /// How a 1.75 m hitter standing 5.25 m from a level, contact-height camera
    /// appears: how tall, as a fraction of screen height, and where their feet
    /// land in the frame.
    ///
    /// Both numbers come from the same projection, which is the point — the
    /// outline is a calibration target, so its size and its position have to be
    /// the same claim about the same geometry. The preview fills the screen and
    /// crops the sensor differently in each orientation: in portrait the
    /// screen's long axis spans the camera's full horizontal field of view,
    /// while in landscape the screen's *width* spans it and the visible
    /// vertical angle is narrowed by the screen's aspect ratio. The same person
    /// is therefore about a third of the height in portrait and roughly two
    /// thirds in landscape.
    private func guideGeometry(isLandscape: Bool,
                               screenAspect: Double) -> (heightFraction: Double, footFraction: Double) {
        let targetDistanceM = 5.25      // middle of the 4.5-6 m window
        let hitterHeightM = 1.75
        let lensHeightM = 1.1           // contact height, per CAPTURE_PROTOCOL
        let fov = capture.fieldOfViewDeg
        let fallback = (heightFraction: isLandscape ? 0.62 : 0.30,
                        footFraction: isLandscape ? 0.80 : 0.64)
        guard fov > 5 else { return fallback }

        // Through CameraPose, which also places the horizon guide on this
        // same preview. Two framing aids deriving the crop independently is
        // how a future correction moves one and not the other, and the two
        // contradict each other on the one screen meant to be trusted.
        guard let vHalfDeg = CameraPose.visibleVerticalHalfAngleDeg(
            horizontalFovDeg: fov, isLandscape: isLandscape,
            screenAspect: screenAspect) else { return fallback }
        let visibleMetres = 2 * targetDistanceM * tan(vHalfDeg * .pi / 180)
        guard visibleMetres > 0.1 else { return fallback }

        // The lens is at contact height, so the ground is `lensHeightM` below
        // the optical axis — which is the centre of the frame.
        let height = min(0.80, max(0.15, hitterHeightM / visibleMetres))
        let foot = min(0.90, max(height + 0.12, 0.5 + lensHeightM / visibleMetres))
        return (height, foot)
    }

    private func guideLabel(_ text: String, at point: CGPoint,
                            small: Bool = false,
                            ink: Color = Theme.yellow) -> some View {
        Text(text)
            .font(Theme.label(small ? 9 : 11))
            .tracking(1.4)
            .foregroundStyle(ink.opacity(small ? 0.7 : 0.9))
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

            HStack(spacing: 6) {
                StatChip(text: levelChip.text, color: levelChip.color)
                // Only once it is actually known. A permanent "height unknown"
                // chip would be one more thing to learn to ignore, and the
                // estimate needs a hitter stood in frame with the distance
                // already measured — a state the user reaches on their own.
                if let h = heightChip {
                    StatChip(text: h.text, color: h.color)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The measured lens height, once the pose, the distance and the tilt are
    /// all in. This is the reading the batter outline could never give.
    private var heightChip: (text: String, color: Color)? {
        guard let h = wizard.lensHeightEstimateM else { return nil }
        let ok = wizard.isLensHeightOK == true
        return (String(format: "Lens %.1f m up%@", h, ok ? " ✓" : ""),
                ok ? Theme.pass : Theme.warn)
    }

    /// Plain function, not a `@ViewBuilder`: the branching is about *words*,
    /// and picking the words first keeps the view a single unconditional chip.
    private var levelChip: (text: String, color: Color) {
        let level = wizard.level
        guard level.isAvailable, level.hasReading else {
            return ("Level unknown", Theme.steel)
        }
        if level.isLevel { return ("Level ✓", Theme.pass) }
        guard !level.isTiltOK else {
            return ("Slightly off level — corrected", Theme.warn)
        }
        // Tilt used to read "still fine", which quietly encouraged aiming the
        // phone up at contact height when the tripod was short. It is not
        // fine — it is corrected, and only up to a point.
        let dir = level.tiltDeg > 0 ? "down" : "up"
        let mag = abs(level.tiltDeg)
        if !wizard.canCorrectTilt {
            return (String(format: "Aiming %@ %.0f° — lens unknown", dir, mag), Theme.fail)
        }
        if wizard.isTiltCorrectable {
            return (String(format: "Aiming %@ %.0f° — corrected ✓", dir, mag), Theme.warn)
        }
        return (String(format: "Aiming %@ %.0f° — too steep", dir, mag), Theme.fail)
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
            Button { withAnimation(.easeInOut(duration: 0.18)) { cardCollapsed.toggle() } } label: {
                HStack(spacing: 8) {
                    Text("Distance")
                        .font(Theme.label(12)).tracking(1)
                        .foregroundStyle(Theme.steel)
                    Spacer(minLength: 0)
                    if let m = wizard.derivedDistanceM {
                        Text(String(format: "≈ %.1f m", m))
                            .font(Theme.numeral(22))
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
                        Text("not set")
                            .font(Theme.label(12))
                            .foregroundStyle(Theme.steel)
                    }
                    Image(systemName: cardCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Theme.yellow)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !cardCollapsed {
                instruction

                // The fallback is a first-class option, not a hidden one.
                // There may be no ball to hand, it may be too dark, or the
                // ball may be sitting on something its own colour — in every
                // one of those cases the user still needs a way to finish.
                HStack(spacing: 8) {
                    Button { showDistanceEntry = true } label: {
                        Text("No ball? Type distance")
                    }
                    .buttonStyle(OutlineButtonStyle(verticalPadding: 10))

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
                            .frame(width: 40)
                    }
                    .buttonStyle(OutlineButtonStyle(verticalPadding: 10))
                    .frame(width: 52)
                }
            }
        }
        .padding(12)
        // Nearly opaque, not 0.65. This card carries several lines of body
        // copy, and the framing guide is drawn behind it — at 0.65 the guide's
        // captions read straight through the paragraph, which looked like the
        // text had been printed twice.
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        // Swallow taps: without this, tapping the card would fall through to
        // the preview and be read as "the ball is here".
        .contentShape(Rectangle())
        // A successful measurement is the panel's whole job. Getting out of
        // the way afterwards is more useful than staying open to be admired.
        .onChange(of: wizard.scaleSource) { _, source in
            if source != .none {
                withAnimation(.easeInOut(duration: 0.18)) { cardCollapsed = true }
            }
        }
        // ...but a tap always reopens it first, so whatever comes back — the
        // diameter, or the reason it was rejected and the detector's
        // diagnostic line — is on screen rather than behind a chevron.
        //
        // Reopening on the tap, rather than refusing to close while there is
        // something to read: the earlier version did the latter and a failed
        // measurement then jammed the panel open, because the collapse button
        // was fighting a condition that never cleared. An explicit tap on the
        // header must always win.
        .onChange(of: measuring) { _, isMeasuring in
            if isMeasuring {
                withAnimation(.easeInOut(duration: 0.18)) { cardCollapsed = false }
            }
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
        if let report = capture.lastMeasureReport {
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(advice.level == .warning ? Theme.warn : Theme.steel)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onArm) {
                Text(wizard.isArmingAllowed ? "Arm — let's hit" : "Arm")
            }
            .buttonStyle(SlabButtonStyle(fill: wizard.isArmingAllowed ? Theme.yellow : Theme.surface,
                                         textColor: wizard.isArmingAllowed ? .black : Theme.steel,
                                         size: 18, verticalPadding: 15))
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

/// The batter, drawn from the artwork in `Assets.xcassets/BatterOutline`.
///
/// The PNG is an alpha-only line drawing — every pixel is black with the ink in
/// the alpha channel — so `.renderingMode(.template)` tints the whole figure a
/// single colour and nothing of the original black survives. That is why it can
/// be shipped as-is rather than re-traced: the asset already *is* a mask.
///
/// It replaces a hand-traced `Shape`. The trace was close but not the drawing,
/// and "close but not it" is worse than either — the guide is meant to be
/// recognised at a glance over live video, not admired.
struct BatterOutline: View {
    /// Width ÷ height of the artwork (421 × 970 px), including the raised bat.
    /// Used to size the figure from the optics, so this must track the asset:
    /// re-crop the PNG and this number changes with it.
    static let aspect = 421.0 / 970.0

    var body: some View {
        Image("BatterOutline")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
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
                    sectionLabel("From above — right", Theme.pass)
                    diagram
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    // The failure this app was actually handed, drawn rather
                    // than described. Every number comes from the ball's path
                    // ACROSS the image, so a ball flying at the lens is
                    // foreshortened: it reads slow, and no amount of detector
                    // tuning recovers it. The right-hand picture is the only
                    // one that says which arrangements are wrong, and it is
                    // the one the framing outline can never draw, because the
                    // outline only ever sees the shot from the camera.
                    sectionLabel("From above — wrong", Theme.fail)
                    wrongDiagram
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    sectionLabel("From the side", Theme.pass)
                    sideDiagram
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

                    tip("1", "Side-on to the flight, never behind",
                        "Square to the ball's flight, on the side the hitter FACES — first-base side for a right-hander, third-base side for a left-hander. Behind them their own body hides the bat at contact.")
                    tip("2", "Five to seven big steps",
                        "That's 4.5–6 m. Closer and the ball leaves the frame too fast; further and it gets too small to measure.")
                    tip("3", "Put the dashed line in the green band",
                        "That line is the real horizon — where level falls in the picture. Aim the phone until it sits inside the band and the phone is level, whatever the ground under the tripod is doing. If the line is off the bottom of the screen you are aiming up; off the top, you are aiming down. This is the check the batter outline cannot do for you: the outline can be matched perfectly from a phone lying in the grass, because moving back and tilting up fits a person into it just as well as standing it at belt height does.")
                    tip("4", "As high as the tripod goes — but keep it level",
                        "Belt height (about 1.1 m, where bat meets ball) is ideal. Once a hitter is stood in frame and the ball has been tapped, the setup screen shows the height it has actually measured — the outline alone can never tell, which is why it used to look right from the ground. A shorter tripod is fine: a level camera sitting low sees exactly the same geometry, just with the ball higher in the picture. What costs you accuracy is tilting the phone UP to point at contact height — so if it won't reach, leave it level and let the ball ride high in frame.")
                    tip("5", "Tap the ball on screen",
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

    private func sectionLabel(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(Theme.label(11)).tracking(1.3)
            .foregroundStyle(colour)
    }

    /// The two ways people actually get this wrong, side by side.
    ///
    /// Both are drawn from above with the same hitter in the same place, so
    /// the only thing that changes between this and the diagram above it is
    /// where the phone sits — which is the entire lesson.
    private var wrongDiagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height

            func cross(at p: CGPoint) {
                var x = Path()
                let a: CGFloat = 9
                x.move(to: CGPoint(x: p.x - a, y: p.y - a))
                x.addLine(to: CGPoint(x: p.x + a, y: p.y + a))
                x.move(to: CGPoint(x: p.x + a, y: p.y - a))
                x.addLine(to: CGPoint(x: p.x - a, y: p.y + a))
                context.stroke(x, with: .color(Theme.fail),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Left half: the phone downrange, ball flying into the lens.
            let hitterA = CGPoint(x: w * 0.10, y: h * 0.62)
            let phoneA = CGPoint(x: w * 0.40, y: h * 0.30)
            var flightA = Path()
            flightA.move(to: hitterA)
            flightA.addLine(to: CGPoint(x: phoneA.x - 6, y: phoneA.y + 10))
            context.stroke(flightA, with: .color(Theme.fail),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            context.fill(Path(ellipseIn: CGRect(x: hitterA.x - 8, y: hitterA.y - 8, width: 16, height: 16)),
                         with: .color(.white))
            context.fill(Path(roundedRect: CGRect(x: phoneA.x - 6, y: phoneA.y - 11, width: 12, height: 22), cornerRadius: 3),
                         with: .color(Theme.fail))
            cross(at: CGPoint(x: w * 0.25, y: h * 0.44))
            context.draw(Text("BALL FLIES AT THE LENS").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.25, y: h * 0.80))
            context.draw(Text("reads slow — flagged for depth")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.25, y: h * 0.90))

            // Right half: the phone behind the hitter.
            let hitterB = CGPoint(x: w * 0.72, y: h * 0.50)
            let phoneB = CGPoint(x: w * 0.60, y: h * 0.50)
            var flightB = Path()
            flightB.move(to: hitterB)
            flightB.addLine(to: CGPoint(x: w * 0.97, y: h * 0.38))
            context.stroke(flightB, with: .color(Theme.fail),
                           style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            context.fill(Path(ellipseIn: CGRect(x: hitterB.x - 8, y: hitterB.y - 8, width: 16, height: 16)),
                         with: .color(.white))
            context.fill(Path(roundedRect: CGRect(x: phoneB.x - 6, y: phoneB.y - 11, width: 12, height: 22), cornerRadius: 3),
                         with: .color(Theme.fail))
            cross(at: CGPoint(x: w * 0.66, y: h * 0.30))
            context.draw(Text("PHONE BEHIND THE HITTER").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.74, y: h * 0.80))
            context.draw(Text("their body hides the bat")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.74, y: h * 0.90))
        }
        .padding(10)
    }

    /// Side elevation: the height question, which no overhead view can show
    /// and which the framing outline silently assumes an answer to.
    private var sideDiagram: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let ground = h * 0.80

            var g = Path()
            g.move(to: CGPoint(x: 0, y: ground))
            g.addLine(to: CGPoint(x: w, y: ground))
            context.stroke(g, with: .color(.white.opacity(0.3)), lineWidth: 1.5)

            // Hitter and contact point.
            let hx = w * 0.22
            var body = Path()
            body.move(to: CGPoint(x: hx, y: ground))
            body.addLine(to: CGPoint(x: hx, y: ground - h * 0.44))
            context.stroke(body, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: hx - 6, y: ground - h * 0.54, width: 12, height: 12)),
                         with: .color(.white))
            let contactY = ground - h * 0.28
            context.fill(Path(ellipseIn: CGRect(x: hx + 16, y: contactY - 5, width: 10, height: 10)),
                         with: .color(Theme.yellow))

            // The right camera: level, at contact height.
            let cx = w * 0.74
            var tripod = Path()
            tripod.move(to: CGPoint(x: cx, y: contactY))
            tripod.addLine(to: CGPoint(x: cx, y: ground))
            context.stroke(tripod, with: .color(Theme.steel),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            context.fill(Path(roundedRect: CGRect(x: cx - 9, y: contactY - 7, width: 18, height: 14), cornerRadius: 3),
                         with: .color(Theme.pass))
            var sight = Path()
            sight.move(to: CGPoint(x: cx - 10, y: contactY))
            sight.addLine(to: CGPoint(x: hx + 26, y: contactY))
            context.stroke(sight, with: .color(Theme.pass.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            context.draw(Text("LEVEL, 1.1 M").font(Theme.label(9)).foregroundStyle(Theme.pass),
                         at: CGPoint(x: cx + 4, y: contactY - 20))

            // The wrong one: on the ground, aimed up to compensate.
            var badSight = Path()
            badSight.move(to: CGPoint(x: w * 0.90, y: ground - 6))
            badSight.addLine(to: CGPoint(x: hx + 30, y: contactY - h * 0.10))
            context.stroke(badSight, with: .color(Theme.fail.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            context.fill(Path(roundedRect: CGRect(x: w * 0.90 - 9, y: ground - 13, width: 18, height: 14), cornerRadius: 3),
                         with: .color(Theme.fail))
            context.draw(Text("ON THE GROUND, AIMED UP").font(Theme.label(9)).foregroundStyle(Theme.fail),
                         at: CGPoint(x: w * 0.72, y: ground + 16))
            context.draw(Text("the outline still matches — that is the trap")
                            .font(Theme.label(8)).foregroundStyle(.white.opacity(0.65)),
                         at: CGPoint(x: w * 0.5, y: ground + 30))
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
