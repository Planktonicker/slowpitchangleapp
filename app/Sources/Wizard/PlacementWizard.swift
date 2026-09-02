// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import CoreGraphics
import Foundation
import ImageIO

/// Camera placement state, in three skippable stages: level, hitter, arm.
///
/// Nothing here blocks arming — see `isArmingAllowed` — and every reading is
/// scaled from pixels, so a camera that moved between sessions changes the
/// numbers silently. What the stages produce is a distance and a lens height,
/// and a record of which of them were skipped.
///
/// What changed from v0.1: ARKit is gone. It fought the 240fps capture session
/// for the camera (the field-test black screen) and made setup feel like
/// surveying. Distance now falls out of optics instead — something of known
/// size in frame plus the lens field of view gives both the scale AND the
/// distance in one measurement, with the live preview running the whole time.
///
/// The default something is the **hitter**, who is already standing there: the
/// nose-to-ankle span of a person of known height, gated on an upright pose.
/// It is ten times more precise than the 26 px ball at this distance and needs
/// no prop and no walk out to the tee. The ball, the plate and a typed distance
/// remain, one menu deep, for when there is no hitter in frame.
@MainActor
final class PlacementWizard: ObservableObject {

    /// Where the pixels-per-metre scale came from.
    enum ScaleSource: String, Codable {
        case none
        case hitter     // the hitter's own nose-to-ankle span — the default path
        case ball       // tap-the-ball auto measure
        case plate      // dragged markers on home plate, front edge to rear point
        case manual     // typed distance, scale predicted from FOV
    }

    /// Home plate, front edge to rear point: 17 in, and the one hard dimension
    /// available at every field.
    ///
    /// Named for the *depth* of the plate, not its width, because the protocol
    /// camera is side-on and perpendicular to the pitch line — so this 17 in
    /// runs along that line, which is across the picture, and is the span the
    /// markers measure. The plate's 17 in front edge is the wrong one: it faces
    /// the pitcher, points at the lens, and is seen end-on, so the pixels
    /// between its two corners are depth foreshortening rather than 43 cm. A
    /// distance derived from them is not slightly wrong, it is arbitrary.
    static let plateDepthM = 17.0 * 0.0254

    // MARK: - Inputs

    let level = LevelSensor()

    /// From the active capture format; needed to turn scale into distance.
    @Published var imageWidthPx: Double = Double(SLA.targetWidth)
    @Published var imageHeightPx: Double = Double(SLA.targetHeight)
    @Published var fieldOfViewDeg: Double = 0

    /// The two plate markers, in **capture-device** coordinates.
    ///
    /// Device, not view. They used to be normalized against the SwiftUI view
    /// while the preview is aspect-filled and safe-area-inset differently, so
    /// the handles measured a different picture from the one under them. The
    /// preview layer's own `captureDevicePointConverted(fromLayerPoint:)` is
    /// the only thing that knows about the fill crop, the rotation and the
    /// mirroring at once.
    @Published var plateStart = CGPoint(x: 0.36, y: 0.72)
    @Published var plateEnd = CGPoint(x: 0.46, y: 0.72)

    @Published var manualDistanceM: Double = 6

    /// Where the hitter's feet sit in the capture buffer, 0 at the top and 1
    /// at the bottom, smoothed from the live pose. Fed in by the setup overlay
    /// because that is the only screen that runs pose.
    ///
    /// It is here rather than in the overlay because it is the third leg of
    /// the camera-height estimate, and the other two — tilt and distance —
    /// already live on this object.
    @Published private(set) var hitterFeetFraction: Double?

    @Published private(set) var scaleSource: ScaleSource = .none
    @Published private(set) var measuredPxPerM: Double?
    /// Ball diameter from the last successful tap-measure, for display.
    @Published private(set) var lastBallDiameterPx: Double?

    // MARK: - Stages

    /// The setup screen in order: aim it level, measure the hitter, arm.
    ///
    /// Ordered because each stage assumes the one before it — the distance is
    /// measured in a tilt-rectified frame, so a wildly off-level camera makes
    /// the measurement worse — and every one of them skippable, because none of
    /// them blocks arming and pretending otherwise is how a user learns to
    /// distrust the screen.
    enum SetupStage: Int, CaseIterable { case level, hitter, ready }

    @Published private(set) var stage: SetupStage = .level

    /// How the camera distance is being measured right now.
    ///
    /// Replaces the old `showPlateMarkers` flag. One method at a time is a
    /// state, not two independent booleans that could both be true — and the
    /// preview needs to know which one, because plate mode is the only one that
    /// takes over the touches with handles and a display zoom.
    enum DistanceMethod: Equatable { case hitter, ball, plate }

    @Published var distanceMethod: DistanceMethod = .hitter

    /// What the hitter stage is doing, as one value.
    ///
    /// Published as a single enum rather than as a handful of separate
    /// properties so the panel re-renders on *transitions*, not on every 10 Hz
    /// pose sample. Reaching a lock changes this at most six times.
    enum HitterScaleState: Equatable {
        /// Nobody has said how tall the hitter is, so there is nothing to scale
        /// the span against.
        case needHeight
        /// Portrait. The buffer is landscape-native, so there is no upright
        /// reading to take — the same rule `feetFraction` follows.
        case landscapeNeeded
        case noHitter
        case notUpright(HitterScale.Rejection)
        case sampling(accepted: Int, needed: Int)
        case locked
    }

    @Published private(set) var hitterScaleState: HitterScaleState = .needHeight

    /// Which way up the capture buffer is, synced from the camera by `AppModel`.
    @Published var bufferOrientation: CGImagePropertyOrientation = .up

    /// The hitter's standing height, in metres, synced from settings.
    ///
    /// Deliberately **not** `@Published`: it changes when somebody types in
    /// Settings, which is a handful of times in the app's life, and adding it to
    /// the published set would put it in the same invalidation path as the 10 Hz
    /// readings this object works hard to keep out of. The explicit send in
    /// `willSet` is the honest version of that trade.
    var hitterHeightM: Double? {
        willSet { if newValue != hitterHeightM { objectWillChange.send() } }
        didSet {
            guard hitterHeightM != oldValue else { return }
            // A locked measurement is a span in pixels; the height is only what
            // that span is divided by. Correcting a mistyped height therefore
            // does not need the hitter to stand there again.
            if scaleSource == .hitter, let span = lockedSpanPx,
               let h = hitterHeightM, h > 0 {
                measuredPxPerM = HitterScale.pxPerM(spanPx: span, hitterHeightM: h)
            }
            if hitterHeightM == nil, scaleSource == .none {
                forceHitterState(.needHeight)
            } else if hitterHeightM != nil, hitterScaleState == .needHeight {
                forceHitterState(.noHitter)
            }
        }
    }

    /// The nose-to-ankle span the lock was taken from, in rectified pixels.
    @Published private(set) var lockedSpanPx: Double?

    /// Played once, when the distance locks.
    ///
    /// Injectable so tests can silence it. The default is a synthesised tone
    /// rather than a system sound because `AudioServicesPlaySystemSound` obeys
    /// the Ring/Silent switch, and a muted phone on a tripod is exactly the
    /// solo-user case this whole measurement exists for.
    var lockChime: () -> Void = { SetupChime.shared.play() }

    /// The rolling window of accepted samples. Never published: it moves at the
    /// pose model's rate, and nothing on screen shows more than its count.
    private var sampler = HitterScale.Sampler()

    /// When `hitterScaleState` last changed, on the caller's clock.
    private var lastHitterStateChangeAt: TimeInterval?

    private var cancellables = Set<AnyCancellable>()

    init() {
        level.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Record where the pose currently puts the hitter's feet.
    ///
    /// Smoothed, because ankle keypoints jitter by a percent or two of frame
    /// height between frames and the height readout is quoted to 10 cm — an
    /// unfiltered number would flicker enough to look broken even while being
    /// well inside tolerance.
    ///
    /// Deliberately never cleared from here. The hitter stepping out of frame
    /// does not move the tripod, and closing the setup overlay stops pose
    /// entirely — so a self-clearing value would erase the estimate at exactly
    /// the moment it needs to survive, which is when swings start being
    /// stamped with it. `clearScale()` retires it instead, because
    /// re-measuring the distance is the thing that actually signals the camera
    /// moved.
    func noteHitterFeet(_ fraction: Double) {
        guard fraction.isFinite else { return }
        guard let previous = smoothedFeet else {
            smoothedFeet = fraction
            hitterFeetFraction = fraction
            return
        }
        let next = previous + (fraction - previous) * 0.25
        smoothedFeet = next
        // Published only on a change worth seeing. The pose arrives at 10 Hz
        // and an EMA moves on every single sample, so assigning straight to
        // the @Published property republished this object — and with it the
        // whole setup overlay, every Path in the framing guide included — ten
        // times a second, forever, while a hitter stood in frame. A twentieth
        // of a percent of frame height is about a centimetre of camera height
        // at five metres: below the resolution of anything that reads it.
        if let shown = hitterFeetFraction, abs(next - shown) < 0.0005 { return }
        hitterFeetFraction = next
    }

    /// The running average, kept off the published property so smoothing does
    /// not itself become a source of view invalidation.
    private var smoothedFeet: Double?

    // MARK: - Stage navigation

    /// Start setup at the top. Called when the overlay opens, so re-opening it
    /// after arming does not drop the user back into whichever stage they last
    /// happened to be looking at.
    func beginSetup() {
        go(to: .level)
    }

    func advance() {
        guard let next = SetupStage(rawValue: stage.rawValue + 1) else { return }
        go(to: next)
    }

    func back() {
        guard let previous = SetupStage(rawValue: stage.rawValue - 1) else { return }
        go(to: previous)
    }

    /// Leave a stage without doing its job.
    ///
    /// The same transition as `advance`, named separately because it is a
    /// different act: nothing here blocks arming, and the flags on the swing
    /// record — `.levelUnknown`, `.cameraTilted`, `.distanceNotMeasured` — are
    /// what carry the fact that a stage was skipped.
    func skip() { advance() }

    func go(to next: SetupStage) {
        guard next != stage else { return }
        // Plate mode owns the preview's touches and its display zoom, so it
        // cannot be left running behind another stage. Dropping back to the
        // default method is what resets the zoom, via the marker binding going
        // nil in `CaptureView`.
        if stage == .hitter, distanceMethod == .plate { distanceMethod = .hitter }
        stage = next
    }

    // MARK: - Distance from the hitter

    /// Fold in one pose sample.
    ///
    /// `hitterPresent` is the capture gate's own held presence, which survives a
    /// frame the pose model lost — without it a single missed inference resets a
    /// count that is meant to reward standing still.
    func noteSkeleton(_ joints: [PoseJoint: CGPoint]?, hitterPresent: Bool,
                      at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Sampling only where it means something: the hitter stage, this
        // method, and only until a distance is locked. Anywhere else this is a
        // pose stream nobody asked a question of.
        guard stage == .hitter, distanceMethod == .hitter, scaleSource == .none else { return }

        guard let heightM = hitterHeightM, heightM > 0 else {
            setHitterState(.needHeight, at: now)
            return
        }
        guard let joints, !joints.isEmpty else {
            if hitterPresent, case .sampling = hitterScaleState { return }
            setHitterState(.noHitter, at: now)
            return
        }
        guard let upright = HitterScale.uprightPixels(joints, orientation: bufferOrientation,
                                                      widthPx: imageWidthPx,
                                                      heightPx: imageHeightPx) else {
            setHitterState(.landscapeNeeded, at: now)
            return
        }

        let focal = TiltRectifier.focalPx(widthPx: imageWidthPx, fovDeg: fieldOfViewDeg)
        let verdict = HitterScale.evaluate(upright: upright, tiltDeg: level.tiltDeg,
                                           focalPx: focal,
                                           cx: imageWidthPx / 2, cy: imageHeightPx / 2)
        switch verdict {
        case .rejected(let why):
            setHitterState(.notUpright(why), at: now)
        case .accepted(let spanPx):
            sampler.add(spanPx: spanPx, at: now)
            if let median = sampler.medianIfReady(at: now) {
                lockHitterScale(spanPx: median, heightM: heightM)
            } else {
                setHitterState(.sampling(accepted: sampler.count(at: now),
                                         needed: HitterScale.samplesNeeded), at: now)
            }
        }
    }

    /// Take the measurement and stop looking.
    ///
    /// Locked on purpose. What the hitter does after this — crouch, stride,
    /// swing — is irrelevant, because the tripod has not moved, and a distance
    /// that kept re-measuring itself would drift into the crouch the upright
    /// gate exists to exclude.
    private func lockHitterScale(spanPx: Double, heightM: Double) {
        lockedSpanPx = spanPx
        measuredPxPerM = HitterScale.pxPerM(spanPx: spanPx, hitterHeightM: heightM)
        scaleSource = .hitter
        // The diameter readout belongs to the ball path and would otherwise sit
        // there claiming to describe this measurement.
        lastBallDiameterPx = nil
        sampler.reset()
        forceHitterState(.locked)
        lockChime()
    }

    /// Unlock and start again, without changing which method is in use.
    func remeasureHitter() {
        clearScale()
        distanceMethod = .hitter
    }

    /// Assign only on a real change, and refuse a *downgrade* that arrives
    /// within half a second of the last one.
    ///
    /// The same rule `noteHitterFeet` follows, for the same reason. The pose
    /// model drops a joint now and then, and without this a count climbing to
    /// "4 of 5" flickered back through "Looking for the hitter…" on the way,
    /// which reads as the app losing someone who never moved.
    private func setHitterState(_ next: HitterScaleState, at now: TimeInterval) {
        guard next != hitterScaleState else { return }
        if Self.isDowngrade(from: hitterScaleState, to: next),
           let last = lastHitterStateChangeAt, now - last < 0.5 { return }
        hitterScaleState = next
        lastHitterStateChangeAt = now
    }

    /// A state change that is not a sample: a lock, a clear, a typed height.
    /// Never suppressed, and it clears the timer so the next sample is judged
    /// on its own.
    private func forceHitterState(_ next: HitterScaleState) {
        lastHitterStateChangeAt = nil
        guard next != hitterScaleState else { return }
        hitterScaleState = next
    }

    private static func isDowngrade(from: HitterScaleState, to: HitterScaleState) -> Bool {
        guard case .sampling = from else { return false }
        switch to {
        case .notUpright, .noHitter: return true
        default: return false
        }
    }

    // MARK: - Scale sources

    /// The one-tap path: the detector measured the resting ball at
    /// `diameterPx`; the ball is 9.7 cm across, so the scale is immediate.
    ///
    /// `atX`/`atY` are where in the frame it was measured, in pixels. They
    /// matter when the camera is tilted: the same ball reads bigger high in a
    /// down-aimed frame than it would to a level camera, and the derived
    /// distance would inherit that. Rectifying the diameter at the point it was
    /// measured keeps this number in the same frame as everything the analyzer
    /// reports.
    func applyBallMeasurement(diameterPx: Double, atX: Double, atY: Double) {
        let focal = TiltRectifier.focalPx(widthPx: imageWidthPx, fovDeg: fieldOfViewDeg)
        // Made upright first. The tap arrives in raw buffer pixels, and the
        // buffer is landscape-native whichever way the phone is held — so
        // filming landscape the other way up put the point in the wrong half of
        // the frame while the tilt sign stayed the same, which is a
        // magnification correction applied backwards.
        let upright = CameraPose.uprightBufferPoint(CGPoint(x: atX, y: atY),
                                                    orientation: bufferOrientation,
                                                    width: imageWidthPx, height: imageHeightPx)
        let magnification: Double
        if let upright {
            let r = TiltRectifier.rectify(x: Double(upright.x), y: Double(upright.y),
                                          tiltDeg: level.tiltDeg, focalPx: focal,
                                          cx: imageWidthPx / 2, cy: imageHeightPx / 2)
            magnification = r.magnification
        } else {
            // Portrait. There is no upright frame to rectify in, and refusing
            // the measurement outright would regress a ball tap that works
            // today — so the tilt correction is skipped and the raw diameter
            // stands, which is what happened before any of this existed.
            magnification = 1
        }
        // Reported raw, so the diagnostics line and the picture agree.
        lastBallDiameterPx = diameterPx
        measuredPxPerM = diameterPx * magnification / SLA.ballDiameterM
        scaleSource = .ball
        lockedSpanPx = nil
    }

    /// Recompute scale from the plate markers. Call whenever a handle moves.
    ///
    /// Both endpoints are rectified for camera tilt, exactly as the ball tap is.
    /// Without it the plate — which sits low in a down-aimed frame, where the
    /// projection stretches hardest — measured its own foreshortening.
    func applyPlateMeasurement() {
        let focal = TiltRectifier.focalPx(widthPx: imageWidthPx, fovDeg: fieldOfViewDeg)
        let a = rectifiedPlatePoint(plateStart, focalPx: focal)
        let b = rectifiedPlatePoint(plateEnd, focalPx: focal)
        let separation = hypot(b.x - a.x, b.y - a.y)
        // Two handles on top of each other is somebody mid-drag, not a plate.
        guard separation > 4 else { return }
        measuredPxPerM = separation / Self.plateDepthM
        scaleSource = .plate
        lockedSpanPx = nil
    }

    /// A device-normalized marker in rectified buffer pixels.
    ///
    /// Scaled per axis before anything else: the normalized axes are not
    /// isotropic, so converting both with the width overweighted any vertical
    /// component by the aspect ratio — 1.78x on 16:9 — and every number derived
    /// from the plate came out wrong whenever the span was not horizontal.
    private func rectifiedPlatePoint(_ p: CGPoint, focalPx: Double) -> (x: Double, y: Double) {
        let px = CGPoint(x: Double(p.x) * imageWidthPx, y: Double(p.y) * imageHeightPx)
        guard let upright = CameraPose.uprightBufferPoint(px, orientation: bufferOrientation,
                                                          width: imageWidthPx,
                                                          height: imageHeightPx) else {
            // Portrait: no upright frame, so no rectification — same choice as
            // the ball tap, and for the same reason.
            return (Double(px.x), Double(px.y))
        }
        let r = TiltRectifier.rectify(x: Double(upright.x), y: Double(upright.y),
                                      tiltDeg: level.tiltDeg, focalPx: focalPx,
                                      cx: imageWidthPx / 2, cy: imageHeightPx / 2)
        return (r.x, r.y)
    }

    /// Fallback: trust a tape-measured distance and predict the scale from
    /// the lens geometry instead of measuring it.
    func applyManualDistance() {
        // px/m at distance d is focal/d — through the parity-pinned focal
        // model rather than an inline copy of the FOV relation, so the wizard
        // and TiltRectifier can never disagree about the same lens (and this
        // inherits focalPx's fov<180 guard the copy lacked).
        guard manualDistanceM > 0 else { return }
        let focal = TiltRectifier.focalPx(widthPx: imageWidthPx, fovDeg: fieldOfViewDeg)
        guard focal > 0 else { return }
        measuredPxPerM = focal / manualDistanceM
        scaleSource = .manual
        lockedSpanPx = nil
    }

    /// Retire the measurement. Deliberately says nothing about which method is
    /// in use — clearing a reading is not choosing a different way to take one,
    /// and conflating them is how "Clear" silently threw the user out of plate
    /// mode with the handles still on screen.
    func clearScale() {
        measuredPxPerM = nil
        lastBallDiameterPx = nil
        hitterFeetFraction = nil
        smoothedFeet = nil
        scaleSource = .none
        lockedSpanPx = nil
        sampler.reset()
        // Never `.sampling(0, 5)`: "0 of 5" before anybody is in frame reads as
        // a broken counter rather than as a screen waiting for a hitter.
        forceHitterState(hitterHeightM == nil ? .needHeight : .noHitter)
    }

    // MARK: - Derived

    /// Distance from the camera, inverted from the measured scale and the
    /// field of view. For the manual source this just round-trips the typed
    /// value.
    var derivedDistanceM: Double? {
        if scaleSource == .manual { return manualDistanceM }
        guard let pxPerM = measuredPxPerM, pxPerM > 0 else { return nil }
        let focal = TiltRectifier.focalPx(widthPx: imageWidthPx, fovDeg: fieldOfViewDeg)
        guard focal > 0 else { return nil }
        return focal / pxPerM
    }

    /// Where the distance came from, in the words the summary row shows.
    ///
    /// The source is part of the reading, not a footnote: the hitter method
    /// measures the hitter's own plane, while the ball and the plate measure an
    /// object that sits roughly 0.7 m nearer the camera. No fudge offset is
    /// applied for that — it is inside every consumer's tolerance — but the
    /// number is labelled so nobody has to wonder why two methods disagree by
    /// about that much.
    var distanceSourceLabel: String? {
        switch scaleSource {
        case .none:   return nil
        case .hitter: return "hitter height"
        case .ball:   return "ball"
        case .plate:  return "plate"
        case .manual: return "typed"
        }
    }

    /// The level reading in one line, for the Ready stage's summary.
    ///
    /// The words used to live in the setup overlay's `levelChip`, which was one
    /// of six places the same angle was drawn. `ok` carries only pass / fail /
    /// unknown; where the distinction between "corrected" and "too steep"
    /// matters, the text says which, because a third colour would be a third
    /// reading.
    var tiltSummary: (text: String, ok: Bool?) {
        guard level.isAvailable, level.hasReading else { return ("Level unknown", nil) }
        if level.isLevel { return ("Level ✓", true) }
        guard !level.isTiltOK else { return ("Slightly off level — corrected", false) }
        let dir = level.tiltDeg > 0 ? "down" : "up"
        let mag = abs(level.tiltDeg)
        if !canCorrectTilt {
            return (String(format: "Aiming %@ %.0f° — lens unknown", dir, mag), false)
        }
        if isTiltCorrectable {
            return (String(format: "Aiming %@ %.0f° — corrected ✓", dir, mag), false)
        }
        return (String(format: "Aiming %@ %.0f° — too steep", dir, mag), false)
    }

    /// How high the lens is above the ground, solved from the hitter's feet.
    ///
    /// This is the number the batter outline could never supply. The outline
    /// constrains how tall the hitter is in frame and where their feet land —
    /// two facts — while the camera has three unknowns: distance, tilt and
    /// height. A phone lying on the grass and aimed up can match the outline
    /// exactly. Tilt comes from the IMU and distance from the ball tap, so
    /// the feet close the system and the height falls out.
    ///
    /// `nil` until all three are available, and `nil` when they contradict
    /// each other. See `CameraPose.lensHeightM`.
    var lensHeightEstimateM: Double? {
        guard let feet = hitterFeetFraction,
              let d = derivedDistanceM,
              level.isAvailable, level.hasReading,
              imageWidthPx > 0, imageHeightPx > 0,
              let vHalf = CameraPose.verticalHalfAngleDeg(
                  horizontalFovDeg: fieldOfViewDeg,
                  frameAspect: imageWidthPx / imageHeightPx)
        else { return nil }
        return CameraPose.lensHeightM(feetFraction: feet, distanceM: d,
                                      tiltDeg: level.tiltDeg,
                                      verticalHalfAngleDeg: vHalf)
    }

    /// Whether the lens is near the height the batter outline is drawn for.
    /// `nil` means not measured yet, which is not the same as wrong.
    var isLensHeightOK: Bool? {
        guard let h = lensHeightEstimateM else { return nil }
        return abs(h - CameraPose.idealLensHeightM) <= CameraPose.lensHeightToleranceM
    }

    /// The protocol's window is 4.5-6 m; 3.5-8.5 m is accepted with a nudge,
    /// so a cramped backyard still works — flagged, not forbidden.
    var isDistanceIdeal: Bool {
        guard let m = derivedDistanceM else { return false }
        return m >= 4.5 && m <= 6.0
    }

    var isDistanceAcceptable: Bool {
        guard let m = derivedDistanceM else { return false }
        return m >= 3.5 && m <= 8.5
    }

    /// Distances where the optics genuinely cannot work, as opposed to merely
    /// being outside the protocol's preferred window.
    var isDistanceAbsurd: Bool {
        guard let m = derivedDistanceM else { return false }
        return m < 1.5 || m > 18
    }

    /// Nothing blocks arming any more.
    ///
    /// This gate has been shrinking as it turned out that each thing it
    /// demanded was either corrected downstream or not used at all, and it has
    /// now reached zero. The last item was the camera distance, and the reason
    /// is worth writing down because it is not obvious: **the measurement does
    /// not use it**. Exit velocity is pixels per second times metres per pixel,
    /// and the metres per pixel come from the ball's own apparent diameter in
    /// the flight frames — `analyze_track` computes it from the track and
    /// hands it to the gravity solve as `scale_hint`. Nothing in `ClipAnalyzer`
    /// reads the placement distance at all.
    ///
    /// So the app was refusing to record a swing it could measure perfectly,
    /// pending a number it would then ignore. What the distance is genuinely
    /// worth is the sound-travel correction on contact time (three frames at
    /// 240fps) and a lens-height estimate. Both are improvements, neither is a
    /// precondition, and the record says which swings were taken without them.
    ///
    /// Level went the same way earlier: roll is corrected downstream in
    /// `SwingAnalyzer` — blocking on a quantity we already take back out was
    /// self-defeating — and tilt is rectified, degrading smoothly rather than
    /// falling off a cliff at 3 degrees.
    var isArmingAllowed: Bool { true }

    /// True when the swing about to be recorded will be missing something the
    /// app could otherwise have had. Not a blocker — a caption.
    var isMissingDistance: Bool { scaleSource == .none || isDistanceAbsurd }

    // MARK: - Tilt

    /// Whether the optics needed to undo camera tilt are known. Without a
    /// field of view there is no focal length, and without a focal length the
    /// tilt homography has no scale.
    var canCorrectTilt: Bool { fieldOfViewDeg > 0 }

    /// Whether the current tilt is inside the range the correction can honestly
    /// claim. The homography is exact for a pinhole; real lenses distort, and
    /// a steep tilt is exactly what pushes the flight toward the frame edge
    /// where that distortion lives.
    var isTiltCorrectable: Bool {
        canCorrectTilt && abs(level.tiltDeg) <= SLA.tiltCorrectableMaxDeg
    }

    /// Severity of an advisory, so the UI can colour it.
    ///
    /// There is no `.blocking` any more, and the removal is the point: nothing
    /// blocks arming, so a severity meaning "this stops you" could only ever
    /// be painted next to a button that was not in fact stopped. It survived
    /// the gate it belonged to, and the two advisories still carrying it were
    /// the ones about camera distance — drawn in warning red, at the top of
    /// the list, above genuine warnings, under a fully enabled ARM.
    ///
    /// `.info` is for what was skipped rather than what is wrong. Sorting
    /// warnings ahead of it is what makes `topAdvisory` — the single line the
    /// primary button gets — the worst thing true rather than the first.
    enum AdviceLevel { case warning, info }

    /// Everything worth telling the user about the current placement, worst
    /// first. Replaces `blockingReason`: none of these block any more.
    var advisories: [(level: AdviceLevel, text: String)] {
        var out: [(AdviceLevel, String)] = []

        // Absurd is a warning, not merely missing: the number is non-nil, so
        // it is still handed to the sound-travel correction as if it were real.
        if isDistanceAbsurd, let m = derivedDistanceM {
            out.append((.warning, String(format: "Camera reads %.1f m away — that can't be right. Measure it again in Set up.", m)))
        }

        if !level.isAvailable || !level.hasReading {
            out.append((.warning, "No motion sensor reading — tripod level unknown."))
        } else {
            if !level.isTiltOK {
                let dir = level.tiltDeg > 0 ? "down" : "up"
                let mag = abs(level.tiltDeg)
                if !canCorrectTilt {
                    out.append((.warning, String(format: "Camera aims %@ %.0f° and the lens is unknown, so the tilt can't be corrected. Level it if you can.", dir, mag)))
                } else if !isTiltCorrectable {
                    out.append((.warning, String(format: "Camera aims %@ %.0f° — corrected, but that's steep. Raise the tripod instead of aiming up.", dir, mag)))
                } else {
                    out.append((.warning, String(format: "Camera aims %@ %.0f° — corrected automatically.", dir, mag)))
                }
            }
            if !level.isRollOK {
                out.append((.warning, String(format: "Horizon is %.1f° off — corrected in the maths, but level it if you can.",
                                             abs(level.rollDeg))))
            }
        }

        if scaleSource != .none, !isDistanceAbsurd, !isDistanceAcceptable,
           let m = derivedDistanceM {
            out.append((.warning, String(format: "Camera reads %.1f m away. 4.5–6 m is ideal.", m)))
        }

        // Said out loud, because arming no longer requires it and the app
        // otherwise gives no sign anything was skipped. `.info` on purpose:
        // the swing will still be measured — the scale comes from the ball's
        // own diameter — and dressing a missing nicety as a warning is how
        // people learn to skip past the warnings that matter.
        if scaleSource == .none {
            out.append((.info, "No camera distance yet — measure it in Set up. Not required: it buys a 3-frame contact correction and a lens-height check."))
        }

        // Height last, because it is the one the user can least often fix —
        // a short tripod is a short tripod. It is said at all because the
        // batter outline cannot say it, and because the wrong reaction to a
        // low camera (aiming it up) is worse than the low camera.
        if let h = lensHeightEstimateM, isLensHeightOK == false {
            if h < CameraPose.idealLensHeightM {
                out.append((.warning, String(format: "Lens is about %.1f m off the ground — belt height (1.1 m) is what the outline is drawn for. Raise it if you can, but keep it LEVEL: aiming up to compensate costs more than the height does.", h)))
            } else {
                out.append((.warning, String(format: "Lens is about %.1f m off the ground, above the 1.1 m the outline is drawn for. Lower it, or expect the hitter to sit low in frame.", h)))
            }
        }
        return out
    }

    /// The one advisory worth putting under the primary button.
    var topAdvisory: (level: AdviceLevel, text: String)? { advisories.first }

    /// Capture-condition flags stamped onto swings taken with this placement.
    /// App-only: these sit beside the measurement flags rather than inside
    /// `SwingFlag`, which mirrors the Python reference and knows nothing of
    /// tripods or motion sensors.
    var captureFlags: [CaptureFlag] {
        var out: [CaptureFlag] = []
        if !level.isAvailable || !level.hasReading {
            out.append(.levelUnknown)
        } else {
            if !level.isTiltOK {
                out.append(isTiltCorrectable ? .tiltCorrected : .cameraTilted)
            }
            if !level.isRollOK { out.append(.notLevel) }
        }
        // "Never measured" and "measured, and it was too far" are different
        // facts, and only one of them is a claim about where the camera was.
        // `isDistanceAcceptable` is false in both cases — it returns false for
        // a nil distance — so stamping DISTANCE_OUTSIDE_PROTOCOL off it alone
        // told every hitter who skipped the ball tap that their camera had been
        // outside a window nobody ever put a tape measure to.
        if derivedDistanceM == nil {
            out.append(.distanceNotMeasured)
        } else if !isDistanceAcceptable {
            out.append(.distanceOutsideProtocol)
        }
        if scaleSource == .manual { out.append(.scaleFromManualDistance) }
        if scaleSource == .hitter { out.append(.distanceFromHitterHeight) }
        if isLensHeightOK == false { out.append(.cameraHeightOffProtocol) }
        return out
    }

    // MARK: - Stamp

    /// What gets stamped onto every swing captured in this session.
    struct Placement: Equatable, Sendable {
        var distanceM: Double?
        var heightM: Double?
        var rollDeg: Double
        /// Camera pitch, positive aiming down. Corrected downstream by
        /// `TiltRectifier`, which needs `fovDeg` alongside it — a tilted camera
        /// projects the flight plane, and undoing that projection is a
        /// homography in the tilt angle and the focal length.
        var tiltDeg: Double
        /// Horizontal field of view of the capture format. Zero means the
        /// optics are unknown, and tilt then cannot be undone.
        var fovDeg: Double
        var plateScaleDisagreement: Double?
        var captureFlags: [CaptureFlag]
    }

    var placement: Placement {
        Placement(distanceM: derivedDistanceM,
                  // The lens height the ball tap, the IMU and the hitter's feet
                  // between them close out. This was hardcoded nil, so the one
                  // number the outline guide was replaced with reached no swing
                  // record ever written — while the same wizard state was
                  // simultaneously stamping CAMERA_HEIGHT_OFF_PROTOCOL computed
                  // from the estimate the record refused to carry.
                  heightM: lensHeightEstimateM,
                  // Both angles are handed to the analyzer to be corrected,
                  // not merely reported.
                  rollDeg: level.rollDeg,
                  tiltDeg: level.tiltDeg,
                  fovDeg: fieldOfViewDeg,
                  plateScaleDisagreement: nil,
                  captureFlags: captureFlags)
    }

    // MARK: - Lifecycle

    func startSensors() { level.start() }
    func stopSensors() { level.stop() }
}
