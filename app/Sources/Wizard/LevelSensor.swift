// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import CoreMotion
import Foundation
import UIKit

/// Bubble level for tripod setup.
///
/// Two angles matter, for different reasons:
///
///  * **roll** — rotation of the horizon within the frame. This one is not
///    just a setup warning: it is handed to `SwingAnalyzer` as `rollDeg`, so
///    a tripod that sits 1.5 degrees off has that 1.5 degrees taken back out
///    of the launch angle instead of quietly biasing every reading.
///  * **tilt** — camera pointing up or down. There is no correcting this one
///    after the fact; a tilted camera turns the flight plane into a projection
///    and breaks the assumption that vertical pixels mean vertical metres.
final class LevelSensor: ObservableObject {

    @Published private(set) var rollDeg: Double = 0
    @Published private(set) var tiltDeg: Double = 0
    @Published private(set) var isAvailable = false

    /// Tolerances. Roll is generous because it is corrected downstream; tilt
    /// is tight because it is not.
    let rollToleranceDeg = 2.0
    let tiltToleranceDeg = 3.0

    private let motion = CMMotionManager()
    private var rollZero = 0.0
    private var tiltZero = 0.0

    var isRollOK: Bool { abs(rollDeg) <= rollToleranceDeg }
    var isTiltOK: Bool { abs(tiltDeg) <= tiltToleranceDeg }
    var isLevel: Bool { isRollOK && isTiltOK }

    func start() {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let g = data.gravity

            // Rotation of gravity within the screen plane, zero when the
            // device is upright in portrait.
            let portraitRoll = atan2(g.x, -g.y) * 180 / .pi
            // Filming is landscape, so subtract the orientation's own quarter
            // turn to get the horizon's tilt inside the frame.
            let offset: Double
            switch Self.currentOrientation() {
            case .landscapeLeft:       offset = -90
            case .landscapeRight:      offset = 90
            case .portraitUpsideDown:  offset = 180
            default:                   offset = 0
            }
            var roll = portraitRoll - offset - self.rollZero
            while roll > 180 { roll -= 360 }
            while roll < -180 { roll += 360 }

            // Camera axis is device -z, so gravity's z component is how far
            // the lens is pointing up or down.
            let tilt = asin(max(-1, min(1, g.z))) * 180 / .pi - self.tiltZero

            self.rollDeg = roll
            self.tiltDeg = tilt
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Treat the current pose as level. For a tripod head that is trustworthy
    /// but not perfectly calibrated, or a phone mount with a built-in offset.
    func zeroHere() {
        rollZero += rollDeg
        tiltZero += tiltDeg
        rollDeg = 0
        tiltDeg = 0
    }

    func clearZero() {
        rollZero = 0
        tiltZero = 0
    }

    private static func currentOrientation() -> UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.interfaceOrientation ?? .portrait
    }
}
