// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import Foundation

/// Picks the capture format.
///
/// 240fps at 1080p is the target from `docs/CAPTURE_PROTOCOL.md`. Not every
/// device offers it, so this degrades in a defined order and reports what it
/// settled on — the frame rate ends up in the clip metadata and in every
/// exported CSV, because every measurement scales with it.
enum FormatSelector {

    struct Choice {
        var format: AVCaptureDevice.Format
        /// The frame rate this format will actually run at — derived from the
        /// device's own `minFrameDuration`, not rounded to something tidy.
        var fps: Double
        /// The exact interval to lock the device to.
        ///
        /// Carried as the `CMTime` the device reported rather than rebuilt
        /// from `fps`. Rebuilding meant `CMTime(value: 1, timescale: 240)`,
        /// which is a different number from a format whose real rate is
        /// 239.76 — and asking a device for an interval shorter than it
        /// supports is either refused or silently clamped, after which every
        /// clip carries a frame rate it was not recorded at. Exit velocity
        /// scales directly with that number.
        var frameDuration: CMTime
        var width: Int
        var height: Int
        /// Horizontal field of view in degrees, used by the placement wizard
        /// to predict pixels-per-metre at a known distance.
        var fieldOfViewDeg: Double

        var describes: String {
            // Whole rates read as whole rates; anything else keeps its
            // decimals, because "199fps" and "198.94fps" are not the same
            // claim and the difference belongs in the clip metadata.
            let rate = abs(fps - fps.rounded()) < 0.01
                ? String(Int(fps.rounded()))
                : String(format: "%.2f", fps)
            return "\(width)x\(height) @ \(rate)fps"
        }
    }

    static func best(for device: AVCaptureDevice,
                     targetFPS: Double = SLA.targetFPS,
                     targetWidth: Int = SLA.targetWidth,
                     targetHeight: Int = SLA.targetHeight) -> Choice? {
        var candidates: [Choice] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // The fastest range, and the interval IT reports. Taking the rate
            // and the duration from the same range keeps them consistent; a
            // rate from one place and a duration reconstructed in another is
            // how a clip ends up labelled 240 while running at 239.76.
            guard let fastest = format.videoSupportedFrameRateRanges
                .max(by: { $0.maxFrameRate < $1.maxFrameRate }),
                  fastest.maxFrameRate > 0 else { continue }
            let duration = fastest.minFrameDuration
            // Prefer the duration, which is exact; the advertised rate is a
            // Float and rounds.
            let rate = duration.isNumeric && duration.seconds > 0
                ? 1 / duration.seconds
                : fastest.maxFrameRate
            candidates.append(Choice(format: format,
                                     fps: rate,
                                     frameDuration: duration,
                                     width: Int(dims.width),
                                     height: Int(dims.height),
                                     fieldOfViewDeg: Double(format.videoFieldOfView)))
        }
        guard !candidates.isEmpty else { return nil }

        // 1. Exactly what the protocol asks for.
        let exact = candidates.filter {
            $0.width == targetWidth && $0.height == targetHeight && $0.fps >= targetFPS
        }
        if let c = exact.min(by: { $0.fps < $1.fps }) { return c }

        // 2. Any resolution at the target frame rate — prefer the widest,
        //    since horizontal pixels are what resolve the ball.
        let fastEnough = candidates.filter { $0.fps >= targetFPS }
        if let c = fastEnough.max(by: { $0.width < $1.width }) { return c }

        // 3. Fastest available at the target height, then fastest overall.
        let rightHeight = candidates.filter { $0.height == targetHeight }
        if let c = rightHeight.max(by: { $0.fps < $1.fps }) { return c }
        return candidates.max(by: { $0.fps < $1.fps })
    }

    /// Lock the device to a fixed frame rate. Slo-mo measurement depends on
    /// frames arriving at a known, constant interval — auto frame-rate
    /// throttling in low light would silently corrupt every reading.
    static func apply(_ choice: Choice, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = choice.format
        device.activeVideoMinFrameDuration = choice.frameDuration
        device.activeVideoMaxFrameDuration = choice.frameDuration
    }
}
