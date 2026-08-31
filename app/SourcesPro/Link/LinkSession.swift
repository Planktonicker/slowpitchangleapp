// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation
import MultipeerConnectivity
import QuartzCore
import UIKit

/// Pairs two phones over MultipeerConnectivity and carries `LinkMessage`s.
///
/// Peer-to-peer on purpose: a ball field has no Wi-Fi, and the whole Pro
/// design assumes nothing leaves the two phones. This is the app's first and
/// only networking code — the shipping SwingLab target has none, and this
/// file compiles only into SwingLabPro.
///
/// Publishing is coalesced and change-gated because of the rule in
/// `AppModel`: republishing live state at wire rate invalidates every view in
/// the app many times a second. Views hold this as `@ObservedObject`.
@MainActor
final class LinkSession: NSObject, ObservableObject {

    /// 12 characters, lowercase and hyphen — inside MultipeerConnectivity's
    /// 15-character limit and its allowed character set.
    static let serviceType = "swinglab-pro"

    enum Role: String, CaseIterable, Identifiable, Sendable {
        case master, worker
        var id: String { rawValue }
        var label: String { self == .master ? "This phone leads" : "This phone follows" }
    }

    @Published private(set) var role: Role = .master
    @Published private(set) var isRunning = false
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var discoveredPeers: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var messagesReceived = 0

    /// Set by the owner to observe traffic. Called on the main actor.
    var onMessage: ((LinkMessage, MCPeerID) -> Void)?

    private let peerID = MCPeerID(displayName: String(UIDevice.current.name.prefix(30)))
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peersByName: [String: MCPeerID] = [:]

    var myName: String { peerID.displayName }

    /// The host clock, in seconds. The same timebase
    /// `CMClockGetHostTimeClock()` runs on, which is what capture
    /// presentation timestamps convert into — so a time measured here and a
    /// frame timestamp mean the same thing.
    static func hostNow() -> Double { CACurrentMediaTime() }

    func start(role: Role) {
        stop()
        self.role = role
        lastError = nil

        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        // Both sides advertise AND browse. Which phone is "master" is a
        // role for the protocol, not for discovery, and making discovery
        // symmetric means it does not matter who opens the screen first.
        let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["role": role.rawValue],
                                          serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a

        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b

        isRunning = true
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil
        peersByName.removeAll()
        if isRunning { isRunning = false }
        if !connectedPeers.isEmpty { connectedPeers = [] }
        if !discoveredPeers.isEmpty { discoveredPeers = [] }
    }

    func invite(_ name: String) {
        guard let peer = peersByName[name], let session else { return }
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    /// `reliable` for control and payloads; `unreliable` for clock pings,
    /// where a retransmitted packet is worse than a lost one — it arrives
    /// late and pollutes the round-trip estimate.
    func send(_ message: LinkMessage, reliable: Bool = true) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(try message.encoded(), toPeers: session.connectedPeers,
                             with: reliable ? .reliable : .unreliable)
        } catch {
            lastError = error.localizedDescription
        }
    }

    fileprivate func handle(_ data: Data, from peer: MCPeerID) {
        guard let msg = LinkMessage.decode(data) else { return }
        guard msg.proto == LinkMessage.protocolMajor else {
            lastError = "Peer speaks protocol \(msg.proto); this build speaks \(LinkMessage.protocolMajor). Update both phones."
            return
        }
        messagesReceived += 1
        onMessage?(msg, peer)
    }
}

extension LinkSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers.map(\.displayName)
            if state == .connected, self.role == .master {
                self.send(LinkMessage(kind: .hello,
                                      deviceName: self.peerID.displayName,
                                      deviceModel: UIDevice.current.model,
                                      systemVersion: UIDevice.current.systemVersion,
                                      supports240: true))
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handle(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LinkSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, self.session) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.lastError = "Could not advertise: \(error.localizedDescription)" }
    }
}

extension LinkSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            self.peersByName[peerID.displayName] = peerID
            if !self.discoveredPeers.contains(peerID.displayName) {
                self.discoveredPeers.append(peerID.displayName)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.peersByName[peerID.displayName] = nil
            self.discoveredPeers.removeAll { $0 == peerID.displayName }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.lastError = "Could not browse: \(error.localizedDescription)" }
    }
}
