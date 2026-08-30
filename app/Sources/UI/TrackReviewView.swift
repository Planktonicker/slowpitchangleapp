// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// The clip, played back with everything the app measured drawn on top of it.
///
/// This exists because every other diagnostic is a number about a picture
/// nobody can see. A report saying "1902 tracks built, longest 3769 frames"
/// tells you something is wrong; it cannot tell you the detector spent the
/// whole clip following a stripe of sunlit grass. Drawing the track on the
/// footage answers that in about one second, and it is the same answer for
/// every failure mode at once — wrong object, right object lost halfway,
/// hitter never found, ball detected but at the wrong size.
///
/// Nothing here re-measures anything. It reads the ball track CSV and the pose
/// JSON that analysis already wrote beside the clip, so what is drawn is
/// exactly what was measured, not a second opinion computed for display. If
/// the overlay looks wrong, the measurement was wrong.
struct TrackReviewView: View {
    let swing: SwingDTO

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var track: [BallObservation] = []
    @State private var pose: [PoseObservation] = []
    @State private var trace = DetectionTrace()
    @State private var naturalSize: CGSize = .zero
    @State private var transform: CGAffineTransform = .identity
    @State private var currentTime: Double = 0
    @State private var durationS: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    @State private var loadFailure: String?

    @State private var showBall = true
    @State private var showTrail = true
    @State private var showSkeleton = true
    @State private var showRejects = true
    @State private var showOtherTracks = true
    /// Where the user says the true horizon is, as a fraction down the
    /// picture. `nil` until the tool is opened.
    @State private var horizonFraction: Double?
    @State private var showHorizonTool = false
    @State private var pickingBall = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                picture
                controls
            }
            .background(Theme.black)
            .navigationTitle("What was tracked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
        }
    }

    // MARK: - Picture

    @ViewBuilder private var picture: some View {
        if let player {
            GeometryReader { geo in
                ZStack {
                    PlayerLayerView(player: player)
                    if naturalSize != .zero {
                        overlay(in: geo.size)
                            .allowsHitTesting(false)
                        if showHorizonTool {
                            horizonTool(in: geo.size)
                        }
                        if pickingBall {
                            ballPicker(in: geo.size)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.steel)
                Text(loadFailure ?? "Loading the clip…")
                    .font(.callout).foregroundStyle(Theme.steel)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Plain function, not a `@ViewBuilder` property: it needs local helpers.
    private func overlay(in size: CGSize) -> some View {
        func map(_ x: Double, _ y: Double) -> CGPoint {
            VideoOverlayGeometry.viewPoint(bufferPoint: CGPoint(x: x, y: y),
                                           natural: naturalSize,
                                           transform: transform, in: size)
        }
        let scale = VideoOverlayGeometry.scale(natural: naturalSize,
                                               transform: transform, in: size)
        let ball = nearestBall
        let joints = nearestPose

        return ZStack {
            // What was actually looked at. Everything outside this outline was
            // never examined at any threshold, so a ball sitting out there is
            // not a detection failure — it is a search that did not go near
            // it, which is a different fix entirely.
            if showRejects, trace.hasSearchRegion,
               let x0 = trace.searchedX0, let y0 = trace.searchedY0,
               let x1 = trace.searchedX1, let y1 = trace.searchedY1 {
                let a = map(Double(x0), Double(y0))
                let b = map(Double(x1), Double(y1))
                Path { p in
                    p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                     width: abs(b.x - a.x), height: abs(b.y - a.y)))
                }
                .stroke(Theme.steel.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            }

            // Candidates the detector found and the pipeline then discarded —
            // by the corridor filter, or by track building preferring another
            // chain. Drawn amber so they cannot be mistaken for the green
            // measured ball. A ball with an amber ring on it was SEEN; the
            // question is then why it was dropped, not why it was missed.
            if showRejects {
                ForEach(Array(rejectedNow.enumerated()), id: \.offset) { _, o in
                    let d = max(6, o.diameterPx * Double(scale))
                    Circle()
                        .strokeBorder(Theme.warn.opacity(0.9), lineWidth: 1.5)
                        .frame(width: d, height: d)
                        .position(map(o.x, o.y))
                }
            }

            // Every OTHER track the builder produced. This is the layer that
            // answers "the ball IS being tracked, why wasn't it chosen?" —
            // if one of these follows the ball, the fault is in selection; if
            // none does, it is in linking. Nothing else in the app could tell
            // those apart.
            if showOtherTracks {
                ForEach(Array(trace.trackSummaries.enumerated()), id: \.offset) { _, t in
                    if !t.selected, t.points.count >= 2 {
                        Path { p in
                            p.move(to: map(t.points[0].x, t.points[0].y))
                            for q in t.points.dropFirst() { p.addLine(to: map(q.x, q.y)) }
                        }
                        .stroke(Theme.steel.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
            }

            // The whole flight, faint. Being able to see the shape of the path
            // at a glance is most of the diagnosis: a parabola is a hit, a
            // straight line across the grass is not, and a knot of scribble in
            // one place is the detector sitting on a stationary object.
            if showTrail, track.count >= 2 {
                Path { p in
                    p.move(to: map(track[0].x, track[0].y))
                    for o in track.dropFirst() { p.addLine(to: map(o.x, o.y)) }
                }
                .stroke(Theme.yellow.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // Where the ball is right now, at the size it was measured. The
            // circle is drawn at the MEASURED diameter rather than a fixed
            // marker size on purpose: scale comes from that diameter, so a
            // circle visibly bigger or smaller than the ball under it is a
            // scale error made visible, which no number in the report shows.
            if showBall, let o = ball {
                let d = max(6, o.diameterPx * Double(scale))
                Circle()
                    .strokeBorder(Theme.pass, lineWidth: 2)
                    .frame(width: d, height: d)
                    .position(map(o.x, o.y))
                Circle()
                    .fill(Theme.pass)
                    .frame(width: 3, height: 3)
                    .position(map(o.x, o.y))
            }

            if showSkeleton, let joints {
                skeleton(joints, map: map)
            }
        }
    }

    /// `map` is `@escaping` because `ForEach` stores its content closure rather
    /// than calling it inline, so the mapper has to outlive this call.
    private func skeleton(_ observation: PoseObservation,
                          map: @escaping (Double, Double) -> CGPoint) -> some View {
        ZStack {
            ForEach(Array(PoseJoint.segments.enumerated()), id: \.offset) { _, segment in
                Path { p in
                    var started = false
                    for joint in segment {
                        guard let pt = observation.point(joint) else {
                            // A break, not a shortcut. Joining across a joint
                            // the model was not sure about would draw a limb
                            // that was never detected, and hide the gap that
                            // explains a missing body measurement.
                            started = false
                            continue
                        }
                        let v = map(pt.x, pt.y)
                        if started { p.addLine(to: v) } else { p.move(to: v); started = true }
                    }
                }
                .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            ForEach(PoseJoint.allCases, id: \.self) { joint in
                if let pt = observation.point(joint) {
                    Circle()
                        .fill(Theme.yellow)
                        .frame(width: 6, height: 6)
                        .position(map(pt.x, pt.y))
                }
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 2)
    }

    // MARK: - Picking the ball

    /// A full-picture tap target for pointing at the ball.
    ///
    /// This is the escape hatch that makes a cluttered clip measurable at all.
    /// Deciding which of six hundred tracks is the ball is a heuristic on
    /// footage like a phone lying in grass — every rule tried has picked the
    /// pitch, the landing, or a patch of turf. A tap is not a heuristic. It
    /// settles the one question the pipeline genuinely cannot answer, and the
    /// track is then followed outward from that point by physics alone.
    private func ballPicker(in size: CGSize) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let buffer = VideoOverlayGeometry.bufferPoint(
                    viewPoint: location, natural: naturalSize,
                    transform: transform, in: size) else { return }
                applyBallSeed(t: currentTime, x: Double(buffer.x), y: Double(buffer.y))
            }
            .overlay(alignment: .top) {
                Text("TAP THE BALL")
                    .font(Theme.label(11)).tracking(1.3)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.pass, in: Capsule())
                    .padding(.top, 10)
            }
    }

    /// Stamp the tap onto the swing and measure again from it.
    private func applyBallSeed(t: Double, x: Double, y: Double) {
        var updated = swing
        updated.ballSeedT = t
        updated.ballSeedX = x
        updated.ballSeedY = y
        model.update(updated)
        model.reanalyze(updated)
        pickingBall = false
        dismiss()
    }

    // MARK: - Horizon

    /// Half the vertical field of view of the picture as shown.
    ///
    /// The lens angle is quoted horizontally for the sensor's landscape frame,
    /// so which way the clip was turned decides what vertical angle the screen
    /// is showing. Getting that backwards would scale every tilt read off this
    /// tool by the frame's aspect ratio.
    private var displayedVerticalHalfDeg: Double? {
        let fov = swing.cameraFovDeg ?? model.settings.importFovDeg
        guard fov > 1, naturalSize.width > 0, naturalSize.height > 0 else { return nil }
        if VideoOverlayGeometry.isQuarterTurned(natural: naturalSize, transform: transform) {
            // The display's vertical spans the buffer's WIDTH, which is what
            // the horizontal field of view describes.
            return fov / 2
        }
        return CameraPose.verticalHalfAngleDeg(
            horizontalFovDeg: fov,
            frameAspect: Double(naturalSize.width / naturalSize.height))
    }

    /// The tilt implied by where the line has been dragged.
    private var horizonTiltDeg: Double? {
        guard let f = horizonFraction, let vHalf = displayedVerticalHalfDeg else { return nil }
        return CameraPose.tiltDeg(forHorizonFraction: f, visibleVerticalHalfAngleDeg: vHalf)
    }

    /// A line to drag onto the real horizon.
    ///
    /// An imported clip carries no tilt reading — the stock Camera app records
    /// none — so the correction that exists for filmed clips could never run on
    /// one. The horizon is in the picture though, and where it sits IS the
    /// angle: dragging a line onto the tree line measures by hand exactly what
    /// the accelerometer would have. Roughly right is worth having, because the
    /// rectification is smooth in the angle and has no cliff: a horizon a few
    /// degrees out still lands far closer than pretending the camera was level.
    private func horizonTool(in size: CGSize) -> some View {
        let display = VideoOverlayGeometry.displaySize(natural: naturalSize, transform: transform)
        let rect = VideoOverlayGeometry.videoRect(displaySize: display, in: size)
        let fraction = horizonFraction ?? 0.5
        let y = rect.minY + CGFloat(fraction) * rect.height

        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: y))
                p.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            .stroke(Theme.pass, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))

            Text("DRAG ONTO THE HORIZON")
                .font(Theme.label(10)).tracking(1.2)
                .foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.pass, in: Capsule())
                .position(x: rect.midX, y: y - 16)

            // A wide invisible grab bar. The line itself is two points tall and
            // would be nearly impossible to catch with a fingertip.
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: max(1, rect.width), height: 60)
                .position(x: rect.midX, y: y)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard rect.height > 1 else { return }
                            horizonFraction = min(1, max(0,
                                Double((value.location.y - rect.minY) / rect.height)))
                        }
                )
        }
    }

    /// The row that turns a dragged line into a re-measurement.
    private var horizonBar: some View {
        VStack(spacing: 8) {
            if let tilt = horizonTiltDeg {
                Text(abs(tilt) < 0.5
                     ? "Camera was level"
                     : String(format: "Camera was aiming %@ %.1f°",
                              tilt > 0 ? "down" : "up", abs(tilt)))
                    .font(Theme.numeral(15))
                    .foregroundStyle(Theme.pass)
            } else {
                Text("Drag the green line onto the real horizon — the tree line, the far fence, where the ground meets the sky.")
                    .font(.caption).foregroundStyle(Theme.steel)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel") {
                    showHorizonTool = false
                    horizonFraction = nil
                }
                .buttonStyle(OutlineButtonStyle())
                Button("Re-measure with this tilt") {
                    applyHorizonTilt()
                }
                .buttonStyle(SlabButtonStyle(fill: Theme.yellow, verticalPadding: 12))
                .disabled(horizonTiltDeg == nil)
            }
        }
    }

    /// Stamp the measured tilt onto the swing and run the clip again.
    ///
    /// The FOV goes on too. Without it there is no focal length, and the
    /// rectification is a homography in the tilt angle AND the focal length —
    /// an angle on its own corrects nothing.
    private func applyHorizonTilt() {
        guard let tilt = horizonTiltDeg else { return }
        var updated = swing
        updated.cameraTiltDeg = tilt
        updated.cameraFovDeg = swing.cameraFovDeg ?? model.settings.importFovDeg
        model.update(updated)
        model.reanalyze(updated)
        showHorizonTool = false
        horizonFraction = nil
        dismiss()
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            readout

            Slider(value: Binding(
                get: { currentTime },
                set: { seek(to: $0) }),
                   in: 0...max(0.01, durationS),
                   onEditingChanged: { editing in
                       isScrubbing = editing
                       if editing { player?.pause() }
                   })
            .tint(Theme.yellow)

            HStack(spacing: 20) {
                stepButton("backward.frame.fill", frames: -1)
                Button {
                    if player?.timeControlStatus == .playing { player?.pause() }
                    else { player?.play() }
                } label: {
                    Image(systemName: player?.timeControlStatus == .playing
                          ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 54, height: 40)
                }
                stepButton("forward.frame.fill", frames: 1)
            }
            .foregroundStyle(Theme.yellow)

            if showHorizonTool {
                horizonBar
            }

            HStack(spacing: 14) {
                toggleChip("Ball", isOn: $showBall, colour: Theme.pass)
                toggleChip("Path", isOn: $showTrail, colour: Theme.yellow)
                toggleChip("Body", isOn: $showSkeleton, colour: Theme.yellow)
                toggleChip("Rejected", isOn: $showRejects, colour: Theme.warn)
                toggleChip("Tracks", isOn: $showOtherTracks, colour: Theme.steel)
            }

            if showOtherTracks, !trace.trackSummaries.isEmpty {
                otherTracksList
            }

            if !pickingBall, !showHorizonTool {
                Button {
                    pickingBall = true
                    player?.pause()
                } label: {
                    Label(swing.ballSeedT == nil
                          ? "Wrong thing tracked? Point at the ball"
                          : "Ball picked by hand — point again",
                          systemImage: "hand.tap")
                        .font(.callout)
                }
                .foregroundStyle(Theme.pass)
            }

            if pickingBall {
                VStack(spacing: 6) {
                    Text("Scrub to a frame where you can see the ball, then tap it. The flight is followed out from there — no guessing which track is which.")
                        .font(.caption).foregroundStyle(Theme.steel)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { pickingBall = false }
                        .buttonStyle(OutlineButtonStyle())
                }
            }

            if !showHorizonTool, !pickingBall {
                Button {
                    showHorizonTool = true
                    // Seeded from whatever tilt the swing already carries, so
                    // opening the tool on a corrected clip shows where the
                    // current answer puts the horizon rather than resetting it.
                    if let vHalf = displayedVerticalHalfDeg {
                        horizonFraction = CameraPose.horizonFraction(
                            tiltDeg: swing.cameraTiltDeg ?? 0,
                            visibleVerticalHalfAngleDeg: vHalf) ?? 0.5
                    } else {
                        horizonFraction = 0.5
                    }
                } label: {
                    Label(swing.cameraTiltDeg == nil
                          ? "Camera wasn't level? Set the horizon"
                          : String(format: "Tilt %.1f° — set the horizon again",
                                   swing.cameraTiltDeg ?? 0),
                          systemImage: "level")
                        .font(.callout)
                }
                .foregroundStyle(Theme.pass)
            }
        }
        .padding(14)
        .background(Theme.surface)
    }

    /// What is true at this instant, in words, beside the picture showing it.
    ///
    /// The two counts are the honest summary of the whole screen: a clip with
    /// thousands of frames and a handful of tracked ones is a detection
    /// failure however good the single best frame looks.
    private var readout: some View {
        VStack(spacing: 4) {
            HStack {
                Text(String(format: "%.3f s", currentTime))
                    .font(Theme.numeral(15))
                Spacer()
                if let o = nearestBall {
                    Text(String(format: "ball %.1f px", o.diameterPx))
                        .font(Theme.numeral(13)).foregroundStyle(Theme.pass)
                } else if !rejectedNow.isEmpty {
                    // The distinction the whole trace exists for. "No ball" and
                    // "a ball was found here and thrown away" send you to
                    // opposite ends of the pipeline.
                    Text("\(rejectedNow.count) found here, none used")
                        .font(Theme.label(11)).foregroundStyle(Theme.warn)
                } else if let cutoff = trace.truncatedAtT, currentTime > cutoff {
                    // Past the truncation point an empty frame is a statement
                    // about the FILE, not the footage, and saying "nothing
                    // detected" here once sent a whole debugging session after
                    // a detector that was working.
                    Text("trace full — finds past this point weren't saved")
                        .font(Theme.label(11)).foregroundStyle(Theme.steel)
                } else {
                    Text("nothing detected this frame")
                        .font(Theme.label(11)).foregroundStyle(Theme.steel)
                }
            }
            HStack {
                Text(trackSummary)
                Spacer()
                Text(poseSummary)
            }
            .font(Theme.label(10))
            .foregroundStyle(missingTrackFile ? Theme.warn : Theme.steel)
        }
    }

    /// The candidate tracks, fastest first, each with the selector's own
    /// reason for passing it over. Reading this beside the picture is what
    /// turns "it didn't pick the ball" into a specific, fixable statement.
    private var otherTracksList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(trace.tracksBuilt) tracks built — top by speed")
                .font(Theme.label(10)).tracking(1.1)
                .foregroundStyle(Theme.steel)
            ForEach(Array(trace.trackSummaries.prefix(4).enumerated()), id: \.offset) { _, t in
                HStack(spacing: 6) {
                    Text(t.selected ? "USED" : "—")
                        .font(Theme.label(9))
                        .foregroundStyle(t.selected ? Theme.pass : Theme.steel)
                        .frame(width: 34, alignment: .leading)
                    Text(String(format: "%d fr %.2f–%.2fs  %.0f px/s  str %.2f",
                                t.frames, t.startT, t.endT, t.speedPxS, t.straightness))
                        .font(Theme.numeral(10))
                    Spacer(minLength: 4)
                    Text(t.rejectedBecause)
                        .font(Theme.label(9))
                        .foregroundStyle(Theme.warn)
                        .lineLimit(1)
                }
                .foregroundStyle(t.selected ? Theme.pass : .white.opacity(0.75))
            }

            if !trace.stitchExplains.isEmpty {
                Text("why the fast pieces didn't join")
                    .font(Theme.label(9)).tracking(1.1)
                    .foregroundStyle(Theme.steel)
                    .padding(.top, 3)
                ForEach(Array(trace.stitchExplains.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Theme.numeral(9))
                        .foregroundStyle(Theme.warn)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A swing that measured frames but has no track file on disk is a
    /// DIFFERENT fault from one whose tracker found nothing, and saying "0
    /// tracked frames" for both sent somebody looking at a perfectly good clip
    /// wondering why the ball in plain sight was not detected. It had been —
    /// the evidence just was not written, which for a long time was true of
    /// every imported swing.
    private var missingTrackFile: Bool {
        track.isEmpty && swing.trackedFrames > 0
    }

    private var trackSummary: String {
        if missingTrackFile {
            return "measured \(swing.trackedFrames) frames — but no track file was saved with this swing, so there is nothing to draw. Re-import the clip."
        }
        return track.isEmpty ? "the tracker found no ball anywhere in this clip"
                             : "\(track.count) tracked frames"
    }

    private var poseSummary: String {
        if pose.isEmpty {
            return swing.body == nil ? "no body track" : "body measured, track not saved"
        }
        return "\(pose.count) pose samples"
    }

    private func stepButton(_ symbol: String, frames: Int) -> some View {
        Button {
            player?.pause()
            player?.currentItem?.step(byCount: frames)
            if let t = player?.currentTime().seconds, t.isFinite { currentTime = t }
        } label: {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 40)
        }
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>, colour: Color) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(Theme.label(11)).tracking(1.1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isOn.wrappedValue ? colour.opacity(0.25) : .clear,
                            in: Capsule())
                .overlay(Capsule().strokeBorder(
                    isOn.wrappedValue ? colour : Theme.steel.opacity(0.5), lineWidth: 1.5))
                .foregroundStyle(isOn.wrappedValue ? colour : Theme.steel)
        }
    }

    // MARK: - Lookup

    /// The tracked ball nearest the playhead, if one is close enough to be
    /// about this frame.
    ///
    /// Tolerance is a frame and a half: near enough to survive the player
    /// landing between samples, tight enough that "no ball this frame" stays
    /// true when the tracker really lost it, which is exactly the gap somebody
    /// scrubbing back and forth is looking for.
    private var nearestBall: BallObservation? {
        nearest(in: track, time: { $0.t })
    }

    private var nearestPose: PoseObservation? {
        nearest(in: pose, time: { $0.t })
    }

    /// Candidates at roughly this instant that did not make the final track.
    ///
    /// Compared by frame rather than by identity: a candidate that became the
    /// tracked ball is the same observation, and ringing it twice would say
    /// "found and rejected" about the one point that was neither.
    private var rejectedNow: [BallObservation] {
        guard !trace.candidates.isEmpty else { return [] }
        let fps = swing.fps > 1 ? swing.fps : SLA.targetFPS
        let tolerance = 1.5 / fps
        let used = Set(track.map(\.frame))
        return trace.candidates.filter {
            abs($0.t - currentTime) <= tolerance && !used.contains($0.frame)
        }
    }

    private func nearest<T>(in items: [T], time: (T) -> Double) -> T? {
        guard !items.isEmpty else { return nil }
        let fps = swing.fps > 1 ? swing.fps : SLA.targetFPS
        let tolerance = 1.5 / fps
        var best: T?
        var bestGap = Double.infinity
        for item in items {
            let gap = abs(time(item) - currentTime)
            if gap < bestGap { bestGap = gap; best = item }
        }
        return bestGap <= tolerance ? best : nil
    }

    // MARK: - Loading

    private func seek(to t: Double) {
        currentTime = t
        // Zero tolerance both ways. The default is half a second, which at
        // 240 fps is 120 frames — the scrubber would land nowhere near the
        // frame the overlay is drawing, and the two would disagree for reasons
        // that have nothing to do with the measurement.
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func load() async {
        if let name = swing.trackCSVFilename,
           let text = try? String(contentsOf: ClipStore.trackURL(named: name), encoding: .utf8) {
            track = TrackCSV.parse(text).track
        }
        if let name = swing.poseFilename,
           let data = try? Data(contentsOf: ClipStore.trackURL(named: name)) {
            pose = (try? JSONDecoder().decode([PoseObservation].self, from: data)) ?? []
        }
        if let name = swing.traceFilename,
           let data = try? Data(contentsOf: ClipStore.trackURL(named: name)) {
            trace = (try? JSONDecoder().decode(DetectionTrace.self, from: data)) ?? DetectionTrace()
        }

        guard let clip = swing.clipFilename else {
            loadFailure = "This swing has no clip saved — turn on Settings → Storage → Keep clips."
            return
        }
        let url = ClipStore.clipURL(named: clip)
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadFailure = "The clip for this swing is no longer on the device."
            return
        }
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            loadFailure = "That clip has no video track."
            return
        }
        if let size = try? await videoTrack.load(.naturalSize) {
            naturalSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        // Without this the overlay is drawn in encoded-buffer space over a
        // picture the player has already rotated — see `VideoOverlayGeometry`.
        if let t = try? await videoTrack.load(.preferredTransform) {
            transform = t
        }
        durationS = (try? await asset.load(.duration).seconds) ?? 0

        let p = AVPlayer(url: url)
        // Frame stepping and scrubbing both want exact frames, not the
        // player's convenience.
        p.currentItem?.seekingWaitsForVideoCompositionRendering = true
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main) { time in
                guard !isScrubbing, time.isNumeric else { return }
                currentTime = time.seconds
            }
        player = p
    }
}

/// An `AVPlayerLayer` with nothing else on it.
///
/// AVKit's `VideoPlayer` brings its own transport controls, which sit on top
/// of the picture — and therefore under the overlay — and fight the scrubber
/// this screen needs. A bare layer also pins the content mode to
/// `.resizeAspect`, which is the letterboxing `VideoOverlayGeometry` assumes.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
