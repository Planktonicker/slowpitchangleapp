// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// The wire protocol between a master phone and its worker.
///
/// JSON rather than a packed binary format, deliberately: the control plane
/// is low rate, and a field log you can read is worth more than the bytes it
/// costs. The bulk payloads (tracks, pose) are separate and are the only
/// thing sent in volume — video is never sent at all, which is what makes a
/// no-signal ball field workable.
enum LinkKind: String, Codable, Sendable {
    case hello          // identity + capabilities, both directions
    case clockPing      // master -> worker, carries t1
    case clockPong      // worker -> master, carries t1, t2, t3
    case clockModel     // master -> worker, the fitted result (for its HUD)
    case clapReport     // worker -> master, a heard impulse on the worker clock
    case bye
}

/// A single control message. Optional fields rather than an enum with
/// associated values so an older build can decode a newer message's common
/// half instead of failing outright.
struct LinkMessage: Codable, Sendable {
    /// Bumped only for incompatible changes; a mismatch refuses the peer
    /// rather than half-working.
    static let protocolMajor = 1

    var proto: Int = LinkMessage.protocolMajor
    var kind: LinkKind
    var seq: UInt64 = 0

    // Clock exchange. t4 is never sent — the master stamps it on arrival.
    var t1: Double?
    var t2: Double?
    var t3: Double?

    // hello
    var deviceName: String?
    var deviceModel: String?
    var systemVersion: String?
    var supports240: Bool?

    // clockModel
    var offsetS: Double?
    var skew: Double?
    var ciS: Double?

    // clapReport
    var impulseT: Double?
    var impulseDb: Double?

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> LinkMessage? {
        try? JSONDecoder().decode(LinkMessage.self, from: data)
    }
}
