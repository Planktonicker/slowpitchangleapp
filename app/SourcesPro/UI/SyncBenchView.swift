// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UIKit

/// The P1 gate, made testable: two phones, one clock, and two independent
/// measurements of how far apart they are.
///
/// The network says one thing (ping bursts, minimum-RTT filtered, fitted for
/// offset and skew). A clap says another (both phones hear one transient and
/// stamp it on their own host clock). If those two disagree by more than the
/// sound could explain, something is wrong — and that disagreement, not
/// either number alone, is the evidence.
///
/// Held as `@StateObject` here and passed down as `@ObservedObject`, per the
/// no-republish rule: these objects publish while a burst is running, and
/// routing that through `AppModel` would invalidate the whole app.
struct SyncBenchView: View {
    @StateObject private var link = LinkSession()
    @StateObject private var clap = ClapListener()
    @StateObject private var driver = ClockSyncDriver()
    @State private var role: LinkSession.Role = .master
    @State private var peerClapT: Double?
    @State private var myClapT: Double?
    @State private var exported: String?

    var body: some View {
        NavigationStack {
            List {
                roleSection
                peersSection
                if role == .master { clockSection }
                clapSection
                if let e = link.lastError {
                    Section { Text(e).foregroundStyle(.red).font(.footnote) }
                }
                helpSection
            }
            .navigationTitle("Sync bench")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear { link.stop(); clap.stop(); driver.stop() }
    }

    private var roleSection: some View {
        Section("Role") {
            Picker("Role", selection: $role) {
                ForEach(LinkSession.Role.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .disabled(link.isRunning)

            Button(link.isRunning ? "Stop" : "Start link") {
                if link.isRunning { link.stop(); clap.stop() } else { begin() }
            }
            Text("This phone is “\(link.myName)”. Start the link on both, pick a different role on each.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var peersSection: some View {
        Section("Peers") {
            if !link.connectedPeers.isEmpty {
                ForEach(link.connectedPeers, id: \.self) { p in
                    Label(p, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ForEach(link.discoveredPeers.filter { !link.connectedPeers.contains($0) }, id: \.self) { p in
                Button { link.invite(p) } label: {
                    Label("Connect to \(p)", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            if link.discoveredPeers.isEmpty && link.connectedPeers.isEmpty {
                Text(link.isRunning ? "Looking for the other phone…" : "Not started.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clockSection: some View {
        Section("Network clock") {
            Group {
                let d = driver
                Button(d.isBursting ? "Measuring…" : "Run a burst (\(ClockSyncDriver.burstSize) pings)") {
                    d.startBurst(over: link)
                }
                .disabled(link.connectedPeers.isEmpty || d.isBursting)

                if d.isBursting { ProgressView(value: d.progress) }

                if let m = d.model {
                    LabeledContent("Offset", value: String(format: "%+.2f ms", m.offsetS * 1000))
                    LabeledContent("Skew", value: String(format: "%+.1f ppm", m.skew * 1e6))
                    LabeledContent("Confidence", value: String(format: "±%.2f ms", m.ciS * 1000))
                    LabeledContent("Fastest round trip", value: String(format: "%.2f ms", m.rttMinS * 1000))
                    LabeledContent("Exchanges kept", value: "\(m.nUsed) of \(d.samples.count)")
                    HStack {
                        Circle().fill(m.isDegraded ? .red : (m.isWithinBudget ? .green : .yellow))
                            .frame(width: 10, height: 10)
                        Text(m.isWithinBudget
                             ? "Inside the 1 ms budget — 3D can be trusted on timing."
                             : (m.isDegraded
                                ? "Worse than 3 ms. 3D would be gated; 2D is unaffected."
                                : "Between 1 and 3 ms. Usable, but not comfortable."))
                        .font(.footnote)
                    }
                    Button("Export exchanges as CSV") { exported = d.csv(); saveCSV(d.csv()) }
                    if exported != nil {
                        Text("Written to Documents — pull it off with Files or Finder.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No measurement yet.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clapSection: some View {
        Section("Clap test — the independent witness") {
            Button(clap.isListening ? "Stop listening" : "Listen for a clap") {
                clap.isListening ? clap.stop() : clap.start()
            }
            if clap.isListening {
                LabeledContent("Level", value: String(format: "%.0f dB over floor", clap.currentDb))
            }
            if let mine = myClapT {
                LabeledContent("Heard here", value: String(format: "%.4f s", mine))
            }
            if let theirs = peerClapT {
                LabeledContent("Heard there", value: String(format: "%.4f s", theirs))
            }
            if let mine = myClapT, let theirs = peerClapT, let m = driver.model {
                // Map the peer's stamp onto this phone's clock, then compare.
                // Sound travel is NOT corrected — the two phones stand at
                // different distances from the clap, about 2.9 ms per metre
                // of path difference, and only the rig geometry knows that.
                let mapped = ClockSync3D.mapToMaster(theirs, m)
                let diffMs = (mapped - mine) * 1000
                LabeledContent("Disagreement", value: String(format: "%+.1f ms", diffMs))
                Text(abs(diffMs) <= 5
                     ? "Network and clap agree. That is the P1 gate passing."
                     : "They disagree by more than sound travel explains at these distances — check the link, or whether both phones heard the SAME clap.")
                    .font(.footnote)
                    .foregroundStyle(abs(diffMs) <= 5 ? .green : .orange)
            }
            if let e = clap.error {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            Text("Start the link and listen on both phones, then clap once, hard, midway between them.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var helpSection: some View {
        Section("What passes") {
            Text("""
                 Gate GP2: the network clock and the clap must agree to within \
                 a few milliseconds, and the burst's confidence should sit \
                 under 1 ms. Run it for ten minutes at field distances before \
                 believing it — the failure mode of a bad link is a plausible \
                 number, not an error.
                 """)
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func begin() {
        link.onMessage = { msg, _ in
            switch msg.kind {
            case .clockPing: driver.answerPing(msg, over: link)
            case .clockPong: driver.recordPong(msg)
            case .clapReport: peerClapT = msg.impulseT
            default: break
            }
        }
        clap.onImpulse = { t, db in
            myClapT = t
            // Workers report theirs upward; the master compares.
            if role == .worker {
                link.send(LinkMessage(kind: .clapReport, impulseT: t, impulseDb: db))
            }
        }
        link.start(role: role)
    }

    private func saveCSV(_ text: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("sync_bench.csv")
        try? text.data(using: .utf8)?.write(to: url)
    }
}
