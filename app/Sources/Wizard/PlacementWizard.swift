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
/// something of known size in frame (the ball, 3.82 in; or the plate, 17 in)
/// plus the lens field of view gives both the scale AND the distance in one
/// measurement, with the live preview running the whole time.
@MainActor
final class PlacementWizard: ObservableObject {

    /// Where the pixels-per-metre scale came from.
    enum ScaleSource: String, Codable {
        case none
        case ball       // tap-the-ball auto measure — the layman path
        case plate      // dragged markers on home plate's 17 in front edge
        case manual     // typed distance, scale predicted from FOV
    }

    /// Home plate's front edge is 17 in — the one hard dimension available
    /// at every field, independent of the ball.
    static let plateWidthM = 17.0 * 0.0254

    // MARK: - Inputs

    let level = LevelSensor()

    /// From the active capture format; needed to turn scale into distance.
    @Published var imageWidthPx: Double = Double(SLA.targetWidth)
    @Published var fieldOfViewDeg: Double = 0

    /// Endpoints of the plate's front edge, normalized preview coordinates.
    @Published var plateStart = CGPoint(x: 0.36, y: 0.72)
    @Published var plateEnd = CGPoint(x: 0.46, y: 0.72)
    @Published var showPlateMarkers = false

    @Published var manualDistanceFt: Double = 20

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

    // MARK: - Scale sources

    /// The one-tap path: the detector measured the resting ball at
    /// `diameterPx`; the ball is 3.82 in, so the scale is immediate.
    func applyBallMeasurement(diameterPx: Double) {
        lastBallDiameterPx = diameterPx
        measuredPxPerM = diameterPx / SLA.ballDiameterM
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
        guard fieldOfViewDeg > 0, manualDistanceFt > 0 else { return }
        let d = manualDistanceFt / 3.28084
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
        scaleSource = .none
    }

    // MARK: - Derived

    /// Distance from the camera, inverted from the measured scale and the
    /// field of view. For the manual source this just round-trips the typed
    /// value.
    var derivedDistanceFt: Double? {
        if scaleSource == .manual { return manualDistanceFt }
        guard let pxPerM = measuredPxPerM, pxPerM > 0, fieldOfViewDeg > 0 else { return nil }
        let halfFov = fieldOfViewDeg / 2 * .pi / 180
        let widthAtDistanceM = imageWidthPx / pxPerM
        let d = widthAtDistanceM / (2 * tan(halfFov))
        return d * 3.28084
    }

    /// The protocol's window is 15-20 ft; 12-28 is accepted with a nudge, so
    /// a cramped backyard still works — flagged, not forbidden.
    var isDistanceIdeal: Bool {
        guard let ft = derivedDistanceFt else { return false }
        return ft >= 15 && ft <= 20
    }

    var isDistanceAcceptable: Bool {
        guard let ft = derivedDistanceFt else { return false }
        return ft >= 12 && ft <= 28
    }

    /// Distances where the optics genuinely cannot work, as opposed to merely
    /// being outside the protocol's preferred window.
    var isDistanceAbsurd: Bool {
        guard let ft = derivedDistanceFt else { return false }
        return ft < 5 || ft > 60
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

    /// Severity of an advisory, so the UI can colour it.
    enum AdviceLevel { case blocking, warning }

    /// Everything worth telling the user about the current placement, worst
    /// first. Replaces `blockingReason`: most of these no longer block.
    var advisories: [(level: AdviceLevel, text: String)] {
        var out: [(AdviceLevel, String)] = []

        if scaleSource == .none {
            out.append((.blocking, "Tap the ball in the picture to set the distance."))
        }
        if isDistanceAbsurd, let ft = derivedDistanceFt {
            out.append((.blocking, String(format: "Camera reads %.0f ft away — that can't be right. Re-measure.", ft)))
        }

        if !level.isAvailable || !level.hasReading {
            out.append((.warning, "No motion sensor reading — tripod level unknown."))
        } else {
            if !level.isTiltOK {
                out.append((.warning, String(format: "Camera points %@ by %.1f°. Readings will be less accurate.",
                                             level.tiltDeg > 0 ? "down" : "up", abs(level.tiltDeg))))
            }
            if !level.isRollOK {
                out.append((.warning, String(format: "Horizon is %.1f° off — corrected in the maths, but level it if you can.",
                                             abs(level.rollDeg))))
            }
        }

        if scaleSource != .none, !isDistanceAbsurd, !isDistanceAcceptable,
           let ft = derivedDistanceFt {
            out.append((.warning, String(format: "Camera reads %.0f ft away. 15–20 ft is ideal.", ft)))
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
            if !level.isTiltOK { out.append(.cameraTilted) }
            if !level.isRollOK { out.append(.notLevel) }
        }
        if !isDistanceAcceptable { out.append(.distanceOutsideProtocol) }
        if scaleSource == .manual { out.append(.scaleFromManualDistance) }
        return out
    }

    // MARK: - Stamp

    /// What gets stamped onto every swing captured in this session.
    struct Placement: Equatable, Sendable {
        var distanceFt: Double?
        var heightFt: Double?
        var rollDeg: Double
        /// Recorded, never corrected: a tilted camera projects the flight plane
        /// and there is no undoing that after the fact. Kept so a suspicious
        /// reading can be explained later.
        var tiltDeg: Double
        var plateScaleDisagreement: Double?
        var captureFlags: [CaptureFlag]
    }

    var placement: Placement {
        Placement(distanceFt: derivedDistanceFt,
                  heightFt: nil,
                  // Handed to the analyzer so tripod roll is corrected, not
                  // just reported.
                  rollDeg: level.rollDeg,
                  tiltDeg: level.tiltDeg,
                  plateScaleDisagreement: nil,
                  captureFlags: captureFlags)
    }

    // MARK: - Lifecycle

    func startSensors() { level.start() }
    func stopSensors() { level.stop() }
}
