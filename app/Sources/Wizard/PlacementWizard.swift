// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import Foundation

/// Camera placement state. Arming is blocked until the checks pass.
///
/// Every reading is scaled from pixels, so a camera that moved between
/// sessions silently changes the numbers — placement is a precondition, not
/// a suggestion. What changed from v0.1: ARKit is gone. It fought the 240fps
/// capture session for the camera (the field-test black screen) and made
/// setup feel like surveying. Distance now falls out of optics instead:
/// something of known size in frame (the ball, 9.7 cm; or the plate, 43 cm)
/// plus the lens field of view gives both the scale AND the distance in one
/// measurement, with the live preview running the whole time.
@MainActor
final class PlacementWizard: ObservableObject {

    /// Where the pixels-per-metre scale came from.
    enum ScaleSource: String, Codable {
        case none
        case ball       // tap-the-ball auto measure — the layman path
        case plate      // dragged markers on home plate's 43 cm front edge
        case manual     // typed distance, scale predicted from FOV
    }

    /// Home plate's front edge is 43 cm (17 in) — the one hard dimension available
    /// at every field, independent of the ball.
    static let plateWidthM = 17.0 * 0.0254

    // MARK: - Inputs

    let level = LevelSensor()

    /// From the active capture format; needed to turn scale into distance.
    @Published var imageWidthPx: Double = Double(SLA.targetWidth)
    @Published var imageHeightPx: Double = Double(SLA.targetHeight)
    @Published var fieldOfViewDeg: Double = 0

    /// Endpoints of the plate's front edge, normalized preview coordinates.
    @Published var plateStart = CGPoint(x: 0.36, y: 0.72)
    @Published var plateEnd = CGPoint(x: 0.46, y: 0.72)
    @Published var showPlateMarkers = false

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
        let r = TiltRectifier.rectify(x: atX, y: atY,
                                      tiltDeg: level.tiltDeg, focalPx: focal,
                                      cx: imageWidthPx / 2, cy: imageHeightPx / 2)
        // Reported raw, so the diagnostics line and the picture agree.
        lastBallDiameterPx = diameterPx
        measuredPxPerM = diameterPx * r.magnification / SLA.ballDiameterM
        scaleSource = .ball
        showPlateMarkers = false
    }

    /// Recompute scale from the plate markers. Call whenever a handle moves.
    func applyPlateMeasurement() {
        let dx = (plateEnd.x - plateStart.x) * imageWidthPx
        let dy = (plateEnd.y - plateStart.y) * imageWidthPx
        let separation = (dx * dx + dy * dy).squareRoot()
        guard separation > 4 else { return }
        measuredPxPerM = separation / Self.plateWidthM
        scaleSource = .plate
    }

    /// Fallback: trust a tape-measured distance and predict the scale from
    /// the lens geometry instead of measuring it.
    func applyManualDistance() {
        guard fieldOfViewDeg > 0, manualDistanceM > 0 else { return }
        let d = manualDistanceM
        let halfFov = fieldOfViewDeg / 2 * .pi / 180
        let widthAtDistanceM = 2 * d * tan(halfFov)
        guard widthAtDistanceM > 0 else { return }
        measuredPxPerM = imageWidthPx / widthAtDistanceM
        scaleSource = .manual
        showPlateMarkers = false
    }

    func clearScale() {
        measuredPxPerM = nil
        lastBallDiameterPx = nil
        hitterFeetFraction = nil
        smoothedFeet = nil
        scaleSource = .none
    }

    // MARK: - Derived

    /// Distance from the camera, inverted from the measured scale and the
    /// field of view. For the manual source this just round-trips the typed
    /// value.
    var derivedDistanceM: Double? {
        if scaleSource == .manual { return manualDistanceM }
        guard let pxPerM = measuredPxPerM, pxPerM > 0, fieldOfViewDeg > 0 else { return nil }
        let halfFov = fieldOfViewDeg / 2 * .pi / 180
        let widthAtDistanceM = imageWidthPx / pxPerM
        return widthAtDistanceM / (2 * tan(halfFov))
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

    /// The only hard precondition left: without a scale there is no way to turn
    /// pixels into miles per hour, so there is nothing to record.
    ///
    /// Level used to gate this too. It no longer does. Roll is *corrected*
    /// downstream in `SwingAnalyzer` — blocking on a quantity we already take
    /// back out was self-defeating — and tilt, while genuinely uncorrectable,
    /// degrades smoothly rather than falling off a cliff at 3°. Both are now
    /// advisories that also flag the reading, so an off-level tripod produces
    /// a measurement labelled for what it is instead of no measurement at all.
    var isArmingAllowed: Bool {
        scaleSource != .none && !isDistanceAbsurd
    }

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
    enum AdviceLevel { case blocking, warning }

    /// Everything worth telling the user about the current placement, worst
    /// first. Replaces `blockingReason`: most of these no longer block.
    var advisories: [(level: AdviceLevel, text: String)] {
        var out: [(AdviceLevel, String)] = []

        if scaleSource == .none {
            out.append((.blocking, "Tap the ball in the picture to set the distance."))
        }
        if isDistanceAbsurd, let m = derivedDistanceM {
            out.append((.blocking, String(format: "Camera reads %.1f m away — that can't be right. Re-measure.", m)))
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
        if !isDistanceAcceptable { out.append(.distanceOutsideProtocol) }
        if scaleSource == .manual { out.append(.scaleFromManualDistance) }
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
                  heightM: nil,
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
