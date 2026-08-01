// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import ARKit
import Combine
import Foundation

/// Measures camera-to-plate distance and lens height with ARKit.
///
/// The capture protocol asks for 15-20 ft at roughly contact height, measured
/// rather than guessed, because both numbers feed the expected
/// pixels-per-metre the plate check compares against.
///
/// ARKit and `AVCaptureSession` both want the camera, so they cannot run at
/// once. `PlacementWizard` stops capture before starting this, and the
/// reverse when the wizard closes.
final class ARDistanceSensor: NSObject, ObservableObject, ARSessionDelegate {

    @Published private(set) var distanceM: Double?
    @Published private(set) var heightM: Double?
    @Published private(set) var isRunning = false
    @Published private(set) var trackingMessage: String?

    let session = ARSession()

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var distanceFt: Double? { distanceM.map { $0 * 3.28084 } }
    var heightFt: Double? { heightM.map { $0 * 3.28084 } }

    /// The protocol's window: 15-20 ft, preferring 20.
    var isDistanceOK: Bool {
        guard let ft = distanceFt else { return false }
        return ft >= 15 && ft <= 20
    }

    /// Lens at roughly contact height (~3.5 ft), with slack for tripod reach.
    var isHeightOK: Bool {
        guard let ft = heightFt else { return false }
        return ft >= 2.5 && ft <= 4.5
    }

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard Self.isSupported else {
            trackingMessage = "This device does not support ARKit distance measurement. Enter the distance by hand."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        switch frame.camera.trackingState {
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingMessage = "Hold still while ARKit gets its bearings…"
            case .insufficientFeatures:
                trackingMessage = "Not enough texture to track. Aim at the ground near the plate."
            case .excessiveMotion:
                trackingMessage = "Too much movement — the tripod should be still."
            default:
                trackingMessage = "Move the phone slowly to start tracking."
            }
        case .notAvailable:
            trackingMessage = "Tracking unavailable."
        case .normal:
            trackingMessage = nil
        }

        // Distance: raycast straight out of the middle of the frame — the
        // user aims the centre at the plate or tee.
        let centre = CGPoint(x: 0.5, y: 0.5)
        if let query = frame.raycastQuery(from: centre,
                                          allowing: .estimatedPlane,
                                          alignment: .any) {
            if let hit = session.raycast(query).first {
                let cam = frame.camera.transform.columns.3
                let target = hit.worldTransform.columns.3
                let dx = Double(cam.x - target.x)
                let dy = Double(cam.y - target.y)
                let dz = Double(cam.z - target.z)
                distanceM = (dx * dx + dy * dy + dz * dz).squareRoot()
            }
        }

        // Height: camera above the lowest horizontal plane ARKit has found,
        // which in practice is the ground the tripod stands on.
        let groundY = frame.anchors
            .compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }
            .map { Double($0.transform.columns.3.y) }
            .min()
        if let groundY {
            heightM = max(0, Double(frame.camera.transform.columns.3.y) - groundY)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingMessage = error.localizedDescription
        isRunning = false
    }
}
