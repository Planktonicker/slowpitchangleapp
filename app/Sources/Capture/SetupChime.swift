// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AudioToolbox
import AVFAudio
import Foundation

/// The short tone that says the camera distance just locked.
///
/// It exists because the measurement happens while the hitter is standing in
/// the box looking at the pitcher, several metres from a phone whose screen
/// they cannot read. Sound is the only channel that reaches them.
///
/// Why a synthesised tone rather than `AudioServicesPlaySystemSound`: system
/// sounds obey the Ring/Silent switch, and a phone left muted on a tripod is
/// precisely the solo-user case this whole measurement exists to serve. Audio
/// played through the app's own `.playAndRecord` session — which the capture
/// controller has already configured with `.defaultToSpeaker` — is heard
/// either way. The system sound stays as the fallback, because a chime that
/// sometimes does not play is better than a crash.
///
/// Setup is never armed, so a stray tone here cannot start a clip.
final class SetupChime {

    static let shared = SetupChime()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Built once, on first use. Standing the engine up at launch would hold
    /// audio hardware through every screen that never chimes.
    private var buffer: AVAudioPCMBuffer?
    private var started = false

    private init() {}

    func play() {
        guard prepare(), let buffer else {
            // 1057 is the short system "tink". Muted, it is silent — which is
            // the case this class was written to avoid — but a silent chime is
            // still better than none, and the distance is on screen regardless.
            AudioServicesPlaySystemSound(1057)
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// True when the engine is running and a tone is ready to schedule.
    private func prepare() -> Bool {
        if started { return true }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        guard let format, let tone = Self.sine(format: format) else { return false }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        buffer = tone
        started = true
        return true
    }

    /// A quarter second of 880 Hz with raised-cosine fades.
    ///
    /// The fades are not decoration. A sine that starts and stops at full
    /// amplitude has a step at each end, and a step is a click — through a
    /// phone speaker outdoors it is the loudest part of the sound.
    private static func sine(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * 0.25)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let fade = Double(frames) * 0.15
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var gain = 0.35
            if Double(i) < fade {
                gain *= 0.5 * (1 - cos(.pi * Double(i) / fade))
            } else if Double(i) > Double(frames) - fade {
                gain *= 0.5 * (1 - cos(.pi * (Double(frames) - Double(i)) / fade))
            }
            channel[i] = Float(sin(2 * Double.pi * 880 * t) * gain)
        }
        return buffer
    }
}
