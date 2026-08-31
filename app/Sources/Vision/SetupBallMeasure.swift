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

    /// Below about 14 px across, every shape statistic here degenerates into
    /// quantisation noise — a geometrically perfect 5 px disc scores worse on
    /// the ray gate than a square does. 14 px is ~38 ft at a 60° lens, well
    /// beyond any usable filming distance, so this costs nothing real.
    static let minMeasurableDiameterPx = 14.0

    /// Largest ball we will measure, as a fraction of frame width.
    ///
    /// Deliberately generous. An earlier version derived this from an 8–40 ft
    /// filming window, which is right for a tripod at a field but rejected a
    /// ball sitting on a desk two feet away — the first thing anyone tries
    /// indoors — before a single shape test could run. The shape gates below
    /// are what reject a tabletop; the size band should not be doing that job,
    /// and `PlacementWizard` already tells the user when the derived distance
    /// is implausible. Better to measure the ball and say "that reads 2 ft,
    /// move back" than to report that there is no ball.
    static let maxDiameterFractionOfWidth = 0.45

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

    /// A short, human-readable trace of what the gates saw. This exists
    /// because the failure messages alone are not enough to tell a real
    /// rejection from an over-tight threshold, and every guess made from a
    /// screenshot so far has been wrong. It costs nothing and turns "it still
    /// cannot find the ball" into an answer.
    static func measure(image: PixelImage,
                        tapX: Double,
                        tapY: Double,
                        searchRadiusPx: Double,
                        settings: DetectorSettings,
                        fovDeg: Double) -> (outcome: Outcome, report: String) {

        _ = fovDeg   // distance sanity is the wizard's job, not the detector's
        let (minDiameter, maxDiameter) = diameterBand(imageWidth: image.width,
                                                      fovDeg: fovDeg,
                                                      searchRadiusPx: searchRadiusPx)
        guard maxDiameter > minDiameter else {
            return (.needsWiderSearch, "window too small for any ball")
        }

        // A ball is textured — seams, stitching, print, a specular highlight —
        // and no single colour window catches all of it reliably. So several
        // are tried, with and without a morphological close, and the most
        // disc-like candidate wins. Betting on one seeded window is what made
        // a real ball come back as a blob filling a third of its box.
        //
        // Close is offered because it repairs the gaps that lettering and
        // seams punch in the mask; it is not trusted blindly, because it can
        // also bridge a ball into whatever it is resting on. A bridged blob
        // fails the elongation and ray gates, so it cannot win.
        let c = tapColour(image: image, x: tapX, y: tapY)
        let variants: [(name: String, settings: DetectorSettings, close: Bool)] = [
            ("seed24c", seededWindow(c, hueSpan: 24, base: settings), true),
            ("seed24",  seededWindow(c, hueSpan: 24, base: settings), false),
            ("seed12c", seededWindow(c, hueSpan: 12, base: settings), true),
            ("dflt-c",  settings, true),
            ("dflt",    settings, false),
        ]

        var bestFound: (BallMeasurement, Shape, DetectorSettings, String)?
        var lastFail: Attempt?

        for v in variants {
            let attempt = bestCandidate(image: image, tapX: tapX, tapY: tapY,
                                        searchRadiusPx: searchRadiusPx,
                                        settings: v.settings, close: v.close,
                                        minDiameter: minDiameter, maxDiameter: maxDiameter)
            switch attempt {
            case .found(let m, let shape):
                if bestFound == nil || shape.score < bestFound!.1.score {
                    bestFound = (m, shape, v.settings, v.name)
                }
            case .failed:
                lastFail = attempt
            }
        }

        let tapDesc = String(format: "tap hsv %.0f/%.0f/%.0f", c.h, c.s, c.v)

        guard let (primary, shape, winning, winName) = bestFound else {
            let trace = lastFail?.trace ?? "no candidate"
            return (lastFail?.outcomeOnly ?? .nothingThere,
                    "r\(Int(searchRadiusPx)) · \(tapDesc) · \(trace)")
        }

        let base = String(format: "%@ · d %.0fpx · fill %.2f · rays %d/16 · edge %@",
                          winName, primary.diameterPx, shape.extent, shape.goodRays,
                          primary.subpixelRefined ? "yes" : "no")

        // A ball has a step edge, so its measured size barely moves when the
        // colour window is tightened; a broad colour region collapses. This is
        // the only test that looks at the image rather than the mask, and it is
        // what keeps a tabletop out.
        let b = bestCandidate(image: image, tapX: tapX, tapY: tapY,
                              searchRadiusPx: searchRadiusPx,
                              settings: tightened(winning), close: true,
                              minDiameter: minDiameter, maxDiameter: maxDiameter)

        // Very disc-like candidates are allowed to skip the cross-check. A
        // scuffed or backlit ball can vanish under a deliberately harsh window
        // while still being unmistakably round and isolated, and refusing those
        // left real balls unmeasurable — the failure actually seen in the field.
        let unmistakable = shape.goodRays >= rayCount - 1
            && shape.extent >= 0.70 && shape.extent <= 0.86

        guard case .found(let check, _) = b else {
            return unmistakable
                ? (.found(primary), base + " · tight:none, allowed (round)")
                : (.notAnEdge, base + " · vanished under tighter colour")
        }

        let dDiff = abs(primary.diameterPx - check.diameterPx) / max(1e-6, primary.diameterPx)
        let drift = ((primary.x - check.x) * (primary.x - check.x)
                     + (primary.y - check.y) * (primary.y - check.y)).squareRoot()
        let stable = dDiff <= stabilityDiameterTol
            && drift <= stabilityCentroidTol * primary.diameterPx
        guard stable || unmistakable else {
            return (.notAnEdge, base + String(format: " · size moved %.0f%% under tighter colour", dDiff * 100))
        }
        return (.found(primary), base + String(format: " · stable %.0f%%", dDiff * 100))
    }

    // MARK: - Size band

    private static func diameterBand(imageWidth: Int,
                                     fovDeg: Double,
                                     searchRadiusPx: Double) -> (Double, Double) {
        // The ray gate needs a moat around the ball inside the search window,
        // so the window itself caps how big a ball can be measured. The caller
        // grows the window when a candidate is rejected only for lack of room.
        let roomCap = 2 * searchRadiusPx / rayReachFactor
        let hi = min(maxDiameterFractionOfWidth * Double(imageWidth), roomCap)
        return (minMeasurableDiameterPx, hi)
    }

    // MARK: - Colour window

    /// The colour under the tap, as a median over a patch.
    ///
    /// A real ball is not one colour: it carries seams, stitching, printed
    /// lettering and a specular highlight, and a narrow window seeded from a
    /// few pixels catches scattered fragments of it rather than a disc — the
    /// observed failure was a blob filling only a third of its bounding box.
    /// So the patch is large enough to average across that texture, and the
    /// window it produces is deliberately generous.
    static func tapColour(image: PixelImage, x: Double, y: Double,
                          radius: Int = 6) -> (h: Double, s: Double, v: Double) {
        var hs: [Double] = [], ss: [Double] = [], vs: [Double] = []
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        for dy in -radius...radius {
            for dx in -radius...radius {
                let p = image.pixel(x: cx + dx, y: cy + dy)
                let hsv = HSVConvert.fromBGR(b: p.b, g: p.g, r: p.r)
                hs.append(hsv.h); ss.append(hsv.s); vs.append(hsv.v)
            }
        }
        func median(_ a: [Double]) -> Double {
            let sorted = a.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return (median(hs), median(ss), median(vs))
    }

    /// A colour window centred on what the user pointed at, `hueSpan` wide.
    ///
    /// Not intersected with the configured window: a ball photographed against
    /// a bright window reads far outside the default optic-yellow band, and
    /// intersecting simply threw its pixels away.
    private static func seededWindow(_ c: (h: Double, s: Double, v: Double),
                                     hueSpan: Double,
                                     base: DetectorSettings) -> DetectorSettings {
        var out = base
        out.hsvLo.h = max(0, c.h - hueSpan)
        out.hsvHi.h = min(179, c.h + hueSpan)
        // Floors well under the sampled value so seams and shaded flanks stay
        // inside the mask; the shape gates are what reject non-balls.
        out.hsvLo.s = max(30, c.s * 0.45)
        out.hsvHi.s = 255
        out.hsvLo.v = max(45, c.v * 0.40)
        out.hsvHi.v = 255
        return out
    }

    private static func tightened(_ s: DetectorSettings) -> DetectorSettings {
        var t = s
        let span = max(4.0, (s.hsvHi.h - s.hsvLo.h) * 0.35)
        let mid = (s.hsvHi.h + s.hsvLo.h) / 2
        t.hsvLo.h = mid - span / 2
        t.hsvHi.h = mid + span / 2
        t.hsvLo.s = min(255, s.hsvLo.s + 25)
        return t
    }

    // MARK: - Candidate search

    /// What the winning candidate's shape statistics were, for the report.
    struct Shape {
        var extent: Double
        var goodRays: Int
        var score: Double
    }

    private enum Attempt {
        case found(BallMeasurement, Shape)
        case failed(Outcome, trace: String)

        var outcomeOnly: Outcome {
            switch self {
            case .found: return .nothingThere
            case .failed(let o, _): return o
            }
        }

        var trace: String {
            switch self {
            case .found: return "found"
            case .failed(_, let t): return t
            }
        }
    }

    private static func bestCandidate(image: PixelImage,
                                      tapX: Double, tapY: Double,
                                      searchRadiusPx: Double,
                                      settings: DetectorSettings,
                                      close: Bool,
                                      minDiameter: Double,
                                      maxDiameter: Double) -> Attempt {
        let roi = ROI.around(x: tapX, y: tapY, radius: searchRadiusPx)
            .clamped(width: image.width, height: image.height)
        let w = roi.x1 - roi.x0, h = roi.y1 - roi.y0
        guard w > 8, h > 8 else { return .failed(.nothingThere, trace: "window clipped away") }

        // Closing repairs the holes that seams, stitching and printed lettering
        // punch in a real ball's mask. It can also bridge the ball into what it
        // rests on, so it is one variant among several rather than the default,
        // and a bridged blob is caught by the elongation and ray gates anyway.
        // The stage itself is the shared one — see `maskAfterMorphology`.
        let mask = BallDetector.maskAfterMorphology(image: image, roi: roi,
                                                    lo: settings.hsvLo,
                                                    hi: settings.hsvHi,
                                                    motion: nil, close: close)

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
        var bestShape = Shape(extent: 0, goodRays: 0, score: .infinity)
        var bestScore = Double.infinity
        var diagnosis: Outcome = .nothingThere
        // Why candidates were dropped, so a failure can be explained rather
        // than merely reported.
        var considered = 0
        var rejects: [String: Int] = [:]
        func reject(_ why: String) { rejects[why, default: 0] += 1 }

        for blob in blobs {
            // Prefer the blob under the tap; allow a near miss on its centroid.
            let isTapped = tappedRoot != 0 && blob.root == tappedRoot
            let dEq = 2 * (Double(blob.count) / .pi).squareRoot()
            let dx = (Double(roi.x0) + blob.meanX) - tapX
            let dy = (Double(roi.y0) + blob.meanY) - tapY
            let centroidNear = (dx * dx + dy * dy).squareRoot() <= 0.6 * max(dEq / 2, 8)
            guard isTapped || centroidNear else { continue }
            considered += 1

            // Runs off the edge of the picture: its diameter is under-read,
            // which biases the scale — and therefore exit velocity — high.
            let touchesImageEdge =
                (roi.x0 + blob.minX) <= 0 || (roi.x0 + blob.maxX) >= image.width - 1 ||
                (roi.y0 + blob.minY) <= 0 || (roi.y0 + blob.maxY) >= image.height - 1
            if touchesImageEdge { diagnosis = .truncatedByFrame; reject("frame edge"); continue }

            // Runs off the edge of the *search window*: retry wider rather
            // than declaring failure.
            let touchesROIEdge = blob.minX <= 0 || blob.maxX >= w - 1
                || blob.minY <= 0 || blob.maxY >= h - 1
            if touchesROIEdge {
                diagnosis = isTapped ? .mergedWithBackground : .needsWiderSearch
                reject("runs off window")
                continue
            }

            // Cheap pre-filter. Blind to squares by construction, so it is not
            // the discriminator — the ray gate is.
            let major = blob.majorAxis, minor = blob.minorAxis
            if minor > 1e-6, major / minor > maxElongation {
                diagnosis = .mergedWithBackground
                reject(String(format: "elongated %.1f", major / minor))
                continue
            }

            // Extent on the hole-filled blob. Filling matters: a specular
            // blowout on the crown of a sunlit ball punches a hole that drags
            // raw extent down to the rejection threshold.
            let filledCount = filledArea(labels: labels, width: w, height: h, blob: blob)
            let extent = filledCount / max(1, blob.boxWidth * blob.boxHeight)
            guard extent >= extentLo, extent <= extentHi else {
                reject(String(format: "fill %.2f", extent))
                continue
            }

            // The ray gate: roundness, isolation and window-safety in one pass.
            let rays = rayProfile(labels: labels, width: w, height: h, blob: blob)
            guard rays.good >= raysRequired else {
                // One contiguous arc missing is a shadow, not an impostor.
                if rays.good >= 8, rays.failuresContiguous { diagnosis = .shadowed }
                reject("rays \(rays.good)/16")
                continue
            }

            let cx = Double(roi.x0) + blob.meanX
            let cy = Double(roi.y0) + blob.meanY

            // Sub-pixel refinement is strongly preferred: without a real edge
            // the fallback is the halo-inflated mask diameter, a known ~+6%
            // bias landing straight in the scale.
            //
            // It is no longer an outright veto, though. A scuffed ball, or one
            // backlit against a bright window, can genuinely have too little
            // colour contrast to refine while still being unmistakably round
            // and isolated — and refusing those meant the user could not
            // measure a real ball at all, which is worse than a flagged
            // reading. Only near-perfect discs get the exemption, and they are
            // marked so the UI can say the number is rough.
            var diameter: Double
            var refinedOK = true
            if let refined = BallDetector.subpixelMinorDiameter(
                    image: image, cx: cx, cy: cy,
                    minorAxisDeg: blob.minorAxisDeg, r0: max(2, rays.median)) {
                // The image-derived diameter must broadly agree with the mask.
                guard abs(refined - dEq) / max(1e-6, refined) <= subpixelVsMaskTol else {
                    diagnosis = .notAnEdge
                    reject("edge/mask disagree")
                    continue
                }
                diameter = refined
            } else if rays.good >= rayCount - 1, extent >= 0.70, extent <= 0.86 {
                diameter = 2 * rays.median
                refinedOK = false
            } else {
                diagnosis = .notAnEdge
                reject("no edge to measure")
                continue
            }

            guard diameter >= minDiameter, diameter <= maxDiameter else {
                diagnosis = diameter > maxDiameter ? .needsWiderSearch : .nothingThere
                reject(String(format: "size %.0fpx outside %.0f-%.0f",
                              diameter, minDiameter, maxDiameter))
                continue
            }

            let score = abs(extent - 0.785)
                + 0.5 * (1 - Double(rays.good) / Double(rayCount))
                + (refinedOK ? 0 : 0.25)
            if score < bestScore {
                bestScore = score
                bestShape = Shape(extent: extent, goodRays: rays.good, score: score)
                best = BallMeasurement(diameterPx: diameter, x: cx, y: cy,
                                       areaPx: Double(blob.count),
                                       subpixelRefined: refinedOK)
            }
        }

        if let best { return .found(best, bestShape) }
        let why = rejects.isEmpty
            ? (considered == 0 ? "no coloured blob under the tap" : "no candidate")
            : rejects.map { "\($0.value)x \($0.key)" }.sorted().joined(separator: ", ")
        return .failed(diagnosis, trace: "\(considered) near tap · \(why)")
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
