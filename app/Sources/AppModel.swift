// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Combine
import Foundation
import SwiftUI

/// Ties capture, analysis and storage together.
@MainActor
final class AppModel: ObservableObject {

    let capture = CaptureController()
    let wizard = PlacementWizard()
    let store: SwingStoring

    @Published private(set) var swings: [SwingDTO] = []
    @Published var currentSetting: SwingSetting = .tee
    @Published private(set) var analysisProgress: Double?
    @Published private(set) var lastSwing: SwingDTO?
    @Published var banner: Banner?
    @Published var settings = AppSettings.load() {
        didSet { settings.save() }
    }

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        var id = UUID()
        var kind: Kind
        var text: String
    }

    var scoreboard: ValidationScoreboard { ValidationScoreboard.build(from: swings) }

    var isAnalyzing: Bool { analysisProgress != nil }

    init(store: SwingStoring) {
        self.store = store
        capture.onClip = { [weak self] output in
            self?.handleClip(output, autoTriggered: true)
        }
        capture.onError = { [weak self] message in
            self?.banner = Banner(kind: .error, text: message)
        }
        reload()
    }

    // MARK: - Session

    private var cancellables = Set<AnyCancellable>()

    func startCapture() {
        capture.configureAndStart()
        // Field of view and frame width are only known once the capture
        // format has been chosen, and the plate scale check needs both.
        capture.$fieldOfViewDeg
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fov in self?.wizard.fieldOfViewDeg = fov }
            .store(in: &cancellables)
        capture.$activeFormatDescription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] description in
                // "1920x1080 @ 240fps" -> 1920
                if let width = description.split(separator: "x").first.flatMap({ Double($0) }) {
                    self?.wizard.imageWidthPx = width
                }
            }
            .store(in: &cancellables)
    }

    func stopCapture() {
        capture.isArmed = false
        capture.stop()
    }

    func arm() {
        guard wizard.isArmingAllowed else {
            banner = Banner(kind: .warning,
                            text: wizard.blockingReason ?? "Finish the placement wizard first.")
            return
        }
        capture.isArmed = true
    }

    func disarm() { capture.isArmed = false }

    /// Manual capture — the escape hatch when the audio trigger cannot hear
    /// contact. Recorded as such so gate G5 stays honest.
    func triggerManually() {
        capture.triggerManually()
        pendingManual = true
    }

    private var pendingManual = false

    // MARK: - Clip handling

    func handleClip(_ output: ClipRecorder.Output, autoTriggered: Bool) {
        let wasManual = pendingManual
        pendingManual = false
        let setting = currentSetting
        let placement = wizard.placement
        var options = settings.analyzerOptions
        options.rollDeg = placement.rollDeg

        analysisProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var analysis: ClipAnalysis?
            var failure: String?
            do {
                analysis = try await ClipAnalyzer.analyze(
                    url: output.url,
                    contactTime: output.contactOffset,
                    options: options,
                    progress: { p in
                        Task { @MainActor [weak self] in self?.analysisProgress = p }
                    }
                )
            } catch {
                failure = error.localizedDescription
            }
            let finalAnalysis = analysis
            let finalFailure = failure
            await MainActor.run {
                self.finishClip(output: output,
                                setting: setting,
                                placement: placement,
                                analysis: finalAnalysis,
                                failure: finalFailure,
                                autoTriggered: autoTriggered && !wasManual)
            }
        }
    }

    private func finishClip(output: ClipRecorder.Output,
                            setting: SwingSetting,
                            placement: PlacementWizard.Placement,
                            analysis: ClipAnalysis?,
                            failure: String?,
                            autoTriggered: Bool) {
        analysisProgress = nil

        let clipName = settings.keepClips
            ? ClipStore.fileUnderConvention(clip: output.url, setting: setting)
            : nil
        if !settings.keepClips { try? FileManager.default.removeItem(at: output.url) }

        var dto: SwingDTO
        if let analysis {
            dto = SwingDTO(analysis: analysis, setting: setting,
                           clipFilename: clipName, autoTriggered: autoTriggered)
            // Write the track in the exact format `analyze_swing.py` reads, so
            // any suspicious reading can be re-run on the Mac.
            if let clipName {
                let trackName = (clipName as NSString).deletingPathExtension + ".csv"
                let csv = TrackCSV.serialize(
                    track: analysis.track,
                    fps: analysis.fps,
                    meta: [("clip", clipName),
                           ("contact_time", String(format: "%.6f", analysis.contactTime)),
                           ("setting", setting.rawValue),
                           ("source", "SwingLab on-device")]
                )
                if let data = csv.data(using: .utf8) {
                    try? data.write(to: ClipStore.trackURL(named: trackName), options: .atomic)
                    dto.trackCSVFilename = trackName
                }
            }
        } else {
            // A clip where tracking failed still counts — it is a G1 miss, and
            // dropping it would flatter the trackability number.
            dto = SwingDTO()
            dto.setting = setting
            dto.clipFilename = clipName
            dto.trackedFrames = 0
            dto.autoTriggered = autoTriggered
            dto.notes = failure
        }

        dto.cameraDistanceFt = placement.distanceFt
        dto.lensHeightFt = placement.heightFt
        dto.cameraRollDeg = placement.rollDeg

        do {
            try store.save(dto)
            reload()
            lastSwing = dto
            if let failure {
                banner = Banner(kind: .warning, text: "Clip saved but no ball track: \(failure)")
            }
        } catch {
            banner = Banner(kind: .error, text: "Could not save the swing: \(error.localizedDescription)")
        }
    }

    // MARK: - Editing and re-analysis

    func update(_ swing: SwingDTO) {
        do {
            try store.save(swing)
            reload()
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
    }

    func delete(_ swing: SwingDTO) {
        ClipStore.delete(clipNamed: swing.clipFilename)
        ClipStore.delete(trackNamed: swing.trackCSVFilename)
        try? store.delete(id: swing.id)
        reload()
    }

    /// Re-run the pipeline on a stored clip — after retuning colour ranges,
    /// or with the fallback detector forced.
    func reanalyze(_ swing: SwingDTO, forceFallback: Bool = false) {
        guard let clipName = swing.clipFilename else {
            banner = Banner(kind: .warning, text: "That swing has no clip to re-analyze.")
            return
        }
        let url = ClipStore.clipURL(named: clipName)
        var options = settings.analyzerOptions
        options.rollDeg = swing.cameraRollDeg ?? 0
        options.forceFallbackDetector = forceFallback
        analysisProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await ClipAnalyzer.analyze(
                    url: url,
                    contactTime: swing.contactTime > 0 ? swing.contactTime : nil,
                    options: options,
                    progress: { p in
                        Task { @MainActor [weak self] in self?.analysisProgress = p }
                    })
                await MainActor.run {
                    var updated = SwingDTO(analysis: analysis,
                                           setting: swing.setting,
                                           clipFilename: clipName,
                                           autoTriggered: swing.autoTriggered)
                    // Preserve everything the pipeline does not produce.
                    updated.id = swing.id
                    updated.capturedAt = swing.capturedAt
                    updated.trackCSVFilename = swing.trackCSVFilename
                    updated.hangS = swing.hangS
                    updated.carryFt = swing.carryFt
                    updated.cameraDistanceFt = swing.cameraDistanceFt
                    updated.lensHeightFt = swing.lensHeightFt
                    updated.cameraRollDeg = swing.cameraRollDeg
                    updated.notes = swing.notes
                    self.analysisProgress = nil
                    self.update(updated)
                    self.banner = AppModel.Banner(kind: .info, text: "Re-analyzed.")
                }
            } catch {
                await MainActor.run {
                    self.analysisProgress = nil
                    self.banner = AppModel.Banner(kind: .error, text: error.localizedDescription)
                }
            }
        }
    }

    func reload() {
        do {
            swings = try store.all()
        } catch {
            banner = Banner(kind: .error, text: "Could not read stored swings: \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    func exportAll() -> [URL] {
        var urls: [URL] = []
        let stamp = Self.stampFormatter.string(from: Date())
        if let u = try? CSVExport.write(CSVExport.summaryCSV(swings),
                                        filename: "summary_\(stamp).csv") { urls.append(u) }
        if let u = try? CSVExport.write(CSVExport.fullCSV(swings),
                                        filename: "swinglab_\(stamp).csv") { urls.append(u) }
        if let u = try? CSVExport.write(CSVExport.scoreboardText(scoreboard),
                                        filename: "validation_\(stamp).txt") { urls.append(u) }
        return urls
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
