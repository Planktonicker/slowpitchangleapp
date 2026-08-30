// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// What the analyser saw, in a form that fits in a message.
///
/// The problem this solves: a failed clip says "No ball flight found" and
/// nothing else, so every field failure has been diagnosed by guessing. The
/// footage that would settle it is hundreds of megabytes and cannot leave the
/// phone; this is a few hundred bytes of the same information.
///
/// It records the pipeline stage by stage, because *which* stage failed is
/// almost the whole answer:
///
///  * no pixels passed the colour window  -> the ball's colour is outside it
///  * pixels passed but no candidates     -> the size or shape gates are wrong
///  * candidates but no track             -> they are not the same object
///    frame to frame, or the direction filter is dropping the flight
///  * a track but a bad number            -> scale or fit, not detection
///
/// Filled in during analysis and kept by the caller, so it survives the
/// analysis throwing — a clip that produced nothing is exactly the one worth
/// reporting on.
///
/// Not `Sendable`, deliberately: `ClipAnalyzer` walks frames sequentially and
/// this is written from that walk. Handing it to anything concurrent would need
/// locking it does not have.
final class ClipDiagnostics {

    // Clip facts
    var fps: Double = 0
    var width = 0
    var height = 0
    var durationS: Double = 0
    var framesDecoded = 0
    var fpsWasOverridden = false
    /// Set when the radius gates were rescaled for a non-1080p clip.
    var radiusScale: Double?
    /// Wall-clock seconds for the whole analysis. Reported because "it takes
    /// forever" and "it takes eleven seconds" are different bug reports, and
    /// only one of them is actionable.
    var elapsedS: Double?

    // Stage 1 — Vision's trajectory hint
    var hintPoints: Int?

    // Stage 2 — colour and shape
    /// Frames probed for raw colour coverage. A handful, spread through the
    /// clip: counting in-window pixels on all of them would double the cost of
    /// a pass that already walks every pixel.
    var probedFrames = 0
    var inWindowPixels: [Int] = []
    var framesWithCandidates = 0
    var totalCandidates = 0
    var candidateDiametersPx: [Double] = []

    // Stage 3 — tracking
    var tracksBuilt = 0
    var bestTrackFrames = 0

    // Stage 4 — bat and body
    var batTapeFrames = 0
    var poseFramesSampled = 0
    var poseFramesWithPerson = 0
    var jointSeenCount: [PoseJoint: Int] = [:]
    var jointConfidenceSum: [PoseJoint: Double] = [:]

    // Outcome
    var failure: String?
    var launchAngleDeg: Double?
    var exitVeloMph: Double?
    var scaleMPerPx: Double?
    var flags: [String] = []

    func noteJoint(_ joint: PoseJoint, confidence: Double) {
        jointSeenCount[joint, default: 0] += 1
        jointConfidenceSum[joint, default: 0] += confidence
    }

    /// The report, as plain text meant to be pasted into a message.
    ///
    /// Terse on purpose. Every line is a number somebody can act on, and the
    /// verdict at the end names the stage that failed rather than leaving it to
    /// be inferred from the numbers above it.
    func report(detector: DetectorSettings) -> String {
        var out = ["SwingLab clip diagnostics"]
        out.append("--------------------------------")
        out.append(String(format: "clip     %dx%d  %.1fs  %.0f fps%@  %d frames decoded",
                          width, height, durationS, fps,
                          fpsWasOverridden ? " (overridden)" : "", framesDecoded))
        if let elapsed = elapsedS {
            out.append(String(format: "took     %.1fs (%.0f ms per decoded frame)",
                              elapsed, 1000 * elapsed / Double(max(1, framesDecoded))))
        }
        out.append(String(format: "hsv      lo %.0f/%.0f/%.0f  hi %.0f/%.0f/%.0f  radius %.0f-%.0f px",
                          detector.hsvLo.h, detector.hsvLo.s, detector.hsvLo.v,
                          detector.hsvHi.h, detector.hsvHi.s, detector.hsvHi.v,
                          detector.minRadiusPx * (radiusScale ?? 1),
                          detector.maxRadiusPx * (radiusScale ?? 1)))
        if let k = radiusScale {
            out.append(String(format: "           radii scaled x%.2f for a %d px wide clip", k, width))
        }

        out.append("")
        out.append("1 vision   " + (hintPoints.map { "flight found, \($0) points" }
                                    ?? "no flight found (fell back to full-frame)"))

        let framePixels = max(1, width * height)
        if probedFrames > 0 {
            let mean = inWindowPixels.reduce(0, +) / max(1, inWindowPixels.count)
            let peak = inWindowPixels.max() ?? 0
            out.append(String(format: "2 colour   %d frames probed: mean %d px in window (%.3f%%), peak %d",
                              probedFrames, mean, 100.0 * Double(mean) / Double(framePixels), peak))
        }
        out.append("3 shape    \(framesWithCandidates)/\(framesDecoded) frames produced a candidate, \(totalCandidates) total")
        if !candidateDiametersPx.isEmpty {
            let d = candidateDiametersPx.sorted()
            out.append(String(format: "           diameter px  min %.1f  median %.1f  max %.1f",
                              d.first!, d[d.count / 2], d.last!))
        }
        out.append("4 track    \(tracksBuilt) tracks built, longest \(bestTrackFrames) frames")
        out.append("5 bat      \(batTapeFrames) frames with barrel tape")

        if poseFramesSampled > 0 {
            out.append(String(format: "6 body     person in %d/%d sampled frames (%.0f%%)",
                              poseFramesWithPerson, poseFramesSampled,
                              100.0 * Double(poseFramesWithPerson) / Double(poseFramesSampled)))
            for joint in PoseJoint.allCases {
                let seen = jointSeenCount[joint] ?? 0
                let mean = seen > 0 ? (jointConfidenceSum[joint] ?? 0) / Double(seen) : 0
                out.append(String(format: "           %-15@ %3d/%3d  mean conf %.2f",
                                  joint.rawValue as NSString, seen, poseFramesSampled, mean))
            }
        } else {
            out.append("6 body     not run")
        }

        for note in notes() { out.append("note       " + note) }

        out.append("")
        if let failure {
            out.append("result     FAILED — \(failure)")
        } else {
            out.append(String(format: "result     %.1f deg at %.1f mph, scale %.5f m/px",
                              launchAngleDeg ?? .nan, exitVeloMph ?? .nan, scaleMPerPx ?? .nan))
            if !flags.isEmpty { out.append("flags      " + flags.joined(separator: " ")) }
        }
        out.append("verdict    " + verdict())
        return out.joined(separator: "\n")
    }

    /// Things the clip's own numbers say about the footage, separate from
    /// whether the pipeline worked. Both of these have cost a field trip
    /// before: footage that turned out not to be 240 fps, and a whole session
    /// in one file where a swing was expected.
    private func notes() -> [String] {
        var out: [String] = []
        if fps > 0 && fps < 100 {
            out.append(String(format:
                "%.0f fps, not 240. Exit velocity scales directly with frame rate, so if this is really slow-motion footage the rate is being read wrong — set Settings → Analysis → \"Imported clip frame rate\". If it is genuinely %.0f fps, the ball moves too far between frames to track.",
                fps, fps))
        }
        if durationS > 20 {
            out.append(String(format:
                "%.0fs long — a whole session rather than one swing. Only the single best track in the file is measured, so the other swings in it are discarded silently. Trim to the swing you care about.",
                durationS))
        }
        if width > 0 && width < 1900 && radiusScale == nil {
            out.append(String(format:
                "%d px wide, not 1920. The ball is correspondingly smaller, so the minimum-radius gate may reject it.",
                width))
        }
        return out
    }

    /// Name the stage that failed. The numbers above already contain this, but
    /// stating it means the report is useful to somebody who has not memorised
    /// the pipeline — which includes whoever reads it in six months.
    private func verdict() -> String {
        if framesDecoded == 0 {
            // Metadata reads need no decoder, so knowing the size and duration
            // while decoding nothing points at the decoder rather than the file.
            let readMetadata = width > 0 && durationS > 0
            return readMetadata
                ? "the file's metadata read fine but not one frame decoded — that is the hardware video decoder being unavailable, not a bad file. Close anything else using the camera and retry."
                : "clip could not be decoded at all"
        }
        if probedFrames > 0, (inWindowPixels.max() ?? 0) < 20 {
            return "the ball's colour is outside the HSV window — almost nothing in any frame matched. Widen it, or the ball is not optic yellow under this light."
        }
        if framesWithCandidates == 0 {
            return "colour matched but nothing passed the size and shape gates. Check the diameter range against how big the ball actually is here."
        }
        if bestTrackFrames < 3 {
            return "candidates were found but never linked into a flight — they are probably not the same object frame to frame (background clutter of a similar colour)."
        }
        if failure != nil {
            return "a track was built but analysis rejected it; see the failure line."
        }
        if bestTrackFrames < SLA.minTrackFrames {
            return "measured, but off a short track — treat the number as provisional."
        }
        return "clean run."
    }
}
