// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import XCTest
@testable import SwingLab

/// Renders the setup and HUD controls to PNG so a layout can be looked at
/// without a phone in the room.
///
/// Not assertions — pictures. Every layout fault found so far (a panel painted
/// over half the picture, a stepper wrapping onto two lines, a Back button
/// sliced by the panel edge, controls sharing no edge in landscape) compiled
/// cleanly and passed every test. A compiler cannot see a ragged margin.
///
/// **What these images do NOT show.** The composed screen over a live camera is
/// out of reach here and always will be: a simulator has no camera, and
/// `CaptureController.status` and the `LevelSensor` readings are `private(set)`
/// and hardware-fed, so `SetupOverlay` as a whole would render its "Starting
/// the camera…" card and the Ready panel would sit frozen at "Level unknown".
/// `CameraPreview` cannot be captured by any renderer — it is a video layer.
/// So these are the PARTS, at the sizes they really get, in states chosen by
/// hand. That is enough to catch the faults above, and it is not a substitute
/// for looking at a phone.
///
/// One artefact to know before reading the images: `ImageRenderer` does not
/// draw a `Menu`'s label, so the "..." control in the hitter panel comes out as
/// a missing-symbol sign. It is correct on device. Do not chase it.
@MainActor
final class SetupShotTests: XCTestCase {

    /// The panel column in landscape, and the full content width in portrait on
    /// a 393 pt-wide phone. Both are the real numbers from `SetupOverlay`.
    private let panelWidth: CGFloat = 300
    private let portraitWidth: CGFloat = 365

    // MARK: - Output

    /// Written beside the source tree rather than into the simulator's data
    /// container. `#filePath` is the path on the machine that COMPILED this,
    /// which is the machine CI then collects from; the simulator shares that
    /// filesystem, so the file lands where a later build step can find it. An
    /// environment variable would be tidier but needs a run to prove, and a
    /// screenshot job that silently writes nowhere is worse than none.
    private static let outDir: URL = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository root
        let dir = root.appendingPathComponent("build/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func shoot<V: View>(_ name: String, width: CGFloat, _ view: V) {
        let framed = view
            .frame(width: width)
            .padding(14)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.uiImage, let png = image.pngData() else {
            XCTFail("could not render \(name)")
            return
        }
        let url = Self.outDir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }

    /// A wizard with the optics a phone actually reports, so anything derived
    /// from them is the number the app would show.
    private func makeWizard() -> PlacementWizard {
        let wizard = PlacementWizard()
        wizard.imageWidthPx = 1920
        wizard.imageHeightPx = 1080
        wizard.fieldOfViewDeg = 68
        wizard.hitterHeightM = 1.81
        wizard.lockChime = {}
        return wizard
    }

    // MARK: - Header and instruments

    func testShootStepper() {
        for (name, stage) in [("level", PlacementWizard.SetupStage.level),
                              ("hitter", .hitter),
                              ("ready", .ready)] {
            // Full header, because the wrap that had to be fixed only appeared
            // once the stepper was competing with the buttons for the width.
            shoot("header-\(name)", width: portraitWidth,
                  SetupHeader(stage: stage, onSelect: { _ in },
                              onClose: {}, onMirror: {}, onHelp: {}))
        }
    }

    func testShootRollBeam() {
        shoot("beam-level", width: portraitWidth, RollBeam(rollDeg: 0.4, isRollOK: true))
        shoot("beam-off", width: portraitWidth, RollBeam(rollDeg: 6.2, isRollOK: false))
    }

    // MARK: - Stage panels, at the width they get in each orientation

    func testShootLevelPanel() {
        for (label, width) in [("landscape", panelWidth), ("portrait", portraitWidth)] {
            shoot("panel-level-\(label)", width: width,
                  LevelStagePanel(isLevel: false, onNext: {}))
            shoot("panel-level-ok-\(label)", width: width,
                  LevelStagePanel(isLevel: true, onNext: {}))
        }
    }

    func testShootHitterPanel() {
        // No height typed yet — the first thing a new user sees.
        let fresh = makeWizard()
        fresh.hitterHeightM = nil
        fresh.go(to: .hitter)
        shoot("panel-hitter-needs-height", width: panelWidth,
              hitterPanel(fresh, heightCm: nil))

        // Looking, with a height in hand.
        let looking = makeWizard()
        looking.go(to: .hitter)
        shoot("panel-hitter-looking", width: panelWidth, hitterPanel(looking))

        // Measured and locked, which is the state with the most in it.
        let locked = makeWizard()
        locked.go(to: .hitter)
        feedStandingHitter(locked)
        shoot("panel-hitter-locked", width: panelWidth, hitterPanel(locked))
        shoot("panel-hitter-locked-portrait", width: portraitWidth, hitterPanel(locked))

        // The plate sub-mode carries the longest copy on the screen.
        let plate = makeWizard()
        plate.go(to: .hitter)
        plate.distanceMethod = .plate
        shoot("panel-hitter-plate", width: panelWidth, hitterPanel(plate))
    }

    func testShootReadyPanel() {
        // A distance that was skipped, and one that was typed — the two ends of
        // what the summary rows have to say.
        let skipped = makeWizard()
        skipped.go(to: .ready)
        shoot("panel-ready-skipped", width: panelWidth,
              ReadyStagePanel(wizard: skipped, hitterPresent: false, onArm: {}, onBack: {}))

        let measured = makeWizard()
        measured.manualDistanceM = 5.2
        measured.applyManualDistance()
        measured.go(to: .ready)
        shoot("panel-ready-measured", width: panelWidth,
              ReadyStagePanel(wizard: measured, hitterPresent: true, onArm: {}, onBack: {}))
        shoot("panel-ready-measured-portrait", width: portraitWidth,
              ReadyStagePanel(wizard: measured, hitterPresent: true, onArm: {}, onBack: {}))
    }

    // MARK: - The guide, at real screen shapes

    func testShootFramingGuide() {
        shoot("guide-landscape", width: 852,
              FramingGuide(fov: 68, isLandscape: true, screenAspect: 852.0 / 393.0,
                           hitterOnLeft: true, hitterHeightM: 1.81,
                           rightInset: 28 / 852, topInset: 100 / 393,
                           bottomInset: 0, outlineValid: true)
                .frame(width: 852, height: 393))
        shoot("guide-portrait", width: 393,
              FramingGuide(fov: 68, isLandscape: false, screenAspect: 393.0 / 852.0,
                           hitterOnLeft: true, hitterHeightM: 1.81,
                           rightInset: 0, topInset: 100 / 852, bottomInset: 220 / 852,
                           outlineValid: true)
                .frame(width: 393, height: 852))
    }

    // MARK: - HUD controls

    func testShootScoreBug() {
        for (name, state) in [("ready", HUDState.ready), ("armed", .armed),
                              ("recording", .recording), ("analysing", .analysing)] {
            // The width the bug really gets on a 393pt phone (its own floor,
            // since 30% of the screen is under it), and its landscape share.
            shoot("bug-\(name)", width: ScoreBug.minWidth(height: 52), scoreBug(state))
            shoot("bug-\(name)-wide", width: 256, scoreBug(state))
        }
    }

    /// The whole control block, both orientations, at the widths the app
    /// really gives it. Composition is the thing being checked here — the
    /// version this replaced had three widths and three left edges, which
    /// compiled, tested clean, and looked like three unrelated islands.
    func testShootControlBlock() {
        shoot("block-portrait", width: 204, VStack(spacing: 10) {
            bug(.armed, subline: "field, live pitching · no swings yet")
            armedActions
            endRound
        })

        shoot("block-landscape", width: 426, VStack(spacing: 10) {
            HStack(spacing: 10) {
                bug(.armed, subline: "field, live pitching · no swings yet")
                armedActions.frame(width: 140)
            }
            .frame(height: 52)
            endRound
        })

        // Analysing: no MANUAL — `contextAction` returns nil — so the longest
        // word on the screen gets the whole width.
        shoot("block-analysing", width: 204, VStack(spacing: 10) {
            bug(.analysing, subline: nil)
            Button {} label: { Text("Measuring…") }
                .buttonStyle(SlabButtonStyle(fill: Theme.surface, textColor: Theme.steel,
                                             size: 15, verticalPadding: 0, minHeight: 52))
            endRound
        })
    }

    /// The ribbon at both shapes. Portrait is the one that was broken: the
    /// controls took most of a 361pt line and left every chip reading "1…".
    func testShootRibbon() {
        let chips: [(text: String, symbol: String, color: Color)] = [
            ("340 dropped · buffers", "exclamationmark.triangle.fill", Theme.warn),
            ("2 ignored", "bolt.slash.fill", Theme.warn),
            ("no hitter", "person.slash.fill", Theme.warn),
        ]
        let controls = AnyView(HStack(spacing: 8) {
            Text("SET UP").font(Theme.label(11)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(Theme.yellow).frame(height: 44)
            Text("FIELD, LIVE PITCHING ⌄").font(Theme.label(11))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(Theme.yellow).frame(height: 44)
        })
        shoot("ribbon-portrait", width: 361,
              ExceptionRibbon(chips: chips, onChipTap: {}, trailing: controls,
                              isLandscape: false))
        shoot("ribbon-landscape", width: 820,
              ExceptionRibbon(chips: chips, onChipTap: {}, trailing: controls,
                              isLandscape: true))
    }

    // MARK: - The opening screen

    /// The screen the app opens on, panel by panel, at the 353pt a 393pt phone
    /// gives it. Seven tappable rectangles became three; the question is
    /// whether three still says everything the seven did.
    func testShootStartPanels() {
        for mode in SessionMode.allCases {
            shoot("start-mode-\(mode.rawValue)", width: 353, ModeCard(mode: mode))
        }
        shoot("start-library-empty", width: 353,
              LibraryPanel(swingCount: 0, onSwings: {}, onRounds: {}, onTrends: {}))
        shoot("start-library", width: 353,
              LibraryPanel(swingCount: 3, onSwings: {}, onRounds: {}, onTrends: {}))

        // The three together, in the order and spacing the screen uses, since
        // the point of the change was the composition rather than any panel.
        shoot("start-stack", width: 353, VStack(alignment: .leading, spacing: 22) {
            ModeCard(mode: .live)
            VStack(spacing: 10) {
                Button {} label: { Text("Start session") }
                    .buttonStyle(SlabButtonStyle(size: 19, verticalPadding: 20))
                Text("Next: frame the hitter and tap the ball once. The camera does not start until then.")
                    .font(.caption).foregroundStyle(Theme.steel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LibraryPanel(swingCount: 3, onSwings: {}, onRounds: {}, onTrends: {})
        })
    }

    // MARK: - Helpers

    private func bug(_ state: HUDState, subline: String?) -> some View {
        ScoreBug(state: state, label: "Launch", value: state.isLoud ? "" : "31°",
                 qualifier: nil, subline: subline, height: 52, onTap: {})
    }

    private var armedActions: some View {
        HStack(spacing: 10) {
            Button {} label: {
                VStack(spacing: 2) {
                    Image(systemName: "bolt.fill").font(.system(size: 17, weight: .bold))
                    Text("MANUAL").font(Theme.label(9)).tracking(0.5)
                }
                .frame(width: 52)
            }
            .buttonStyle(OutlineButtonStyle(verticalPadding: 0, cornerRadius: 14, minHeight: 52))
            .frame(width: 52)
            Button {} label: { Text("Stop") }
                .buttonStyle(SlabButtonStyle(fill: Theme.fail, textColor: .white,
                                             size: 19, verticalPadding: 0, minHeight: 52))
        }
        .frame(height: 52)
    }

    private var endRound: some View {
        Button {} label: {
            Label("End round", systemImage: "flag.checkered")
                .font(Theme.label(12)).tracking(1)
        }
        .buttonStyle(OutlineButtonStyle(verticalPadding: 7, cornerRadius: 10, hitHeight: 44))
    }

    private func scoreBug(_ state: HUDState) -> some View {
        ScoreBug(state: state,
                 label: "Launch",
                 value: state.isLoud ? "" : "31°",
                 qualifier: nil,
                 subline: "live pitching · no swings yet",
                 height: 60,
                 onTap: {})
    }

    private func hitterPanel(_ wizard: PlacementWizard, heightCm: Double? = 181) -> some View {
        HitterStagePanel(wizard: wizard,
                         heightCm: .constant(heightCm),
                         measuring: false,
                         failureText: nil,
                         isRoughBall: false,
                         detectorReport: nil,
                         onTypeDistance: {},
                         onBack: {},
                         onNext: {})
    }

    /// The same synthetic upright hitter the wizard tests use, so a locked
    /// panel shows a real measured distance rather than a made-up string.
    private func feedStandingHitter(_ wizard: PlacementWizard) {
        let width = wizard.imageWidthPx, height = wizard.imageHeightPx
        let focal = TiltRectifier.focalPx(widthPx: width, fovDeg: wizard.fieldOfViewDeg)
        let span = focal * 1.81 * HitterScale.noseToAnkleStatureFraction / 5.25
        let cx = width / 2, cy = height / 2
        let top = cy - span / 2, foot = cy + span / 2
        let pixels: [PoseJoint: CGPoint] = [
            .nose: CGPoint(x: cx, y: top),
            .leftShoulder: CGPoint(x: cx - 70, y: top + 0.10 * span),
            .rightShoulder: CGPoint(x: cx + 70, y: top + 0.10 * span),
            .leftHip: CGPoint(x: cx - 20, y: top + 0.45 * span),
            .rightHip: CGPoint(x: cx + 20, y: top + 0.45 * span),
            .leftKnee: CGPoint(x: cx - 20, y: top + 0.72 * span),
            .rightKnee: CGPoint(x: cx + 20, y: top + 0.72 * span),
            .leftAnkle: CGPoint(x: cx - 20, y: foot),
            .rightAnkle: CGPoint(x: cx + 20, y: foot),
        ]
        let joints = pixels.mapValues {
            CGPoint(x: Double($0.x) / width, y: Double($0.y) / height)
        }
        for i in 0..<HitterScale.samplesNeeded {
            wizard.noteSkeleton(joints, hitterPresent: true, at: Double(i) * 0.1)
        }
    }
}
