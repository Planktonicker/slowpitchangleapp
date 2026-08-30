// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation
import SwiftData

/// SwiftData row for a swing.
///
/// Deliberately flat and primitive-typed: enums and arrays are stored as
/// strings so a schema migration never hinges on a Swift type that changed
/// shape. `SwingDTO` is the type the rest of the app sees.
@Model
final class SwingEntity {
    @Attribute(.unique) var id: UUID
    var capturedAt: Date
    var settingRaw: String

    var clipFilename: String?
    var trackCSVFilename: String?

    var fps: Double
    var contactTime: Double
    var launchAngleDeg: Double
    var exitVeloMph: Double
    var exitVeloMps: Double
    var scaleBallMPerPx: Double
    var scaleGravityMPerPx: Double?
    var scaleDisagreement: Double?
    var diameterDrift: Double
    var trackedFrames: Int
    var trackDurationS: Double
    var fitRmsPx: Double
    /// Pipe-separated flag raw values, the same encoding the CSV export uses.
    var flagsRaw: String
    var usedVisionHint: Bool
    var autoTriggered: Bool

    var batAttackAngleDeg: Double?
    var batFrames: Int?
    var batSpeedMph: Double?
    var smashFactor: Double?
    var undercutMm: Double?

    var hangS: Double?
    var carryM: Double?

    var cameraDistanceM: Double?
    var lensHeightM: Double?
    var cameraRollDeg: Double?
    var cameraTiltDeg: Double?
    var cameraFovDeg: Double?
    var poseFilename: String?
    var traceFilename: String?
    var ballSeedT: Double?
    var ballSeedX: Double?
    var ballSeedY: Double?
    var visionOrientationRaw: Int = 1
    /// `BodyMetrics` as JSON. A blob rather than five nullable columns: they
    /// are one measurement that is meaningful together, and the set will grow
    /// as more sagittal metrics are added — each of which would otherwise be a
    /// schema migration.
    var bodyJSON: String?
    /// Pipe-separated `CaptureFlag` raw values, same encoding as `flagsRaw`.
    var captureFlagsRaw: String = ""
    /// The barrel-tape path as JSON, same reasoning as `bodyJSON`: it is a
    /// variable-length list that nothing queries, so one column beats a
    /// relationship and a migration.
    var batPathJSON: String?
    var diagnosticsFilename: String?

    /// The round this swing was taken in. Optional so every already-stored
    /// swing keeps loading — SwiftData gives a new optional column nil rather
    /// than refusing the store, and a swing with no round is exactly what a
    /// pre-sessions swing is.
    var sessionID: UUID?

    var notes: String?

    init(dto: SwingDTO) {
        id = dto.id
        capturedAt = dto.capturedAt
        settingRaw = dto.setting.rawValue
        clipFilename = dto.clipFilename
        trackCSVFilename = dto.trackCSVFilename
        fps = dto.fps
        contactTime = dto.contactTime
        launchAngleDeg = dto.launchAngleDeg
        exitVeloMph = dto.exitVeloMph
        exitVeloMps = dto.exitVeloMps
        scaleBallMPerPx = dto.scaleBallMPerPx
        scaleGravityMPerPx = dto.scaleGravityMPerPx
        scaleDisagreement = dto.scaleDisagreement
        diameterDrift = dto.diameterDrift
        trackedFrames = dto.trackedFrames
        trackDurationS = dto.trackDurationS
        fitRmsPx = dto.fitRmsPx
        flagsRaw = dto.flags.map(\.rawValue).joined(separator: "|")
        usedVisionHint = dto.usedVisionHint
        autoTriggered = dto.autoTriggered
        batAttackAngleDeg = dto.batAttackAngleDeg
        batFrames = dto.batFrames
        batSpeedMph = dto.batSpeedMph
        smashFactor = dto.smashFactor
        undercutMm = dto.undercutMm
        hangS = dto.hangS
        carryM = dto.carryM
        cameraDistanceM = dto.cameraDistanceM
        lensHeightM = dto.lensHeightM
        cameraRollDeg = dto.cameraRollDeg
        cameraTiltDeg = dto.cameraTiltDeg
        cameraFovDeg = dto.cameraFovDeg
        poseFilename = dto.poseFilename
        traceFilename = dto.traceFilename
        ballSeedT = dto.ballSeedT
        ballSeedX = dto.ballSeedX
        ballSeedY = dto.ballSeedY
        visionOrientationRaw = dto.visionOrientationRaw
        bodyJSON = Self.encodeBody(dto.body)
        captureFlagsRaw = dto.captureFlags.map(\.rawValue).joined(separator: "|")
        batPathJSON = Self.encodePath(dto.batPathPx)
        diagnosticsFilename = dto.diagnosticsFilename
        sessionID = dto.sessionID
        notes = dto.notes
    }

    func apply(_ dto: SwingDTO) {
        capturedAt = dto.capturedAt
        settingRaw = dto.setting.rawValue
        clipFilename = dto.clipFilename
        trackCSVFilename = dto.trackCSVFilename
        fps = dto.fps
        contactTime = dto.contactTime
        launchAngleDeg = dto.launchAngleDeg
        exitVeloMph = dto.exitVeloMph
        exitVeloMps = dto.exitVeloMps
        scaleBallMPerPx = dto.scaleBallMPerPx
        scaleGravityMPerPx = dto.scaleGravityMPerPx
        scaleDisagreement = dto.scaleDisagreement
        diameterDrift = dto.diameterDrift
        trackedFrames = dto.trackedFrames
        trackDurationS = dto.trackDurationS
        fitRmsPx = dto.fitRmsPx
        flagsRaw = dto.flags.map(\.rawValue).joined(separator: "|")
        usedVisionHint = dto.usedVisionHint
        autoTriggered = dto.autoTriggered
        batAttackAngleDeg = dto.batAttackAngleDeg
        batFrames = dto.batFrames
        batSpeedMph = dto.batSpeedMph
        smashFactor = dto.smashFactor
        undercutMm = dto.undercutMm
        hangS = dto.hangS
        carryM = dto.carryM
        cameraDistanceM = dto.cameraDistanceM
        lensHeightM = dto.lensHeightM
        cameraRollDeg = dto.cameraRollDeg
        cameraTiltDeg = dto.cameraTiltDeg
        cameraFovDeg = dto.cameraFovDeg
        poseFilename = dto.poseFilename
        traceFilename = dto.traceFilename
        ballSeedT = dto.ballSeedT
        ballSeedX = dto.ballSeedX
        ballSeedY = dto.ballSeedY
        visionOrientationRaw = dto.visionOrientationRaw
        bodyJSON = Self.encodeBody(dto.body)
        captureFlagsRaw = dto.captureFlags.map(\.rawValue).joined(separator: "|")
        batPathJSON = Self.encodePath(dto.batPathPx)
        diagnosticsFilename = dto.diagnosticsFilename
        sessionID = dto.sessionID
        notes = dto.notes
    }

    var dto: SwingDTO {
        var d = SwingDTO()
        d.id = id
        d.capturedAt = capturedAt
        d.setting = SwingSetting(rawValue: settingRaw) ?? .tee
        d.clipFilename = clipFilename
        d.trackCSVFilename = trackCSVFilename
        d.fps = fps
        d.contactTime = contactTime
        d.launchAngleDeg = launchAngleDeg
        d.exitVeloMph = exitVeloMph
        d.exitVeloMps = exitVeloMps
        d.scaleBallMPerPx = scaleBallMPerPx
        d.scaleGravityMPerPx = scaleGravityMPerPx
        d.scaleDisagreement = scaleDisagreement
        d.diameterDrift = diameterDrift
        d.trackedFrames = trackedFrames
        d.trackDurationS = trackDurationS
        d.fitRmsPx = fitRmsPx
        d.flags = flagsRaw.split(separator: "|").compactMap { SwingFlag(rawValue: String($0)) }
        d.usedVisionHint = usedVisionHint
        d.autoTriggered = autoTriggered
        d.batAttackAngleDeg = batAttackAngleDeg
        d.batFrames = batFrames
        d.batSpeedMph = batSpeedMph
        d.smashFactor = smashFactor
        d.undercutMm = undercutMm
        d.hangS = hangS
        d.carryM = carryM
        d.cameraDistanceM = cameraDistanceM
        d.lensHeightM = lensHeightM
        d.cameraRollDeg = cameraRollDeg
        d.cameraTiltDeg = cameraTiltDeg
        d.cameraFovDeg = cameraFovDeg
        d.poseFilename = poseFilename
        d.traceFilename = traceFilename
        d.ballSeedT = ballSeedT
        d.ballSeedX = ballSeedX
        d.ballSeedY = ballSeedY
        d.visionOrientationRaw = visionOrientationRaw
        d.body = Self.decodeBody(bodyJSON)
        d.captureFlags = captureFlagsRaw.split(separator: "|")
            .compactMap { CaptureFlag(rawValue: String($0)) }
        d.batPathPx = Self.decodePath(batPathJSON)
        d.diagnosticsFilename = diagnosticsFilename
        d.sessionID = sessionID
        d.notes = notes
        return d
    }

    /// `BodyMetrics` <-> JSON. Failure is silent and lossy on purpose: a body
    /// measurement is supplementary, and a swing whose exit velocity is intact
    /// must not fail to load because a body blob could not be read.
    static func encodeBody(_ body: BodyMetrics?) -> String? {
        guard let body, let data = try? JSONEncoder().encode(body) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeBody(_ json: String?) -> BodyMetrics? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BodyMetrics.self, from: data)
    }

    static func encodePath(_ path: [CGPoint]) -> String? {
        guard !path.isEmpty, let data = try? JSONEncoder().encode(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodePath(_ json: String?) -> [CGPoint] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CGPoint].self, from: data)) ?? []
    }
}

/// SwiftData-backed implementation of `SwingStoring`.
final class SwiftDataSwingStore: SwingStoring {

    let container: ModelContainer
    private let context: ModelContext

    /// Where the store lives. Explicit rather than SwiftData's default so a
    /// store that cannot be opened can be removed and rebuilt.
    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("SwingLab.store")
    }

    init(inMemory: Bool = false) throws {
        try self.init(container: Self.makeContainer(inMemory: inMemory))
    }

    /// Take an already-opened container. The split exists so the expensive
    /// half — opening the container, which checks the schema and the store
    /// file — can happen off the main actor while a loading screen is up, and
    /// only the cheap half, making a context, has to come back to it.
    init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    /// `nonisolated` on purpose: this is the part that runs off the main actor.
    nonisolated static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: Self.storeURL)
        return try ModelContainer(for: SwingEntity.self, configurations: config)
    }

    /// A container plus whether the old store had to be thrown away.
    ///
    /// `@unchecked Sendable` rather than trusting `ModelContainer`'s own
    /// conformance across SwiftData versions: this crosses an actor boundary
    /// exactly once, from the task that opened it to the main actor that will
    /// own it from then on, and nothing else ever touches it concurrently.
    struct OpenedContainer: @unchecked Sendable {
        let container: ModelContainer
        let wasReset: Bool
    }

    /// Open the container off the main actor, rebuilding it if the file on disk
    /// cannot be migrated.
    ///
    /// Field units changed from feet/inches to metres/millimetres, which
    /// renames stored properties — a schema change SwiftData cannot always
    /// migrate in place. Losing a handful of pre-release test swings is a far
    /// better outcome than an app that refuses to open, or one that silently
    /// drops to memory-only and quietly stops saving anything.
    nonisolated static func openContainerRecreatingIfNeeded() throws -> OpenedContainer {
        do {
            return OpenedContainer(container: try makeContainer(), wasReset: false)
        } catch {
            let fm = FileManager.default
            for suffix in ["", "-shm", "-wal"] {
                try? fm.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            return OpenedContainer(container: try makeContainer(), wasReset: true)
        }
    }

    /// Open the store, rebuilding it if the existing file cannot be migrated.
    /// The blocking form. `Boot` uses the two-part version so the container
    /// opens off the main actor behind a loading screen; this stays for tests
    /// and for anywhere a wait is not worth a screen.
    static func openRecreatingIfNeeded() throws -> (store: SwiftDataSwingStore, wasReset: Bool) {
        let opened = try openContainerRecreatingIfNeeded()
        return (SwiftDataSwingStore(container: opened.container), opened.wasReset)
    }

    func all() throws -> [SwingDTO] {
        let descriptor = FetchDescriptor<SwingEntity>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.dto)
    }

    func save(_ swing: SwingDTO) throws {
        let target = swing.id
        var descriptor = FetchDescriptor<SwingEntity>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.apply(swing)
        } else {
            context.insert(SwingEntity(dto: swing))
        }
        try context.save()
    }

    func delete(id: UUID) throws {
        var descriptor = FetchDescriptor<SwingEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    func deleteAll() throws {
        for entity in try context.fetch(FetchDescriptor<SwingEntity>()) {
            context.delete(entity)
        }
        try context.save()
    }
}
