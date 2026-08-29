// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

struct DetectorSettings: Equatable, Codable, Sendable {
    var hsvLo: HSVBounds = SLA.hsvLoDefault
    var hsvHi: HSVBounds = SLA.hsvHiDefault
    var minRadiusPx: Double = SLA.minRadiusPxDefault
    var maxRadiusPx: Double = SLA.maxRadiusPxDefault
}

/// One ball measured at rest during setup.
struct BallMeasurement: Equatable, Sendable {
    var diameterPx: Double
    var x: Double
    var y: Double
    var areaPx: Double
    /// False when the sub-pixel refinement could not run — too little colour
    /// contrast between ball and background, typically deep shade. The coarse
    /// fallback reads the compression halo and so over-states the diameter,
    /// which lands directly in the scale. Surfaced rather than swallowed.
    var subpixelRefined: Bool
}

/// Why a live ball measurement did not produce a number.
///
/// Previously this whole path returned `Double?`, and a `?? nil` flattened
/// "the frame was not in a format we can read" into "no ball found" — so the
/// UI blamed the ball for what was actually a pixel-format bug.
enum BallMeasureResult: Equatable, Sendable {
    case found(BallMeasurement)
    case noFrameYet
    case conversionFailed
    case noBallNearTap(searchRadiusPx: Double)
    /// Round and isolated, but the colour window disagrees with itself — a
    /// broad colour region rather than an object with an edge. This is what a
    /// tabletop looks like, and saying so beats a generic miss.
    case notAnEdge
    /// The tapped blob runs off into whatever it is sitting on.
    case mergedWithBackground
    /// One contiguous arc of the ball is missing.
    case shadowed
    /// Touches the edge of the picture, so its measured size is under-read.
    case truncatedByFrame
}

/// Rectangular search window in image pixels.
struct ROI: Equatable, Sendable {
    var x0: Int, y0: Int, x1: Int, y1: Int

    func clamped(width: Int, height: Int) -> ROI {
        ROI(x0: max(0, min(x0, width - 1)),
            y0: max(0, min(y0, height - 1)),
            x1: max(1, min(x1, width)),
            y1: max(1, min(y1, height)))
    }

    static func around(x: Double, y: Double, radius: Double) -> ROI {
        ROI(x0: Int(x - radius), y0: Int(y - radius),
            x1: Int(x + radius) + 1, y1: Int(y + radius) + 1)
    }
}

/// Finds yellow, roughly-ball-sized blobs in one frame and measures each one
/// sub-pixel.
///
/// Port of `detect_ball_candidates` / `_subpixel_minor_diameter` in
/// `sla_common.py`. Two deliberate deviations from OpenCV, neither of which
/// touches a reported number:
///
///  * blob area is a pixel count rather than `contourArea`'s polygon area
///    (used only to gate candidates by size);
///  * the ellipse comes from image moments rather than `fitEllipse` on a
///    contour (used only to find the minor-axis *direction*).
///
/// The diameter itself — the number that lands in exit velocity — is measured
/// by the same sub-pixel method as the reference.
enum BallDetector {

    /// How many pixels in the whole frame pass the colour window, before any
    /// morphology, size or shape test.
    ///
    /// Diagnostics only. It is the one measurement that separates "the ball is
    /// not the colour we are looking for" from "the colour matched and
    /// something later threw it away" — and those two failures look identical
    /// from outside, which is what has made every field failure so far a
    /// guessing exercise.
    ///
    /// Subsampled 2x in each axis: at 1080p that is a quarter of the work for
    /// an answer that only has to distinguish "almost nothing" from "plenty".
    /// The returned count is scaled back up so it reads as whole-frame pixels.
    static func countInWindow(image: PixelImage, settings: DetectorSettings) -> Int {
        var count = 0
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let p = image.pixel(x: x, y: y)
                if HSVConvert.inRange(b: p.b, g: p.g, r: p.r,
                                      lo: settings.hsvLo, hi: settings.hsvHi) {
                    count += 1
                }
                x += 2
            }
            y += 2
        }
        return count * 4
    }

    static func detect(image: PixelImage,
                       frame: Int,
                       t: Double,
                       settings: DetectorSettings = DetectorSettings(),
                       roi: ROI? = nil) -> [BallObservation] {
        let r = (roi ?? ROI(x0: 0, y0: 0, x1: image.width, y1: image.height))
            .clamped(width: image.width, height: image.height)
        let w = r.x1 - r.x0
        let h = r.y1 - r.y0
        guard w > 2, h > 2 else { return [] }

        // --- colour threshold ---
        var mask = [UInt8](repeating: 0, count: w * h)
        for yy in 0..<h {
            let iy = r.y0 + yy
            let rowBase = yy * w
            for xx in 0..<w {
                let p = image.pixel(x: r.x0 + xx, y: iy)
                if HSVConvert.inRange(b: p.b, g: p.g, r: p.r,
                                      lo: settings.hsvLo, hi: settings.hsvHi) {
                    mask[rowBase + xx] = 255
                }
            }
        }

        // --- morphological open then close, 3x3 cross (OpenCV's 3x3 ellipse) ---
        Morphology.open(&mask, width: w, height: h)
        Morphology.close(&mask, width: w, height: h)

        // --- connected components ---
        let blobs = ConnectedComponents.label(mask: mask, width: w, height: h)

        let minArea = Double.pi * settings.minRadiusPx * settings.minRadiusPx
        // Elongation allowance: up to ~4x blur smear along the motion axis.
        let maxArea = Double.pi * settings.maxRadiusPx * settings.maxRadiusPx * 4.0

        var out: [BallObservation] = []
        for blob in blobs {
            let area = Double(blob.count)
            if area < minArea || area > maxArea { continue }

            let cx = Double(r.x0) + blob.meanX
            let cy = Double(r.y0) + blob.meanY

            var minor = blob.minorAxis
            let major = blob.majorAxis
            if major > 0 && minor > 1e-6 && major / minor > 6.0 { continue }
            if minor <= 1e-6 { minor = 2 * settings.minRadiusPx }

            // The minor axis is perpendicular to the blur smear, so it still
            // reads true ball diameter. Refine it sub-pixel.
            if let refined = subpixelMinorDiameter(image: image,
                                                   cx: cx, cy: cy,
                                                   minorAxisDeg: blob.minorAxisDeg,
                                                   r0: minor / 2.0) {
                minor = refined
            }

            if !(2 * settings.minRadiusPx <= minor && minor <= 2 * settings.maxRadiusPx) {
                continue
            }
            out.append(BallObservation(frame: frame, t: t, x: cx, y: cy,
                                       diameterPx: minor, areaPx: area))
        }
        return out
    }

    /// Sub-pixel ball diameter along the minor (blur-free) axis.
    ///
    /// This is finding #2 from the spike. A colour-threshold contour reads
    /// into the compression/edge-blend halo around the ball — measured at +6%
    /// on encoded synthetic video, which is a direct +6% bias in exit
    /// velocity. So the reference measurement is threshold-free:
    ///
    /// sample the image bilinearly along the minor-axis line, estimate the
    /// ball colour from the blob core and the background colour just outside
    /// it (independently per side), project each sample onto the
    /// core->background colour line to get a mixing fraction `alpha` in
    /// [0, 1], and locate the `alpha = 0.5` crossing on each side by linear
    /// interpolation. The 50% crossing sits at the geometric edge regardless
    /// of venue colours or how far a threshold bleeds into the halo.
    ///
    /// `r0` is a rough radius used only to place the core/background sampling
    /// windows.
    static func subpixelMinorDiameter(image: PixelImage,
                                      cx: Double,
                                      cy: Double,
                                      minorAxisDeg: Double,
                                      r0: Double) -> Double? {
        let step = SLA.diameterProfileStepPx
        let reach = r0 * 1.8 + 4.0
        let n = max(8, Int(reach / step))
        let count = 2 * n + 1

        var rs = [Double](repeating: 0, count: count)
        for i in 0..<count { rs[i] = Double(i - n) * step }

        let a = minorAxisDeg * Double.pi / 180
        let ca = cos(a), sa = sin(a)
        var sb = [Double](repeating: 0, count: count)
        var sg = [Double](repeating: 0, count: count)
        var sr = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let p = image.sampleBilinear(x: cx + rs[i] * ca, y: cy + rs[i] * sa)
            sb[i] = p.b; sg[i] = p.g; sr[i] = p.r
        }

        let c = n
        let coreLimit = max(0.4 * r0, step)
        var coreB = 0.0, coreG = 0.0, coreR = 0.0, coreN = 0
        for i in 0..<count where abs(rs[i]) <= coreLimit {
            coreB += sb[i]; coreG += sg[i]; coreR += sr[i]; coreN += 1
        }
        guard coreN > 0 else { return nil }
        coreB /= Double(coreN); coreG /= Double(coreN); coreR /= Double(coreN)

        func edgeRadius(_ direction: Int) -> Double? {
            let d = Double(direction)
            var bgB = 0.0, bgG = 0.0, bgR = 0.0, bgN = 0
            let lo = 1.3 * r0
            let hi = 1.8 * r0 + 4.0
            for i in 0..<count {
                let rd = rs[i] * d
                if rd >= lo && rd <= hi {
                    bgB += sb[i]; bgG += sg[i]; bgR += sr[i]; bgN += 1
                }
            }
            guard bgN > 0 else { return nil }
            bgB /= Double(bgN); bgG /= Double(bgN); bgR /= Double(bgN)

            let dB = coreB - bgB, dG = coreG - bgG, dR = coreR - bgR
            let denom = dB * dB + dG * dG + dR * dR
            // Under ~30/255 of colour contrast the matte fraction is noise.
            guard denom >= 900.0 else { return nil }

            @inline(__always) func alpha(_ i: Int) -> Double {
                ((sb[i] - bgB) * dB + (sg[i] - bgG) * dG + (sr[i] - bgR) * dR) / denom
            }

            var prevI = c
            var i = c + direction
            while i + direction >= 0 && i + direction < count {
                if alpha(i) < 0.5 && alpha(i + direction) < 0.5 {
                    let a1 = alpha(i)
                    let a0 = alpha(prevI)
                    let frac = a0 > a1 ? (a0 - 0.5) / (a0 - a1) : 0.5
                    return abs(rs[prevI]) + frac * step
                }
                prevI = i
                i += direction
            }
            return nil
        }

        guard let rPos = edgeRadius(1), let rNeg = edgeRadius(-1) else { return nil }
        return rPos + rNeg
    }
}

// MARK: - Binary morphology

enum Morphology {
    /// 4-neighbour cross, which is what OpenCV's
    /// `getStructuringElement(MORPH_ELLIPSE, (3, 3))` actually produces.
    static func erode(_ m: inout [UInt8], width w: Int, height h: Int) {
        let src = m
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if src[i] == 0 { continue }
                var keep = true
                if x == 0 || src[i - 1] == 0 { keep = false }
                if keep, x == w - 1 || src[i + 1] == 0 { keep = false }
                if keep, y == 0 || src[i - w] == 0 { keep = false }
                if keep, y == h - 1 || src[i + w] == 0 { keep = false }
                if !keep { m[i] = 0 }
            }
        }
    }

    static func dilate(_ m: inout [UInt8], width w: Int, height h: Int) {
        let src = m
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if src[i] != 0 { continue }
                var on = false
                if x > 0, src[i - 1] != 0 { on = true }
                if !on, x < w - 1, src[i + 1] != 0 { on = true }
                if !on, y > 0, src[i - w] != 0 { on = true }
                if !on, y < h - 1, src[i + w] != 0 { on = true }
                if on { m[i] = 255 }
            }
        }
    }

    static func open(_ m: inout [UInt8], width: Int, height: Int) {
        erode(&m, width: width, height: height)
        dilate(&m, width: width, height: height)
    }

    static func close(_ m: inout [UInt8], width: Int, height: Int) {
        dilate(&m, width: width, height: height)
        erode(&m, width: width, height: height)
    }
}

// MARK: - Connected components

enum ConnectedComponents {

    struct Blob {
        var count: Int
        var meanX: Double
        var meanY: Double
        /// Full-length axes of the equivalent ellipse, from second moments.
        var majorAxis: Double
        var minorAxis: Double
        /// Direction of the *minor* axis in degrees, image coords (y down) —
        /// this is what the sub-pixel profile is sampled along.
        var minorAxisDeg: Double
        /// Bounding box in mask coordinates. Additive only — the parity-pinned
        /// `detect` ignores these; they exist so `SetupBallMeasure`
        /// can tell a round ball from a rectangular tabletop, which second
        /// moments alone do not distinguish well.
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        /// Union-find root, matching the per-pixel labels from `labelDetailed`.
        var root: Int32 = 0

        var boxWidth: Double { Double(maxX - minX + 1) }
        var boxHeight: Double { Double(maxY - minY + 1) }
        /// Fraction of the bounding box that is filled. A solid disc gives
        /// pi/4 ~ 0.785; a filled rectangle gives ~1.0.
        var extent: Double {
            let box = boxWidth * boxHeight
            return box > 0 ? Double(count) / box : 0
        }
        /// 1.0 for a square box, further from 1 the more oblong.
        var boxAspect: Double {
            boxHeight > 0 ? boxWidth / boxHeight : .infinity
        }
    }

    /// Two-pass 8-connected labelling with union-find.
    static func label(mask: [UInt8], width w: Int, height h: Int) -> [Blob] {
        labelDetailed(mask: mask, width: w, height: h).blobs
    }

    /// As `label`, but also hands back the per-pixel root labels.
    ///
    /// The setup measurement needs them for two things the blob statistics
    /// cannot provide: checking that the pixel the user tapped is actually
    /// *inside* the candidate, and rasterising rays against a single component
    /// rather than the whole mask (speckled turf otherwise defeats the
    /// isolation test).
    static func labelDetailed(mask: [UInt8], width w: Int, height h: Int)
        -> (blobs: [Blob], labels: [Int32]) {
        var labels = [Int32](repeating: 0, count: w * h)
        var parent: [Int32] = [0]   // index 0 unused (0 == background)

        func find(_ x: Int32) -> Int32 {
            var root = x
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var cur = x
            while parent[Int(cur)] != root {   // path compression
                let next = parent[Int(cur)]
                parent[Int(cur)] = root
                cur = next
            }
            return root
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb }
        }

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if mask[i] == 0 { continue }
                var neighbours: [Int32] = []
                if x > 0, labels[i - 1] != 0 { neighbours.append(labels[i - 1]) }
                if y > 0 {
                    if labels[i - w] != 0 { neighbours.append(labels[i - w]) }
                    if x > 0, labels[i - w - 1] != 0 { neighbours.append(labels[i - w - 1]) }
                    if x < w - 1, labels[i - w + 1] != 0 { neighbours.append(labels[i - w + 1]) }
                }
                if neighbours.isEmpty {
                    let newLabel = Int32(parent.count)
                    parent.append(newLabel)
                    labels[i] = newLabel
                } else {
                    var best = neighbours[0]
                    for n in neighbours.dropFirst() where n < best { best = n }
                    labels[i] = best
                    for n in neighbours where n != best { union(best, n) }
                }
            }
        }

        // Second pass: accumulate per-root statistics.
        struct Acc {
            var n = 0
            var sx = 0.0, sy = 0.0
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            var minX = Int.max, maxX = Int.min
            var minY = Int.max, maxY = Int.min
        }
        var acc: [Int32: Acc] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let l = labels[y * w + x]
                if l == 0 { continue }
                let root = find(l)
                var a = acc[root] ?? Acc()
                let dx = Double(x), dy = Double(y)
                a.n += 1
                a.sx += dx; a.sy += dy
                a.sxx += dx * dx; a.syy += dy * dy; a.sxy += dx * dy
                if x < a.minX { a.minX = x }
                if x > a.maxX { a.maxX = x }
                if y < a.minY { a.minY = y }
                if y > a.maxY { a.maxY = y }
                acc[root] = a
            }
        }

        var blobs: [Blob] = []
        for (root, a) in acc {
            let n = Double(a.n)
            guard n > 0 else { continue }
            let mx = a.sx / n, my = a.sy / n
            // Central second moments, normalised by area.
            let mu20 = a.sxx / n - mx * mx
            let mu02 = a.syy / n - my * my
            let mu11 = a.sxy / n - mx * my
            let common = ((mu20 - mu02) * (mu20 - mu02) + 4 * mu11 * mu11).squareRoot()
            let l1 = max(0, (mu20 + mu02 + common) / 2)
            let l2 = max(0, (mu20 + mu02 - common) / 2)
            // For a solid ellipse the covariance eigenvalues are (a/2)^2 and
            // (b/2)^2, so a full axis length is 4*sqrt(lambda).
            let majorAxis = 4 * l1.squareRoot()
            let minorAxis = 4 * l2.squareRoot()
            // Major-axis orientation; the minor axis is 90 degrees off it.
            let thetaDeg = 0.5 * atan2(2 * mu11, mu20 - mu02) * 180 / Double.pi
            blobs.append(Blob(count: a.n, meanX: mx, meanY: my,
                              majorAxis: majorAxis, minorAxis: minorAxis,
                              minorAxisDeg: thetaDeg + 90,
                              minX: a.minX, maxX: a.maxX,
                              minY: a.minY, maxY: a.maxY,
                              root: root))
        }
        // Deterministic order so repeated runs on one frame agree.
        blobs.sort { $0.meanY != $1.meanY ? $0.meanY < $1.meanY : $0.meanX < $1.meanX }

        // Resolve every pixel to its root so callers can test membership.
        var resolved = [Int32](repeating: 0, count: w * h)
        for i in 0..<(w * h) where labels[i] != 0 {
            resolved[i] = find(labels[i])
        }
        return (blobs, resolved)
    }
}
