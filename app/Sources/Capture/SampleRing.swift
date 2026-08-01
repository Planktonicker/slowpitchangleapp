// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreMedia
import Foundation

/// Bounded in-memory ring of encoded samples — the pre-roll.
///
/// The contact trigger fires *at* contact, but the interesting bat motion
/// happens before it, so the app is always recording into this ring and only
/// commits to disk once a swing actually happens.
///
/// Not thread-safe by itself; the capture pipeline owns one per media type
/// and touches them only from its serial queue.
final class SampleRing {

    private(set) var samples: [CMSampleBuffer] = []
    /// Seconds of history to keep.
    var maxDuration: Double
    /// When true, trimming only cuts at keyframes so the retained span is
    /// always independently decodable. Audio needs no such constraint.
    private let keyframeAligned: Bool

    init(maxDuration: Double, keyframeAligned: Bool) {
        self.maxDuration = maxDuration
        self.keyframeAligned = keyframeAligned
    }

    var isEmpty: Bool { samples.isEmpty }

    var span: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let start = CMSampleBufferGetPresentationTimeStamp(first)
        let end = CMSampleBufferGetPresentationTimeStamp(last)
        guard start.isNumeric, end.isNumeric else { return 0 }
        return max(0, end.seconds - start.seconds)
    }

    func append(_ sb: CMSampleBuffer) {
        samples.append(sb)
        trim()
    }

    func removeAll() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Everything currently held, oldest first.
    func drain() -> [CMSampleBuffer] {
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }

    private func trim() {
        guard let last = samples.last else { return }
        let endTime = CMSampleBufferGetPresentationTimeStamp(last)
        guard endTime.isNumeric else { return }

        if !keyframeAligned {
            while let first = samples.first {
                let t = CMSampleBufferGetPresentationTimeStamp(first)
                guard t.isNumeric, endTime.seconds - t.seconds > maxDuration else { break }
                samples.removeFirst()
            }
            return
        }

        // Find the newest keyframe that still leaves at least `maxDuration`
        // of history behind it, and drop everything before it. Cutting
        // anywhere else would leave leading frames that cannot be decoded.
        var cutIndex: Int?
        for i in samples.indices {
            guard samples[i].isSyncSample else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(samples[i])
            guard t.isNumeric else { continue }
            if endTime.seconds - t.seconds >= maxDuration {
                cutIndex = i
            } else {
                break
            }
        }
        if let cut = cutIndex, cut > 0 {
            samples.removeFirst(cut)
        }
    }
}
