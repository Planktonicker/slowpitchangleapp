// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import Foundation
import QuartzCore

/// Hears a sharp transient and stamps it on the host clock.
///
/// This is the bench instrument for the sync test, not the production
/// trigger. It mirrors `ContactTrigger`'s measurement exactly — 5 ms RMS
/// windows against a rolling median floor, fired at a dB margin over it —
/// but takes audio from `AVAudioEngine` rather than from a capture session,
/// so the sync bench needs no camera and cannot fight the one preview layer
/// or the hardware decoder.
///
/// Its output is a host-clock instant, which is the same timebase the link's
/// clock model works in. That is the whole point: the network's answer for
/// "how far apart are these two clocks" and the clap's answer must agree.
@MainActor
final class ClapListener: ObservableObject {

    @Published private(set) var isListening = false
    @Published private(set) var lastImpulseT: Double?
    @Published private(set) var lastImpulseDb: Double?
    @Published private(set) var currentDb: Double = 0
    @Published private(set) var error: String?

    /// Fired on the main actor with (host time, dB over floor).
    var onImpulse: ((Double, Double) -> Void)?

    private let engine = AVAudioEngine()
    private var carry: [Float] = []
    private var floorHistory: [Double] = []
    private var lastFireT: Double = -.infinity
    private var installed = false

    // Mirrored from ContactTrigger, which holds them privately. Duplicated
    // rather than shared because this is a BENCH instrument on a different
    // input path, and quietly making the production trigger's constants
    // public so a test screen can borrow them would be the worse trade. If
    // ContactTrigger's window ever changes, this must follow — that is the
    // cost, and it is written down here so it is not a surprise.
    private let rmsWindowS = 0.005      // 5 ms, as ContactTrigger
    private let floorWindowS = 0.5      // rolling median span

    func start() {
        guard !isListening else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                error = "No audio input available."
                return
            }
            if !installed {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
                    self?.process(buf, when: when, sampleRate: format.sampleRate)
                }
                installed = true
            }
            engine.prepare()
            try engine.start()
            isListening = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        isListening = false
    }

    private nonisolated func process(_ buffer: AVAudioPCMBuffer, when: AVAudioTime,
                                     sampleRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = channel[i] }
        // The tap's timestamp is in host ticks; convert to the same seconds
        // scale CACurrentMediaTime() reports so the stamp is comparable with
        // the clock model.
        let hostStart = AVAudioTime.seconds(forHostTime: when.hostTime)
        Task { @MainActor in
            self.ingest(samples, hostStart: hostStart, sampleRate: sampleRate)
        }
    }

    private func ingest(_ new: [Float], hostStart: Double, sampleRate: Double) {
        carry.append(contentsOf: new)
        let window = max(1, Int(rmsWindowS * sampleRate))
        let maxFloor = max(8, Int(floorWindowS / rmsWindowS))
        var consumed = 0

        while carry.count - consumed >= window {
            var sum = 0.0
            for i in 0..<window {
                let v = Double(carry[consumed + i])
                sum += v * v
            }
            let rms = (sum / Double(window)).squareRoot()
            let floor = floorHistory.isEmpty ? max(rms, 1e-9) : ClockSync3D.median(floorHistory)
            let db = 20 * log10(max(rms, 1e-12) / max(floor, 1e-12))
            currentDb = db

            // The window's CENTRE, matching ContactTrigger: the impulse is
            // reported at the middle of the window that heard it, not its
            // leading edge.
            let windowT = hostStart + Double(consumed) / sampleRate + rmsWindowS / 2
            if db >= SLA.triggerDb, windowT - lastFireT > 1.0 {
                lastFireT = windowT
                lastImpulseT = windowT
                lastImpulseDb = db
                onImpulse?(windowT, db)
            }

            floorHistory.append(rms)
            if floorHistory.count > maxFloor { floorHistory.removeFirst() }
            consumed += window
        }
        if consumed > 0 { carry.removeFirst(consumed) }
        if carry.count > Int(sampleRate) { carry.removeFirst(carry.count - Int(sampleRate)) }
    }
}
