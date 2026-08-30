// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// Pulls full-resolution stills out of a clip.
///
/// The clip cannot leave the phone — hundreds of megabytes — but three frames
/// can, and for tuning the detector they are worth more than the video: colour
/// windows, size gates and shape tests are all decided from single frames.
/// `ClipDiagnostics` says which stage failed; a frame says why.
///
/// PNG, not JPEG. The whole use is measuring colour, and JPEG's chroma
/// subsampling smears exactly the hue boundary being measured — a ball that
/// sits near the edge of the HSV window can be pushed across it by the
/// compression rather than by anything real.
enum FrameExporter {

    /// Written at the clip's native size: `maximumSize` is left unset, so no
    /// scaling happens. A downscaled frame would make the ball smaller in
    /// pixels than it really was, which is the one number the size gate is
    /// judged against.
    /// The one place the exact-seek contract is written down. The default
    /// tolerance is half a second — 120 frames at 240fps, enough to land
    /// after the ball has left the picture — and CLAUDE.md calls it a known
    /// trap; every generator in the app comes from here so the next screen
    /// cannot reintroduce it by hand-configuring its own.
    static func exactSeekGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    static func extract(from url: URL, at times: [Double],
                        namePrefix: String) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let generator = exactSeekGenerator(for: asset)

        var out: [URL] = []
        for (i, seconds) in times.enumerated() {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let cg = try await generator.image(at: time).image
            let data = UIImage(cgImage: cg).pngData()
            guard let data else { continue }
            let dst = ClipStore.exportsDirectory
                .appendingPathComponent(String(format: "%@_f%d_%.2fs.png",
                                               namePrefix, i + 1, seconds))
            try data.write(to: dst, options: .atomic)
            out.append(dst)
        }
        return out
    }

    /// Three times spread across the clip, avoiding the very ends.
    ///
    /// Deliberately not the first and last frame: clips start with the phone
    /// being touched and end after the ball has gone, and neither shows what
    /// the detector has to cope with.
    static func defaultTimes(durationS: Double) -> [Double] {
        guard durationS > 0.3 else { return [durationS / 2] }
        return [0.25, 0.5, 0.75].map { $0 * durationS }
    }

    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    /// Clear previously exported frames.
    ///
    /// Full-resolution PNGs are a few megabytes each and pile up invisibly in
    /// a directory nothing else lists, so each export starts from empty rather
    /// than adding to a heap nobody will ever look at.
    static func clearPreviousFrames() {
        let fm = FileManager.default
        let dir = ClipStore.exportsDirectory
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasSuffix(".png") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
