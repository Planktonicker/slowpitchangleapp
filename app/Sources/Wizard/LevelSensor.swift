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
///  * **tilt** — camera pointing up or down. A tilted camera turns the flight
///    plane into a projection and breaks the assumption that vertical pixels
///    mean vertical metres. This one is handed to `TiltRectifier`, which warps
///    the track back into the view a level camera would have recorded before
///    anything is measured — so the short tripod that has to be aimed up at
///    contact height still produces honest numbers.
final class LevelSensor: ObservableObject {

    @Published private(set) var rollDeg: Double = 0
    /// Camera pitch, **positive when the lens aims down**. Matches the sign
    /// `TiltRectifier` and `sla_common.rectify_tilt` expect; `tiltSign` pins it
    /// with a test, because a flipped sign here would double the projection
    /// error instead of removing it, and would do so silently.
    @Published private(set) var tiltDeg: Double = 0
    @Published private(set) var isAvailable = false
    /// False until the first real reading lands. Without this, "no motion
    /// sensor" and "perfectly level" were the same state (both zero), so the
    /// UI cheerfully showed "Level ✓" for a device that had told us nothing.
    @Published private(set) var hasReading = false
    /// Latched, hysteretic level state. Never computed straight from the live
    /// angles: at 30 Hz an unsmoothed comparison flips either side of the
    /// tolerance many times a second, which is what made buttons that depend
    /// on it strobe between enabled and disabled and read as dead.
    @Published private(set) var isLevelLatched = true

    /// Tolerances. Roll is generous because it is corrected downstream; tilt
    /// is tight because it is not.
    let rollToleranceDeg = 2.0
    let tiltToleranceDeg = 3.0
    /// Recovery band — must come back well inside tolerance before the latch
    /// clears, so a reading sitting exactly on the line cannot oscillate.
    private let recoveryFactor = 0.7
    /// Exponential smoothing factor, ~0.2 s time constant at 30 Hz.
    private let smoothing = 0.15

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "swinglab.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    /// Everything below is guarded by `stateLock`. The motion callback runs
    /// on its own OperationQueue at 30 Hz while zeroHere/clearZero/stop mutate
    /// the same vars from the main thread; unsynchronized, a tap on "zero
    /// here" mid-update was instantly undone (or half-applied) by a callback
    /// still working from the pre-zero values — and the corrupted roll and
    /// tilt flow into the correction subtracted from every launch angle.
    /// `lastPublishedRoll/Tilt` shadow the @Published values so the callback
    /// never has to READ main-thread state either.
    private var rollZero = 0.0
    private var tiltZero = 0.0
    private var smoothedRoll: Double?
    private var smoothedTilt: Double?
    private var latched = true
    private var lastPublished = CFAbsoluteTimeGetCurrent()
    private var lastPublishedRoll = Double.infinity
    private var lastPublishedTilt = Double.infinity
    private let stateLock = NSLock()

    var isRollOK: Bool { abs(rollDeg) <= rollToleranceDeg }
    var isTiltOK: Bool { abs(tiltDeg) <= tiltToleranceDeg }
    var isLevel: Bool { isLevelLatched }

    func start() {
        guard motion.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.isAvailable = false
                self.hasReading = false
            }
            return
        }
        // Called from more than one screen; starting twice runs two update
        // streams and doubles the publishing load for nothing.
        guard !motion.isDeviceMotionActive else { return }
        DispatchQueue.main.async {
            self.isAvailable = true
            // Without this the notification below is never posted, so the
            // observer was dead code and the offset kept whatever value it had
            // at launch. Rotate the phone after starting and roll read a
            // quarter turn out — and roll is stamped on every swing and taken
            // back out of the launch angle, so the error was silent rather
            // than visible. UIKit reference-counts these, so the matching
            // `endGenerating` in `stop()` is not optional.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            self.refreshOrientation()
        }
        // Rotating the phone is the ONE event that changes the offset, and it
        // is the event this used to get wrong.
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Twice, deliberately. This notification reports the DEVICE
                // turning, and `refreshOrientation` reads the INTERFACE
                // orientation, which UIKit may not have updated yet — so the
                // first read can still return the old value. The second, a
                // run-loop turn later, is the one that is reliably right.
                // Reading it twice costs nothing; missing the change puts 90
                // degrees into a measurement.
                Task { @MainActor in
                    self?.refreshOrientation()
                    await Task.yield()
                    self?.refreshOrientation()
                }
            }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        // Off the main queue: this used to publish 30 times a second onto the
        // main thread, and every one of those invalidated the whole view tree
        // while the camera was trying to run at 240fps.
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let g = data.gravity

            // Rotation of gravity within the screen plane, zero when the
            // device is upright in portrait.
            let portraitRoll = atan2(g.x, -g.y) * 180 / .pi
            let offset = self.orientationOffset()

            self.stateLock.lock()
            // Filming is landscape, so subtract the orientation's own quarter
            // turn to get the horizon's tilt inside the frame.
            var roll = portraitRoll - offset - self.rollZero
            while roll > 180 { roll -= 360 }
            while roll < -180 { roll += 360 }

            let tilt = Self.tiltDown(gravityZ: g.z) - self.tiltZero

            let sr = self.smoothedRoll.map { $0 + self.smoothing * (roll - $0) } ?? roll
            let st = self.smoothedTilt.map { $0 + self.smoothing * (tilt - $0) } ?? tilt
            self.smoothedRoll = sr
            self.smoothedTilt = st

            // Latch: trip out at tolerance, recover only well inside it.
            let outOfBounds = abs(sr) > self.rollToleranceDeg
                || abs(st) > self.tiltToleranceDeg
            let backInside = abs(sr) <= self.rollToleranceDeg * self.recoveryFactor
                && abs(st) <= self.tiltToleranceDeg * self.recoveryFactor
            if outOfBounds { self.latched = false }
            else if backInside { self.latched = true }
            let level = self.latched

            // Publish at ~10 Hz, and only when a displayed value moved —
            // compared against the lock-guarded shadows, never the @Published
            // main-thread values.
            let now = CFAbsoluteTimeGetCurrent()
            let moved = abs(sr - self.lastPublishedRoll) >= 0.1
                || abs(st - self.lastPublishedTilt) >= 0.1
            let firstReading = self.lastPublishedRoll == .infinity
            let shouldPublish = now - self.lastPublished >= 0.1 && (moved || firstReading)
            if shouldPublish {
                self.lastPublished = now
                self.lastPublishedRoll = sr
                self.lastPublishedTilt = st
            }
            self.stateLock.unlock()

            guard shouldPublish else { return }
            DispatchQueue.main.async {
                self.rollDeg = sr
                self.tiltDeg = st
                self.isLevelLatched = level
                self.hasReading = true
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        // Balanced against the `beginGenerating` in `start()`, and tied to the
        // observer because that is set in the same breath: both of `start()`'s
        // early returns bail out before either, so keying off the observer is
        // what keeps the reference count honest.
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
            DispatchQueue.main.async {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
        stateLock.lock()
        smoothedRoll = nil
        smoothedTilt = nil
        lastPublishedRoll = .infinity
        lastPublishedTilt = .infinity
        stateLock.unlock()
    }

    /// Treat the current pose as level. For a tripod head that is trustworthy
    /// but not perfectly calibrated, or a phone mount with a built-in offset.
    func zeroHere() {
        stateLock.lock()
        // Zero against the SMOOTHED state the callback owns, not the published
        // copy — they lag each other by up to a publish tick, and the callback
        // must observe the zero and the reset smoothing atomically.
        rollZero += smoothedRoll ?? rollDeg
        tiltZero += smoothedTilt ?? tiltDeg
        smoothedRoll = 0
        smoothedTilt = 0
        latched = true
        lastPublishedRoll = 0
        lastPublishedTilt = 0
        stateLock.unlock()
        rollDeg = 0
        tiltDeg = 0
        isLevelLatched = true
    }

    func clearZero() {
        stateLock.lock()
        rollZero = 0
        tiltZero = 0
        smoothedRoll = nil
        smoothedTilt = nil
        lastPublishedRoll = .infinity
        lastPublishedTilt = .infinity
        stateLock.unlock()
    }

    /// Camera pitch in degrees from `CMDeviceMotion.gravity`'s z component,
    /// positive when the **rear lens aims down**.
    ///
    /// The rear camera looks along device −z, and CoreMotion reports gravity in
    /// device coordinates. Lying flat screen-up the camera points at the table
    /// and `g.z == -1`; face-down at the sky it is `+1`; standing upright in
    /// portrait, level, it is `0`. Hence the negation — without it every sign
    /// downstream, including the direction `TiltRectifier` warps the track, is
    /// backwards.
    ///
    /// Pure and `static` so `PipelineTests` can pin the convention. It has to
    /// be pinned: a wrong sign here does not fail loudly, it doubles the very
    /// error it was added to remove.
    static func tiltDown(gravityZ: Double) -> Double {
        -asin(max(-1, min(1, gravityZ))) * 180 / .pi
    }

    // MARK: - Which way the phone is being held

    /// The quarter turn to take out of the in-frame roll, cached.
    ///
    /// This used to call `UIApplication.shared.connectedScenes` **from the
    /// CoreMotion queue**, which is a background thread, and those are
    /// main-thread-only APIs. Off the main thread the lookup does not throw —
    /// it returns nothing useful — so the `?? .portrait` fallback fired while
    /// the phone was in landscape, the 90 degree offset was never subtracted,
    /// and the spirit level read ninety degrees out for the whole orientation
    /// the app is actually filmed in.
    ///
    /// So the orientation is sampled on the main thread, where it is legal to
    /// ask, and the motion callback reads the answer behind a lock.
    private var orientationObserver: NSObjectProtocol?
    private let orientationLock = NSLock()
    private var cachedOffset: Double = 0

    private func orientationOffset() -> Double {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return cachedOffset
    }

    @MainActor
    func refreshOrientation() {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
        let offset: Double
        switch orientation {
        case .landscapeLeft:       offset = -90
        case .landscapeRight:      offset = 90
        case .portraitUpsideDown:  offset = 180
        default:                   offset = 0
        }
        orientationLock.lock()
        cachedOffset = offset
        orientationLock.unlock()
    }
}
