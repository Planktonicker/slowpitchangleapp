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

    var hangS: Double?
    var carryFt: Double?

    var cameraDistanceFt: Double?
    var lensHeightFt: Double?
    var cameraRollDeg: Double?

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
        hangS = dto.hangS
        carryFt = dto.carryFt
        cameraDistanceFt = dto.cameraDistanceFt
        lensHeightFt = dto.lensHeightFt
        cameraRollDeg = dto.cameraRollDeg
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
        hangS = dto.hangS
        carryFt = dto.carryFt
        cameraDistanceFt = dto.cameraDistanceFt
        lensHeightFt = dto.lensHeightFt
        cameraRollDeg = dto.cameraRollDeg
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
        d.hangS = hangS
        d.carryFt = carryFt
        d.cameraDistanceFt = cameraDistanceFt
        d.lensHeightFt = lensHeightFt
        d.cameraRollDeg = cameraRollDeg
        d.notes = notes
        return d
    }
}

/// SwiftData-backed implementation of `SwingStoring`.
final class SwiftDataSwingStore: SwingStoring {

    let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: SwingEntity.self, configurations: config)
        context = ModelContext(container)
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
