// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Runs ping bursts over the link and keeps the fitted clock model.
///
/// The master sends pings; the worker answers each one immediately with its
/// own two timestamps. The master stamps arrival and fits. `Core3D`'s
/// `ClockSync3D.fit` does the actual maths — this class only decides when to
/// ping and holds the answer, so the parity-pinned part stays pure.
@MainActor
final class ClockSyncDriver: ObservableObject {

    /// Enough exchanges that the minimum-RTT filter has a real minimum to
    /// find, few enough that a burst is over in a couple of seconds.
    static let burstSize = 150
    /// Faster than this and the radio queues them, which inflates exactly
    /// the round trips being measured.
    static let pingIntervalS = 0.012

    @Published private(set) var model: ClockModel?
    @Published private(set) var samples: [ClockSample] = []
    @Published private(set) var isBursting = false
    @Published private(set) var progress = 0.0
    /// Kept for the HUD: how much of the burst the RTT filter threw away.
    @Published private(set) var lastKeptFraction = 0.0

    private var pending: [UInt64: Double] = [:]
    private var seq: UInt64 = 0
    private var burstTask: Task<Void, Never>?

    // The link is passed in per call rather than stored. Storing it forced
    // this object to be constructed with an argument, which meant the view
    // could only keep it in @State — and @State does not observe an
    // ObservableObject, so the bench would have sat frozen while the numbers
    // changed underneath it. Passing it in keeps this a @StateObject.

    var summary: String {
        guard let m = model else { return "not measured" }
        return String(format: "offset %+.2f ms · skew %+.1f ppm · ±%.2f ms · %d/%d kept",
                      m.offsetS * 1000, m.skew * 1e6, m.ciS * 1000, m.nUsed, samples.count)
    }

    func startBurst(over link: LinkSession) {
        guard !isBursting else { return }
        burstTask?.cancel()
        samples = []
        pending = [:]
        progress = 0
        isBursting = true
        burstTask = Task { @MainActor in
            for i in 0..<Self.burstSize {
                if Task.isCancelled { break }
                seq &+= 1
                let t1 = LinkSession.hostNow()
                pending[seq] = t1
                link.send(LinkMessage(kind: .clockPing, seq: seq, t1: t1), reliable: false)
                progress = Double(i + 1) / Double(Self.burstSize)
                try? await Task.sleep(nanoseconds: UInt64(Self.pingIntervalS * 1_000_000_000))
            }
            // Let the last few answers land before fitting.
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.refit()
            self.isBursting = false
        }
    }

    func stop() {
        burstTask?.cancel()
        burstTask = nil
        isBursting = false
    }

    /// The worker's side: answer immediately, stamping receive and reply.
    /// Any delay here inflates the master's round trip, so nothing else
    /// happens between the two stamps.
    func answerPing(_ msg: LinkMessage, over link: LinkSession) {
        let t2 = LinkSession.hostNow()
        guard let t1 = msg.t1 else { return }
        let t3 = LinkSession.hostNow()
        link.send(LinkMessage(kind: .clockPong, seq: msg.seq, t1: t1, t2: t2, t3: t3),
                  reliable: false)
    }

    /// The master's side: stamp arrival and record the exchange.
    func recordPong(_ msg: LinkMessage) {
        let t4 = LinkSession.hostNow()
        guard let t1 = msg.t1 ?? pending[msg.seq], let t2 = msg.t2, let t3 = msg.t3 else { return }
        pending[msg.seq] = nil
        samples.append(ClockSample(t1: t1, t2: t2, t3: t3, t4: t4))
        // Refit as it goes so the screen shows the estimate converging —
        // cheap at this sample count, and it makes a bad link obvious
        // immediately rather than after the burst.
        if samples.count % 10 == 0 { refit() }
    }

    func refit() {
        guard let m = ClockSync3D.fit(samples) else { return }
        model = m
        lastKeptFraction = samples.isEmpty ? 0 : Double(m.nUsed) / Double(samples.count)
    }

    /// Comma-separated exchanges, for pulling off with Files and analysing
    /// on the Mac. The bench is only worth running if its evidence leaves
    /// the phone.
    func csv() -> String {
        var out = "t1,t2,t3,t4,rtt_s,offset_s\n"
        for s in samples {
            out += String(format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f\n",
                          s.t1, s.t2, s.t3, s.t4, s.rtt, s.offset)
        }
        return out
    }
}
