// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Pixels that changed since the previous frame.
///
/// This is the single largest win available on real footage, and it was
/// missing: the Python reference has accepted a foreground mask since the
/// spike, and the Swift port never passed one. Measured on two field clips,
/// detection without it produced 129 and 131 candidates PER FRAME and around a
/// thousand candidate tracks — because sunlit grass and sunlit foliage ARE the
/// ball's colour, and the tree canopy alone yields round, ball-sized blobs
/// parked at the same pixel for the whole clip. Choosing the ball out of that
/// is guesswork, and every heuristic tried has guessed wrong.
///
/// A ball is the one ball-coloured thing in frame that MOVES. With the gate,
/// those same clips went to three and six candidate tracks, and the survivor
/// followed the ball at straightness 1.00.
///
/// Frame differencing rather than a learned background model: it needs one
/// previous frame instead of warm-up, it cannot drift, it costs one subtract
/// per pixel, and it has no library dependency. What it gives up — segmenting
/// slow-moving objects — does not matter when the target is the fastest thing
/// in the picture. Mirrors `motion_mask` in `spike/sla_common.py`.
enum MotionMask {

    /// Luma buffer for one frame, plus the geometry to read it.
    struct Luma {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// `nil` for the first frame, which has nothing to difference against —
    /// callers detect without a gate rather than skipping the frame, so a
    /// clip's opening frame is never silently lost.
    static func mask(current: Luma, previous: Luma?,
                     threshold: Int = Int(SLA.motionDiffThreshold),
                     dilatePx: Int = Int(SLA.motionDilatePx)) -> [Bool]? {
        guard let previous,
              previous.width == current.width,
              previous.height == current.height,
              current.pixels.count == current.width * current.height,
              previous.pixels.count == current.pixels.count
        else { return nil }

        let w = current.width, h = current.height
        var moved = [Bool](repeating: false, count: w * h)
        for i in 0..<moved.count {
            let d = Int(current.pixels[i]) - Int(previous.pixels[i])
            moved[i] = (d < 0 ? -d : d) > threshold
        }
        guard dilatePx > 0 else { return moved }
        // OpenCV's `dilate(3x3 ones, iterations: 2)` — a radius-1 square
        // applied twice — is EXACTLY a radius-2 square applied once (dilation
        // by a square is separable and composes by adding radii), so one
        // rows pass and one cols pass at double radius produce the identical
        // mask with half the passes and two fewer full-frame allocations.
        // The parity fixtures pin the result: one moved pixel must light
        // exactly a 5x5 block.
        //
        // Odd only, and this is a real constraint rather than a tidiness one.
        // An even kernel has no centre pixel, so OpenCV anchors it at
        // (k/2, k/2) and grows the mask one-sidedly: k=2 lights a 3x3 block
        // offset down and right, where the symmetric radius below lights a
        // centred 5x5. `motion_mask` raises on even for the same reason. The
        // gate decides which blobs survive, a differently-cut blob has a
        // different minor axis, and that minor axis is the ball diameter —
        // the scale under every reported number. Both callers pass the
        // default 3; a venue tuner reaching for 4 gets stopped, not silently
        // given a different answer from the Mac reference.
        precondition(dilatePx % 2 == 1,
                     "motion dilation must be odd; even kernels dilate one-sidedly in the reference")
        let r = (dilatePx / 2) * 2
        moved = dilateRows(moved, w: w, h: h, radius: r)
        moved = dilateCols(moved, w: w, h: h, radius: r)
        return moved
    }

    private static func dilateRows(_ src: [Bool], w: Int, h: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return src }
        var out = [Bool](repeating: false, count: src.count)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where src[row + x] {
                let lo = max(0, x - radius), hi = min(w - 1, x + radius)
                for k in lo...hi { out[row + k] = true }
            }
        }
        return out
    }

    private static func dilateCols(_ src: [Bool], w: Int, h: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return src }
        var out = [Bool](repeating: false, count: src.count)
        for y in 0..<h {
            for x in 0..<w where src[y * w + x] {
                let lo = max(0, y - radius), hi = min(h - 1, y + radius)
                for k in lo...hi { out[k * w + x] = true }
            }
        }
        return out
    }
}
