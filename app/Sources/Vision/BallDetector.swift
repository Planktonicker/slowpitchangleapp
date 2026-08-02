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

    /// One stationary ball, near a point the user tapped.
    ///
    /// Deliberately a separate path from `detect`, which is a byte-for-byte
    /// port of `sla_common.py` and pinned by ParityTests — it must not change.
    /// This one may be smarter because the problem is easier and different:
    /// a single ball at rest, whose location the user has just pointed at, and
    /// whose only output is a scale the user can see and re-measure.
    ///
    /// Three things it does that `detect` cannot:
    ///  * **No morphological close.** Closing is exactly what bridges the
    ///    ball's mask into adjacent grass — the default hue window's upper end
    ///    (48 in OpenCV terms) reaches into turf — producing one giant blob
    ///    that then fails the area or elongation test. This is why a ball on
    ///    the ground failed where a ball on a tee against sky succeeded.
    ///  * **Tightens the hue ceiling and retries** when the blob under the tap
    ///    is implausibly large or elongated, walking the yellow/green boundary
    ///    down until the ball separates from the turf.
    ///  * **Derives the size band from optics** rather than the fixed 8–120 px
    ///    window, which silently rejected any ball closer than about 3.6 ft.
    ///
    /// Returns the candidate nearest the tap — not the largest. On grass the
    /// largest blob is the grass.
    static func measureAt(image: PixelImage,
                          nearX: Double,
                          nearY: Double,
                          searchRadiusPx: Double,
                          settings: DetectorSettings = DetectorSettings(),
                          fovDeg: Double = 0) -> BallMeasurement? {
        // Optics-derived plausible diameters, when the field of view is known.
        // A ball 2 ft away and one 60 ft away bracket anything a user could
        // reasonably be pointing at.
        var minDiameter = 2 * settings.minRadiusPx
        var maxDiameter = 2 * settings.maxRadiusPx
        if fovDeg > 0 {
            let halfFov = fovDeg * .pi / 360
            let pxPerMAt = { (d: Double) in
                Double(image.width) / (2 * d * tan(halfFov))
            }
            minDiameter = SLA.ballDiameterM * pxPerMAt(18.3)   // 60 ft
            maxDiameter = SLA.ballDiameterM * pxPerMAt(0.61)   // 2 ft
        }

        var tuned = settings
        for attempt in 0..<4 {
            let roi = ROI.around(x: nearX, y: nearY, radius: searchRadiusPx)
                .clamped(width: image.width, height: image.height)
            if let found = measureOnce(image: image, roi: roi, settings: tuned,
                                       nearX: nearX, nearY: nearY,
                                       minDiameter: minDiameter,
                                       maxDiameter: maxDiameter) {
                return found
            }
            // Walk the hue ceiling down towards pure yellow and try again.
            // Optic yellow sits around 22-35 in OpenCV hue; grass runs from
            // roughly 35 up. Converges in one or two steps in practice.
            guard attempt < 3 else { break }
            tuned.hsvHi.h = max(tuned.hsvLo.h + 6, tuned.hsvHi.h - 6)
        }
        return nil
    }

    private static func measureOnce(image: PixelImage,
                                    roi: ROI,
                                    settings: DetectorSettings,
                                    nearX: Double,
                                    nearY: Double,
                                    minDiameter: Double,
                                    maxDiameter: Double) -> BallMeasurement? {
        let w = roi.x1 - roi.x0, h = roi.y1 - roi.y0
        guard w > 2, h > 2 else { return nil }

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
        // Open only — no close. See the note on `measureAt`.
        Morphology.open(&mask, width: w, height: h)

        let blobs = ConnectedComponents.label(mask: mask, width: w, height: h)
        var best: BallMeasurement?
        var bestDistance = Double.infinity

        for blob in blobs {
            let area = Double(blob.count)
            guard area >= Double.pi * settings.minRadiusPx * settings.minRadiusPx
            else { continue }

            let cx = Double(roi.x0) + blob.meanX
            let cy = Double(roi.y0) + blob.meanY

            var minor = blob.minorAxis
            let major = blob.majorAxis
            // A ball at rest is round. Anything long is turf or a shadow.
            if major > 0 && minor > 1e-6 && major / minor > 2.5 { continue }
            if minor <= 1e-6 { continue }

            var refined = false
            if let sub = subpixelMinorDiameter(image: image, cx: cx, cy: cy,
                                               minorAxisDeg: blob.minorAxisDeg,
                                               r0: minor / 2.0) {
                minor = sub
                refined = true
            }
            guard minor >= minDiameter, minor <= maxDiameter else { continue }

            let dx = cx - nearX, dy = cy - nearY
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = BallMeasurement(diameterPx: minor, x: cx, y: cy,
                                       areaPx: area, subpixelRefined: refined)
            }
        }
        return best
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
    }

    /// Two-pass 8-connected labelling with union-find.
    static func label(mask: [UInt8], width w: Int, height h: Int) -> [Blob] {
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
                acc[root] = a
            }
        }

        var blobs: [Blob] = []
        for (_, a) in acc {
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
                              minorAxisDeg: thetaDeg + 90))
        }
        // Deterministic order so repeated runs on one frame agree.
        blobs.sort { $0.meanY != $1.meanY ? $0.meanY < $1.meanY : $0.meanX < $1.meanX }
        return blobs
    }
}
