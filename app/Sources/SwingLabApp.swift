// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

@main
struct SwingLabApp: App {
    @StateObject private var boot = Boot()

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
                RootView().environmentObject(model)
            }
        }
    }
}

/// Gets the app to its first usable screen without blocking on the way.
///
/// The store used to be opened inside `App.init`, which runs before the first
/// frame — so the whole of it, container open included, happened behind a blank
/// window. Nothing was wrong; there was simply nothing to look at while it
/// worked, and a blank window that does not respond is indistinguishable from a
/// crashed one.
///
/// Now the loading screen draws first and the container opens off the main
/// actor behind it. Only the cheap half — making the context and reading the
/// records — comes back to the main actor, where SwiftData's `ModelContext`
/// has to live.
@MainActor
final class Boot: ObservableObject {

    enum Phase {
        case loading
        case ready(AppModel)
    }

    @Published private(set) var phase: Phase = .loading

    private var started = false

    func start() async {
        // `.task` can fire more than once for one view; opening the store twice
        // would leave two contexts writing to one file.
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
            store = InMemorySwingStore()
            failure = "Saved-swing database could not be opened, so this session is memory-only: \(error.localizedDescription)"
        }

        let model = AppModel(store: store)
        if let failure {
            model.banner = AppModel.Banner(kind: .error, text: failure)
        }
        phase = .ready(model)
    }
}

/// Fallback store. Also what the unit tests use.
final class InMemorySwingStore: SwingStoring {
    private var storage: [UUID: SwingDTO] = [:]

    func all() throws -> [SwingDTO] {
        storage.values.sorted { $0.capturedAt > $1.capturedAt }
    }

    func save(_ swing: SwingDTO) throws { storage[swing.id] = swing }
    func delete(id: UUID) throws { storage[id] = nil }
    func deleteAll() throws { storage.removeAll() }
}
