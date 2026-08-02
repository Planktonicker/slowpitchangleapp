// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Measures one stationary ball that the user tapped, during setup.
///
/// **This is not the tracking detector.** `BallDetector.detect` is a
/// byte-for-byte port of `spike/sla_common.py`, pinned by ParityTests, and must
/// not change. This path is free to be much stricter because the problem is
/// different: one ball, at rest, whose position the user has just pointed at,
/// producing a scale the user can see and re-measure.
///
/// It has to be strict, because the number it produces is the pixels-per-metre
/// scale for the whole session — a wrong one silently multiplies every exit
/// velocity. The reported failure was exactly this: colour alone locked onto a
/// tabletop.
///
/// ## Why colour alone cannot work
///
/// Optic yellow overlaps grass and a lot of tan/wooden furniture, so the mask
/// is not the ball. Shape has to carry the decision. But the obvious shape
/// tests are worse than they look — a filled **square** has moment axes with
/// major/minor of exactly 1.00 and a bounding box of exactly 1.00, so both an
/// elongation test and a "squareness" test pass every compact impostor they
/// were meant to reject. The tests below were chosen because they separate a
/// disc from a square, a rectangle, a diamond and a filled region by wide
/// margins:
///
///  * **Extent** (filled area ÷ bounding box) — π/4 ≈ 0.785 for a disc versus
///    ~0.99 for a square and ~1.00 for a tabletop patch. The single most
///    discriminating statistic, and the only cheap one that rejects a compact
///    impostor.
///  * **A 16-ray gate** — one pass that delivers roundness, isolation and
///    border-safety together: every ray must escape the blob before 1.6r, stay
///    inside the search window, and land within ±15% of the median radius.
///  * **Threshold stability** — a ball has a step edge, so its measured size
///    barely moves when the colour window is tightened. A tabletop is a broad
///    region with no edge, so its apparent size collapses. This is the only
///    test that looks at the *image* rather than the mask, and it is what stops
///    a retry loop from manufacturing a ball-shaped island out of a table.
///  * **Mandatory sub-pixel refinement** — a ball-coloured surface presents no
///    edge, so the refinement fails and the old code silently fell back to the
///    halo-inflated mask diameter. In setup that is simply rejected: setup is
///    repeatable, and a known-biased scale is not worth keeping.
enum SetupBallMeasure {

    /// Distance window the measurement is willing to believe, in metres.
    /// `PlacementWizard` already treats 12–28 ft as usable and refuses to arm
    /// outside 5–60 ft, so accepting diameters implying 2 ft only gave a
    /// tabletop room to hide. Narrowing this is worth more than any shape test.
    static let nearestMeasurableM = 2.44   // 8 ft
    static let farthestMeasurableM = 12.2  // 40 ft

    /// Below about 14 px across, every shape statistic here degenerates into
    /// quantisation noise — a geometrically perfect 5 px disc scores worse on
    /// the ray gate than a square does. 14 px is ~38 ft at a 60° lens, well
    /// outside the protocol's window, so this costs nothing real.
    static let minMeasurableDiameterPx = 14.0

    /// Extent band, measured on the hole-filled blob. A disc is 0.785.
    static let extentLo = 0.62
    static let extentHi = 0.90

    /// Ray gate.
    static let rayCount = 16
    static let raysRequired = 13
    static let rayBand = 0.15          // ±15% of the median radius
    static let rayReachFactor = 1.6

    /// A ball's measured size must not move much when the colour window is
    /// tightened; a colour region's will.
    static let stabilityDiameterTol = 0.10
    static let stabilityCentroidTol = 0.25

    /// The image-derived sub-pixel diameter must broadly agree with the
    /// mask-derived one. The mask diameters are all functions of the same
    /// threshold and so agree with each other even for a square — only the
    /// sub-pixel number is independent evidence.
    static let subpixelVsMaskTol = 0.25

    static let maxElongation = 1.5

    /// Outcome of one measurement attempt, with enough diagnosis to tell the
    /// user something true. A single "couldn't find the ball" for every
    /// geometric failure would turn "it measures the table" into "it never
    /// measures anything", which is worse.
    enum Outcome: Equatable {
        case found(BallMeasurement)
        /// Round, isolated, but the colour window disagrees with itself —
        /// a gradient rather than an edge.
        case notAnEdge
        /// The blob containing the tap runs off into the surroundings.
        case mergedWithBackground
        /// One contiguous arc of the ball is missing — a shadow bite.
        case shadowed
        /// Touches the edge of the picture, so its diameter is under-read.
        case truncatedByFrame
        /// Too big for the search window; the caller should retry wider.
        case needsWiderSearch
        case nothingThere
    }

    // MARK: - Entry point

    static func measure(image: PixelImage,
                        tapX: Double,
                        tapY: Double,
                        searchRadiusPx: Double,
                        settings: DetectorSettings,
                        fovDeg: Double) -> Outcome {

        let (minDiameter, maxDiameter) = diameterBand(imageWidth: image.width,
                                                      fovDeg: fovDeg,
                                                      searchRadiusPx: searchRadiusPx)
        guard maxDiameter > minDiameter else { return .needsWiderSearch }

        // Seed the colour window from the pixels the user actually pointed at,
        // rather than walking the global window blindly and hoping. The blind
        // walk was a false-accept amplifier: tightening the hue ceiling carves
        // a large tan region into ever smaller islands until one happens to be
        // round and ball-sized.
        let seeded = seedFromTap(image: image, x: tapX, y: tapY, base: settings)

        // Two operating points. The second is deliberately tighter; a real
        // ball measures almost the same under both, a colour region does not.
        let tight = tightened(seeded)

        let a = bestCandidate(image: image, tapX: tapX, tapY: tapY,
                              searchRadiusPx: searchRadiusPx, settings: seeded,
                              minDiameter: minDiameter, maxDiameter: maxDiameter)

        guard case .found(let primary, let primaryShape) = a else { return a.outcomeOnly }

        let b = bestCandidate(image: image, tapX: tapX, tapY: tapY,
                              searchRadiusPx: searchRadiusPx, settings: tight,
                              minDiameter: minDiameter, maxDiameter: maxDiameter)
        guard case .found(let check, _) = b else {
            // Survived the nominal window but vanished under a tighter one:
            // there was never an edge there.
            return .notAnEdge
        }

        let dDiff = abs(primary.diameterPx - check.diameterPx) / max(1e-6, primary.diameterPx)
        let drift = ((primary.x - check.x) * (primary.x - check.x)
                     + (primary.y - check.y) * (primary.y - check.y)).squareRoot()
        guard dDiff <= stabilityDiameterTol,
              drift <= stabilityCentroidTol * primary.diameterPx else {
            return .notAnEdge
        }

        _ = primaryShape
        return .found(primary)
    }

    // MARK: - Size band

    private static func diameterBand(imageWidth: Int,
                                     fovDeg: Double,
                                     searchRadiusPx: Double) -> (Double, Double) {
        // The ray gate needs a moat around the ball inside the search window,
        // so the window itself caps how big a ball can be measured.
        let roomCap = 2 * searchRadiusPx / rayReachFactor

        guard fovDeg > 0 else {
            // No lens geometry reported: fall back to the floor and the room
            // cap only. Deliberately not the old 8–120 px window, which spans
            // 30:1 and is most of the reason a tabletop had anywhere to hide.
            return (minMeasurableDiameterPx, min(120, roomCap))
        }
        let halfFov = fovDeg * .pi / 360
        func pxPerM(_ d: Double) -> Double {
            Double(imageWidth) / (2 * d * tan(halfFov))
        }
        let lo = max(minMeasurableDiameterPx,
                     SLA.ballDiameterM * pxPerM(farthestMeasurableM))
        let hi = min(SLA.ballDiameterM * pxPerM(nearestMeasurableM), roomCap)
        return (lo, hi)
    }

    // MARK: - Colour window

    /// Median HSV of a 5×5 patch at the tap, intersected with the configured
    /// window. Uses the information the user gave us instead of guessing.
    private static func seedFromTap(image: PixelImage,
                                    x: Double, y: Double,
                                    base: DetectorSettings) -> DetectorSettings {
        var hs: [Double] = [], ss: [Double] = [], vs: [Double] = []
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        for dy in -2...2 {
            for dx in -2...2 {
                let p = image.pixel(x: cx + dx, y: cy + dy)
                let hsv = HSVConvert.fromBGR(b: p.b, g: p.g, r: p.r)
                hs.append(hsv.h); ss.append(hsv.s); vs.append(hsv.v)
            }
        }
        func median(_ a: [Double]) -> Double {
            let s = a.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        let hm = median(hs), sm = median(ss), vm = median(vs)

        var out = base
        out.hsvLo.h = max(base.hsvLo.h, hm - 9)
        out.hsvHi.h = min(base.hsvHi.h, hm + 9)
        out.hsvLo.s = max(60, min(base.hsvLo.s, 0.6 * sm))
        out.hsvLo.v = max(90, min(base.hsvLo.v, 0.5 * vm))
        // A degenerate window helps nobody; fall back to the configured one.
        if out.hsvHi.h - out.hsvLo.h < 6 { out.hsvLo.h = base.hsvLo.h; out.hsvHi.h = base.hsvHi.h }
        return out
    }

    private static func tightened(_ s: DetectorSettings) -> DetectorSettings {
        var t = s
        t.hsvHi.h = max(s.hsvLo.h + 4, s.hsvHi.h - 8)
        t.hsvLo.s = min(255, s.hsvLo.s + 25)
        return t
    }

    // MARK: - Candidate search

    private enum Attempt {
        case found(BallMeasurement, shapeScore: Double)
        case failed(Outcome)

        var outcomeOnly: Outcome {
            switch self {
            case .found: return .nothingThere
            case .failed(let o): return o
            }
        }
    }

    private static func bestCandidate(image: PixelImage,
                                      tapX: Double, tapY: Double,
                                      searchRadiusPx: Double,
                                      settings: DetectorSettings,
                                      minDiameter: Double,
                                      maxDiameter: Double) -> Attempt {
        let roi = ROI.around(x: tapX, y: tapY, radius: searchRadiusPx)
            .clamped(width: image.width, height: image.height)
        let w = roi.x1 - roi.x0, h = roi.y1 - roi.y0
        guard w > 8, h > 8 else { return .failed(.nothingThere) }

        var mask = [UInt8](repeating: 0, count: w * h)
        for yy in 0..<h {
            let iy = roi.y0 + yy
            let rowBase = yy * w
            for xx in 0..<w {
                let p = image.pixel(x: roi.x0 + xx, y: iy)
                if HSVConvert.inRange(b: p.b, g: p.g, r: p.r,
                                      lo: settings.hsvLo, hi: settings.hsvHi) {
                    mask[rowBase + xx] = 255
                }
            }
        }
        // Open only, never close: closing is exactly what bridges the ball's
        // mask into adjacent grass or tabletop and makes one giant blob.
        Morphology.open(&mask, width: w, height: h)

        let (blobs, labels) = ConnectedComponents.labelDetailed(mask: mask, width: w, height: h)

        // The tap must be *inside* the candidate. Nothing previously required
        // the measured object to be the object the user pointed at — only that
        // its centroid was nearer than any rival's, which is the selection rule
        // most likely to hand back a table.
        let tapCol = Int(tapX.rounded()) - roi.x0
        let tapRow = Int(tapY.rounded()) - roi.y0
        var tappedRoot: Int32 = 0
        if tapCol >= 0, tapCol < w, tapRow >= 0, tapRow < h {
            tappedRoot = labels[tapRow * w + tapCol]
        }

        var best: BallMeasurement?
        var bestScore = Double.infinity
        var diagnosis: Outcome = .nothingThere

        for blob in blobs {
            // Prefer the blob under the tap; allow a near miss on its centroid.
            let isTapped = tappedRoot != 0 && blob.root == tappedRoot
            let dEq = 2 * (Double(blob.count) / .pi).squareRoot()
            let dx = (Double(roi.x0) + blob.meanX) - tapX
            let dy = (Double(roi.y0) + blob.meanY) - tapY
            let centroidNear = (dx * dx + dy * dy).squareRoot() <= 0.6 * max(dEq / 2, 8)
            guard isTapped || centroidNear else { continue }

            // Runs off the edge of the picture: its diameter is under-read,
            // which biases the scale — and therefore exit velocity — high.
            let touchesImageEdge =
                (roi.x0 + blob.minX) <= 0 || (roi.x0 + blob.maxX) >= image.width - 1 ||
                (roi.y0 + blob.minY) <= 0 || (roi.y0 + blob.maxY) >= image.height - 1
            if touchesImageEdge { diagnosis = .truncatedByFrame; continue }

            // Runs off the edge of the *search window*: retry wider rather
            // than declaring failure.
            let touchesROIEdge = blob.minX <= 0 || blob.maxX >= w - 1
                || blob.minY <= 0 || blob.maxY >= h - 1
            if touchesROIEdge {
                diagnosis = isTapped ? .mergedWithBackground : .needsWiderSearch
                continue
            }

            // Cheap pre-filter. Blind to squares by construction, so it is not
            // the discriminator — the ray gate is.
            let major = blob.majorAxis, minor = blob.minorAxis
            if minor > 1e-6, major / minor > maxElongation {
                diagnosis = .mergedWithBackground
                continue
            }

            // Extent on the hole-filled blob. Filling matters: a specular
            // blowout on the crown of a sunlit ball punches a hole that drags
            // raw extent down to the rejection threshold.
            let filledCount = filledArea(labels: labels, width: w, height: h, blob: blob)
            let extent = filledCount / max(1, blob.boxWidth * blob.boxHeight)
            guard extent >= extentLo, extent <= extentHi else { continue }

            // The ray gate: roundness, isolation and window-safety in one pass.
            let rays = rayProfile(labels: labels, width: w, height: h, blob: blob)
            guard rays.good >= raysRequired else {
                // One contiguous arc missing is a shadow, not an impostor.
                if rays.good >= 8, rays.failuresContiguous { diagnosis = .shadowed }
                continue
            }

            let cx = Double(roi.x0) + blob.meanX
            let cy = Double(roi.y0) + blob.meanY

            // Sub-pixel refinement is mandatory here. Without an edge there is
            // no refinement, and the fallback is the halo-inflated mask
            // diameter — a known ~+6% bias landing straight in the scale.
            guard let refined = BallDetector.subpixelMinorDiameter(
                    image: image, cx: cx, cy: cy,
                    minorAxisDeg: blob.minorAxisDeg, r0: max(2, rays.median)) else {
                diagnosis = .notAnEdge
                continue
            }
            // The image-derived diameter must broadly agree with the mask.
            guard abs(refined - dEq) / max(1e-6, refined) <= subpixelVsMaskTol else {
                diagnosis = .notAnEdge
                continue
            }
            guard refined >= minDiameter, refined <= maxDiameter else {
                diagnosis = refined > maxDiameter ? .needsWiderSearch : .nothingThere
                continue
            }

            let score = abs(extent - 0.785)
                + 0.5 * (1 - Double(rays.good) / Double(rayCount))
            if score < bestScore {
                bestScore = score
                best = BallMeasurement(diameterPx: refined, x: cx, y: cy,
                                       areaPx: Double(blob.count),
                                       subpixelRefined: true)
            }
        }

        if let best { return .found(best, shapeScore: bestScore) }
        return .failed(diagnosis)
    }

    // MARK: - Shape statistics

    /// Blob area with interior holes filled, for the extent test only. The raw
    /// pixel count still drives area and diameter.
    private static func filledArea(labels: [Int32], width w: Int, height h: Int,
                                   blob: ConnectedComponents.Blob) -> Double {
        let bw = blob.maxX - blob.minX + 1
        let bh = blob.maxY - blob.minY + 1
        guard bw > 0, bh > 0 else { return Double(blob.count) }

        // Flood the background inward from the bbox border; anything inside
        // the box the flood cannot reach is an interior hole.
        var outside = [Bool](repeating: false, count: bw * bh)
        var stack: [Int] = []
        func consider(_ bx: Int, _ by: Int) {
            guard bx >= 0, bx < bw, by >= 0, by < bh else { return }
            let i = by * bw + bx
            if outside[i] { return }
            let gx = blob.minX + bx, gy = blob.minY + by
            if labels[gy * w + gx] == blob.root { return }   // solid: blocks
            outside[i] = true
            stack.append(i)
        }
        for bx in 0..<bw { consider(bx, 0); consider(bx, bh - 1) }
        for by in 0..<bh { consider(0, by); consider(bw - 1, by) }
        while let i = stack.popLast() {
            let bx = i % bw, by = i / bw
            consider(bx - 1, by); consider(bx + 1, by)
            consider(bx, by - 1); consider(bx, by + 1)
        }
        var filled = 0
        for i in 0..<(bw * bh) where !outside[i] { filled += 1 }
        return Double(filled)
    }

    private struct RayProfile {
        var good: Int
        var median: Double
        var failuresContiguous: Bool
    }

    /// Cast rays from the centroid and measure how far the blob extends along
    /// each. One loop answers three questions: is it round (all radii within a
    /// band), is it isolated (every ray leaves the blob before the reach), and
    /// is it wholly inside the window (no ray runs off the edge).
    ///
    /// Two details are load-bearing. Rays are rasterised against the **single
    /// component**, not the whole mask — otherwise speckled turf around the
    /// ball defeats the isolation test. And the walk never stops early; it
    /// records the *outermost* on-blob sample, so a specular hole in the middle
    /// of the ball does not shorten the ray.
    private static func rayProfile(labels: [Int32], width w: Int, height h: Int,
                                   blob: ConnectedComponents.Blob) -> RayProfile {
        let rEq = (Double(blob.count) / .pi).squareRoot()
        let reach = rayReachFactor * rEq
        let step = 0.25

        var lengths = [Double](repeating: 0, count: rayCount)
        var escaped = [Bool](repeating: false, count: rayCount)
        var inWindow = [Bool](repeating: true, count: rayCount)

        for k in 0..<rayCount {
            let a = 2 * Double.pi * Double(k) / Double(rayCount)
            let ca = cos(a), sa = sin(a)
            var r = 0.0
            var last = 0.0
            var ok = true
            while r <= reach {
                let px = Int((blob.meanX + r * ca).rounded())
                let py = Int((blob.meanY + r * sa).rounded())
                if px < 0 || px >= w || py < 0 || py >= h { ok = false; break }
                if labels[py * w + px] == blob.root { last = r }
                r += step
            }
            lengths[k] = last
            inWindow[k] = ok
            escaped[k] = last < reach - 0.3
        }

        let sorted = lengths.sorted()
        let median = sorted[sorted.count / 2]
        var good = 0
        var failing = [Bool](repeating: false, count: rayCount)
        for k in 0..<rayCount {
            let withinBand = median > 0 && abs(lengths[k] - median) <= rayBand * median
            if inWindow[k] && escaped[k] && withinBand { good += 1 } else { failing[k] = true }
        }

        // A shadow bite removes one contiguous arc; an impostor's short rays
        // are scattered. That difference is what picks the failure message.
        var runs = 0
        for k in 0..<rayCount where failing[k] && !failing[(k + rayCount - 1) % rayCount] {
            runs += 1
        }
        return RayProfile(good: good, median: median,
                          failuresContiguous: runs <= 1)
    }
}
