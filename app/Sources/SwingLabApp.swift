// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI

@main
struct SwingLabApp: App {
    @StateObject private var model: AppModel

    init() {
        Theme.installAppearance()
        // A storage failure must not brick the app in a car park an hour from
        // home: fall back to memory, and the UI says so.
        let store: SwingStoring
        var failure: String?
        do {
            store = try SwiftDataSwingStore()
        } catch {
            store = InMemorySwingStore()
            failure = "Saved-swing database could not be opened, so this session is memory-only: \(error.localizedDescription)"
        }
        let model = AppModel(store: store)
        if let failure {
            model.banner = AppModel.Banner(kind: .error, text: failure)
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
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
