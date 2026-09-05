// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import CoreMotion
import Foundation

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
        DispatchQueue.main.async { self.isAvailable = true }
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

            self.stateLock.lock()
            var roll = Self.rollOffSquare(portraitDeg: portraitRoll) - self.rollZero
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

    /// How far the horizon is from square, in degrees, given gravity's angle in
    /// the screen plane measured from portrait-upright.
    ///
    /// **This does not ask the system which way the phone is held, and that is
    /// the point.** It used to: it read `interfaceOrientation` on the main
    /// thread, cached it, and subtracted 90 for landscape — with the sign taken
    /// from the names `landscapeLeft` and `landscapeRight`, which are among the
    /// most reliably misremembered constants in UIKit and which no test here
    /// could pin, because reading them needs a live `UIApplication`. Get that
    /// sign backwards and a landscape phone reads `±90 − (∓90) = ±180`, so the
    /// bubble slams into one end of the beam and stays there — which is
    /// precisely what it did, and the wrong way round in each landscape.
    ///
    /// The deviation from the nearest quarter turn is the same quantity with
    /// nothing to get wrong. A tripod is set square and then adjusted by
    /// degrees, so the nearest multiple of 90 is the orientation the phone is
    /// in; what is left over is the error. It is correct upside-down, it is
    /// correct if the interface is ever locked while the device is not, and it
    /// is a pure function of one number, so a test can hold it.
    ///
    /// It is the right quantity for the measurement too, not just the display:
    /// `ClipRecorder` writes a display matrix from the same quarter turn, so
    /// the analyzer's frames arrive already square and only the leftover tilt
    /// remains to be taken out of the launch angle.
    ///
    /// Beyond 45° from square there is no "nearest" worth the name and the
    /// answer folds — but that is a phone at 45° on a tripod, which is out of
    /// tolerance by a factor of twenty either way it is read.
    static func rollOffSquare(portraitDeg: Double) -> Double {
        portraitDeg - (portraitDeg / 90).rounded() * 90
    }
}
