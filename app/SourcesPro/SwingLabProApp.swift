// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

// SwingLab Pro: the multi-phone 3D capture variant. Same tree, second target
// (see docs/SWINGLAB_PRO.md) — everything in Sources/ compiles into this app
// too, so Pro's Solo mode IS the shipping SwingLab, run under the Pro bundle
// id. That is deliberate: it exercises the shared code daily, and a Pro phone
// whose partner phone died is still a complete SwingLab.
@main
struct SwingLabProApp: App {
    @StateObject private var boot = ProBoot()

    init() {
        Theme.installAppearance()
    }

    var body: some Scene {
        WindowGroup {
            switch boot.phase {
            case .loading:
                LoadingView(title: "Opening your swings",
                            detail: "Reading the stored measurements.")
                    .task { await boot.start() }
            case .ready(let model):
                ProRootView(model: model)
            }
        }
    }
}

/// A copy of `Boot`, not a use of it: `Boot` lives in SwingLabApp.swift,
/// which is excluded from this target because a target can hold only one
/// `@main`. The copy is temporary by design — the linked-capture phase (P4 in
/// docs/SWINGLAB_PRO.md) starts by moving Boot and the in-memory store into
/// Sources/ proper and deleting this. Until then, any fix to Boot belongs in
/// both places, which is exactly why the copy's lifetime is written down.
///
/// The Pro bundle id gives this app its own sandbox and therefore its own
/// SwiftData container: Pro and SwingLab on one phone keep separate histories
/// and cannot corrupt each other.
@MainActor
final class ProBoot: ObservableObject {

    enum Phase {
        case loading
        case ready(AppModel)
    }

    @Published private(set) var phase: Phase = .loading

    private var started = false

    func start() async {
        // `.task` can fire more than once for one view; opening the store
        // twice would leave two contexts writing to one file.
        guard !started else { return }
        started = true

        var failure: String?
        let store: SwingStoring
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try SwiftDataSwingStore.openContainerRecreatingIfNeeded()
            }.value
            store = SwiftDataSwingStore(container: opened.container)
            if opened.wasReset {
                failure = "Stored swings were cleared: the database predates the switch to metric units and could not be migrated. Saving works normally from here."
            }
        } catch {
            // A storage failure must not brick the app in a car park an hour
            // from home: fall back to memory, and the UI says so.
            store = ProMemoryStore()
            failure = "Saved-swing database could not be opened, so this session is memory-only: \(error.localizedDescription)"
        }

        let model = AppModel(store: store)
        if let failure {
            model.banner = AppModel.Banner(kind: .error, text: failure)
        }
        phase = .ready(model)
    }
}

/// Fallback store — same temporary-copy story as `ProBoot` above
/// (`InMemorySwingStore` is defined in the excluded SwingLabApp.swift).
final class ProMemoryStore: SwingStoring {
    private var storage: [UUID: SwingDTO] = [:]

    func all() throws -> [SwingDTO] {
        storage.values.sorted { $0.capturedAt > $1.capturedAt }
    }

    func save(_ swing: SwingDTO) throws { storage[swing.id] = swing }
    func delete(id: UUID) throws { storage[id] = nil }
    func deleteAll() throws { storage.removeAll() }
}
