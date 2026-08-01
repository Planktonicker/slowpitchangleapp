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
        var fps: Double
        var width: Int
        var height: Int
        /// Horizontal field of view in degrees, used by the placement wizard
        /// to predict pixels-per-metre at a known distance.
        var fieldOfViewDeg: Double

        var describes: String {
            "\(width)x\(height) @ \(Int(fps.rounded()))fps"
        }
    }

    static func best(for device: AVCaptureDevice,
                     targetFPS: Double = SLA.targetFPS,
                     targetWidth: Int = SLA.targetWidth,
                     targetHeight: Int = SLA.targetHeight) -> Choice? {
        var candidates: [Choice] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }
                .max() ?? 0
            guard maxRate > 0 else { continue }
            candidates.append(Choice(format: format,
                                     fps: maxRate,
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
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(choice.fps.rounded()))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
    }
}
