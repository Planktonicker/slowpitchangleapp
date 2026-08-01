// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import Foundation

/// Guided camera placement. Arming is blocked until the checks pass.
///
/// This is the app's version of the geometry section of
/// `docs/CAPTURE_PROTOCOL.md`, and the reason it is worth enforcing rather
/// than trusting: every reading is scaled from pixels, so a camera that moved
/// between sessions silently changes the numbers. The wizard makes "filmed
/// the same way" a precondition instead of a hope.
@MainActor
final class PlacementWizard: ObservableObject {

    enum Step: Int, CaseIterable, Identifiable {
        case level, distance, plateScale, ready
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .level: return "Level the camera"
            case .distance: return "Distance and height"
            case .plateScale: return "Home-plate scale check"
            case .ready: return "Ready"
            }
        }
    }

    /// Home plate's front edge is 17 in across — the one hard dimension
    /// available at every field, and independent of the ball.
    static let plateWidthM = 17.0 * 0.0254

    @Published var step: Step = .level
    @Published var manualDistanceFt: Double = 20
    @Published var useManualDistance = false

    /// Endpoints of the plate's front edge, in normalized preview coordinates.
    @Published var plateStart = CGPoint(x: 0.36, y: 0.72)
    @Published var plateEnd = CGPoint(x: 0.46, y: 0.72)
    @Published var plateCheckSkipped = false

    let level = LevelSensor()
    let distance = ARDistanceSensor()

    /// Image width in pixels and horizontal field of view, from the active
    /// capture format — needed to predict pixels-per-metre.
    @Published var imageWidthPx: Double = Double(SLA.targetWidth)
    @Published var fieldOfViewDeg: Double = 0

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Republish sensor changes so views observing the wizard update.
        level.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        distance.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    var effectiveDistanceFt: Double? {
        useManualDistance ? manualDistanceFt : distance.distanceFt
    }

    var isDistanceOK: Bool {
        guard let ft = effectiveDistanceFt else { return false }
        return ft >= 15 && ft <= 20
    }

    /// Pixels per metre predicted from geometry alone: image width, the
    /// format's field of view, and the measured distance.
    var predictedPxPerM: Double? {
        guard let ft = effectiveDistanceFt, ft > 0, fieldOfViewDeg > 0 else { return nil }
        let d = ft / 3.28084
        let halfFov = fieldOfViewDeg / 2 * .pi / 180
        let widthAtDistanceM = 2 * d * tan(halfFov)
        guard widthAtDistanceM > 0 else { return nil }
        return imageWidthPx / widthAtDistanceM
    }

    /// Pixels per metre as actually measured off the plate in the preview.
    var measuredPxPerM: Double? {
        let dx = (plateEnd.x - plateStart.x) * imageWidthPx
        // Preview is normalized on both axes; the y term needs the same
        // pixel scale to keep the separation isotropic.
        let dy = (plateEnd.y - plateStart.y) * imageWidthPx
        let sep = (dx * dx + dy * dy).squareRoot()
        guard sep > 4 else { return nil }
        return sep / Self.plateWidthM
    }

    /// Fractional disagreement between the two, mirroring the ball-vs-gravity
    /// cross-check the analysis does per swing. A third independent estimate,
    /// available before a single ball is hit.
    var plateScaleDisagreement: Double? {
        guard let predicted = predictedPxPerM, let measured = measuredPxPerM,
              predicted > 0 else { return nil }
        return abs(measured - predicted) / predicted
    }

    var isPlateScaleOK: Bool {
        if plateCheckSkipped { return true }
        guard let d = plateScaleDisagreement else { return false }
        return d <= 0.10
    }

    var isArmingAllowed: Bool {
        level.isLevel && isDistanceOK && isPlateScaleOK
    }

    /// What gets stamped onto every swing captured in this session.
    struct Placement: Equatable, Sendable {
        var distanceFt: Double?
        var heightFt: Double?
        var rollDeg: Double
        var plateScaleDisagreement: Double?
    }

    var placement: Placement {
        Placement(distanceFt: effectiveDistanceFt,
                  heightFt: distance.heightFt,
                  // Handed to the analyzer so tripod roll is corrected, not
                  // just reported.
                  rollDeg: level.rollDeg,
                  plateScaleDisagreement: plateScaleDisagreement)
    }

    // MARK: - Lifecycle

    func startSensors() {
        level.start()
        if step == .distance && !useManualDistance { distance.start() }
    }

    func stopSensors() {
        level.stop()
        distance.stop()
    }

    func enter(_ newStep: Step) {
        // ARKit only runs while its own step is on screen: it wants the
        // camera, and so does capture.
        if newStep == .distance && !useManualDistance {
            distance.start()
        } else {
            distance.stop()
        }
        step = newStep
    }

    func advance() {
        let all = Step.allCases
        guard let i = all.firstIndex(of: step), i + 1 < all.count else { return }
        enter(all[i + 1])
    }

    func back() {
        let all = Step.allCases
        guard let i = all.firstIndex(of: step), i > 0 else { return }
        enter(all[i - 1])
    }

    var blockingReason: String? {
        if !level.isRollOK {
            return String(format: "Horizon is %.1f° off level.", abs(level.rollDeg))
        }
        if !level.isTiltOK {
            return String(format: "Camera is tilted %.1f° up or down.", abs(level.tiltDeg))
        }
        if !isDistanceOK {
            if let ft = effectiveDistanceFt {
                return String(format: "Camera is %.1f ft out. The protocol wants 15-20 ft.", ft)
            }
            return "No distance measured yet."
        }
        if !isPlateScaleOK {
            if let d = plateScaleDisagreement {
                return String(format: "Plate scale is %.0f%% off what the geometry predicts. Re-check the distance and the plate markers.", d * 100)
            }
            return "Mark both ends of the plate's front edge."
        }
        return nil
    }
}
