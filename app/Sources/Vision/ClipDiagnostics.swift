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
    /// Where the frame rate came from. Worth reporting on its own line: a
    /// wrong rate is invisible in every other number, because everything
    /// downstream is simply scaled by it and stays plausible.
    enum FPSSource: String { case measured, container, override }
    var fpsSource: FPSSource = .container
    /// What the container claimed, when it claimed anything. Kept even when
    /// the measurement wins, because the two disagreeing is the signature of
    /// slow-motion footage and worth seeing.
    var containerFps: Double?
    /// Fraction of frame intervals well away from the median — variable frame
    /// rate, which breaks the constant-interval assumption every timing
    /// measurement rests on.
    var frameIntervalIrregularFraction: Double?
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
        out.append(String(format: "clip     %dx%d  %.1fs  %.2f fps (%@)  %d frames decoded",
                          width, height, durationS, fps,
                          fpsSource.rawValue, framesDecoded))
        // Printed whenever the two disagree at all. This single line is the
        // whole slow-motion story: a 240 fps original wearing a 30 fps label.
        if let container = containerFps, abs(container - fps) > 0.5 {
            out.append(String(format: "         container metadata says %.2f fps — measured timing used instead",
                              container))
        }
        if let irregular = frameIntervalIrregularFraction, irregular > 0.05 {
            out.append(String(format: "         %.0f%% of frame intervals are irregular — variable frame rate, timing is unreliable",
                              irregular * 100))
        }
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
            // The rate is now measured from the sample timing rather than read
            // off the container, so a low number here is far more likely to be
            // true than it used to be — the advice changed with it.
            out.append(String(format:
                "%.0f fps, measured from the clip's own frame timing rather than its metadata. At this rate the ball moves too far between frames to track: film in slow motion (Camera → Slo-Mo) and import with \"From Photos\", which is the only route that keeps the original high-rate frames. Every other way of getting a clip off the phone renders the slow-motion EDIT, which really is %.0f fps.",
                fps, fps))
        }
        if let irregular = frameIntervalIrregularFraction, irregular > 0.05 {
            out.append(String(format:
                "%.0f%% of the frame intervals differ from the typical one. Every timing measurement here — exit velocity above all — assumes frames arrive evenly, so this footage will read wrong by however uneven it is. Re-record rather than re-encode: a variable-rate file cannot be repaired after the fact.",
                irregular * 100))
        }
        // The opposite of "nothing matched", and until now it had no note at
        // all: the report would print "21.114%" and leave the reader to know
        // that a ball is about 0.05% of a frame. Three orders of magnitude is
        // not a tuning nudge, it is the detector looking at scenery.
        if let fraction = inWindowFraction, fraction > 0.02 {
            out.append(String(format:
                "%.1f%% of every frame matches the ball's colour window. A ball at this distance is a few hundredths of one percent, so the window is admitting the background wholesale — sunlit grass is the usual culprit, since it shares optic yellow's hue. Raise the LOWER SATURATION first (Settings → Ball colour): vegetation is dull where the ball is fluorescent, and that one number separates them without touching the hue at all.",
                fraction * 100))
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

    /// Mean share of the frame passing the colour window, over the probed
    /// frames. `nil` when nothing was probed.
    private var inWindowFraction: Double? {
        guard probedFrames > 0, !inWindowPixels.isEmpty, width > 0, height > 0 else { return nil }
        let mean = Double(inWindowPixels.reduce(0, +)) / Double(inWindowPixels.count)
        return mean / Double(width * height)
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
        // Checked before the track checks below, because when the window is
        // this wide everything downstream is a consequence rather than a
        // separate fault, and naming the consequence sends people tuning the
        // wrong number.
        if let fraction = inWindowFraction, fraction > 0.05 {
            return String(format:
                "the colour window is far too wide — %.0f%% of every frame matches it, where a ball is a few hundredths of one percent. Everything after this stage is measuring background. Raise the lower saturation in Settings → Ball colour.",
                fraction * 100)
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

        // Everything above asks whether the PIPELINE ran. That is not the same
        // question as whether the answer means anything, and answering only
        // the first is how a -66 degree launch angle off a nineteen-second
        // "flight" came back labelled "clean run." — the single most
        // misleading thing this report has ever said. The checks below are the
        // second question.

        // A slow-pitch ball is in frame for a few hundred milliseconds. A
        // track lasting seconds is not a flight; it is something stationary
        // and ball-coloured being followed patiently across the whole clip.
        if fps > 0 {
            let trackSeconds = Double(bestTrackFrames) / fps
            if trackSeconds > Self.implausibleTrackSeconds {
                return String(format:
                    "the longest \"flight\" lasts %.1f s. A hit ball crosses the frame in a fraction of a second, so this is a stationary object of about the right colour being tracked, not a swing — look at the colour line above: if a large share of every frame matches, the detector is following the background.",
                    trackSeconds)
            }
        }

        if flags.contains("HIGH_RESIDUAL") {
            return "a track was measured but it does not fit a parabola, which a ball in flight must. The points being tracked are not one object moving ballistically — most often background clutter sharing the ball's colour."
        }

        if let angle = launchAngleDeg,
           angle < Self.plausibleLaunchLoDeg || angle > Self.plausibleLaunchHiDeg {
            return String(format:
                "measured %.0f degrees, which is not a hit — that is the ball going almost straight %@. Whatever was tracked, it was not a struck ball.",
                angle, angle < 0 ? "into the ground" : "up")
        }

        if flags.contains("DEPTH_MOTION") {
            return "the ball was moving toward or away from the camera rather than across it, so it is foreshortened and reads slow. This is a camera-placement problem, not a detection one: stand square to the flight, on the side the hitter faces."
        }

        return "clean run."
    }

    /// Longest a tracked object may persist and still be called a flight.
    ///
    /// Generous — a high slow-pitch arc hangs, and the clip may catch part of
    /// the descent — but nothing like the seconds a mis-tracked patch of turf
    /// will happily produce.
    private static let implausibleTrackSeconds = 2.5

    /// Outside this, the number is not a mis-measured hit, it is not a hit.
    private static let plausibleLaunchLoDeg = -25.0
    private static let plausibleLaunchHiDeg = 75.0
}
