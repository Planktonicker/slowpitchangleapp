// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import CoreMedia
import Foundation

/// Detects bat-on-ball contact from the microphone.
///
/// Same measurement as `spike/check_audio_trigger.py` (validation gate G5):
/// short-window RMS against a rolling median noise floor, and a contact
/// impulse has to stand `SLA.triggerDb` above that floor. Running the same
/// test the Python does means a venue that passes G5 on the Mac will trigger
/// here.
final class ContactTrigger {

    /// Fired with the presentation time of the impulse.
    var onContact: ((CMTime) -> Void)?

    /// Everything below is touched from two queues: audio buffers arrive on
    /// the capture queue and run `process`, while arming and disarming happen
    /// on the pipeline queue and call `reset`. Without this lock, arming while
    /// the microphone was mid-buffer emptied `carry` underneath `process` and
    /// trapped on "Can't remove more items from a collection than it has" —
    /// which is what made pressing ARM kill the app.
    private let lock = NSLock()

    private var _lastDb: Double = 0
    /// Live level for the UI, in dB over the rolling floor.
    var lastDb: Double {
        lock.lock(); defer { lock.unlock() }
        return _lastDb
    }

    private var _thresholdDb: Double
    var thresholdDb: Double {
        get { lock.lock(); defer { lock.unlock() }; return _thresholdDb }
        set { lock.lock(); _thresholdDb = newValue; lock.unlock() }
    }

    private var _refractoryS: Double = 2.0
    /// Ignore further impulses for this long after one fires — the ball
    /// hitting a net or the ground would otherwise re-trigger immediately.
    var refractoryS: Double {
        get { lock.lock(); defer { lock.unlock() }; return _refractoryS }
        set { lock.lock(); _refractoryS = newValue; lock.unlock() }
    }

    private var _isArmed = true
    var isArmed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isArmed }
        set { lock.lock(); _isArmed = newValue; lock.unlock() }
    }

    private let rmsWindowS = 0.005      // 5 ms
    private let floorWindowS = 0.5      // rolling median span
    private var floorHistory: [Double] = []
    private var maxFloorSamples: Int { max(8, Int(floorWindowS / rmsWindowS)) }
    private var lastFireTime: Double = -.infinity
    private var carry: [Double] = []    // leftover samples between callbacks

    init(thresholdDb: Double = SLA.triggerDb) {
        self._thresholdDb = thresholdDb
    }

    func reset() {
        lock.lock()
        floorHistory.removeAll()
        carry.removeAll()
        lastFireTime = -.infinity
        lock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let mono = Self.monoSamples(from: sampleBuffer) else { return }
        guard let asbd = Self.asbd(from: sampleBuffer) else { return }
        let sampleRate = asbd.mSampleRate
        guard sampleRate > 0 else { return }

        let startPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startSeconds = startPTS.isNumeric ? startPTS.seconds : 0
        let windowLength = max(1, Int(rmsWindowS * sampleRate))

        // Impulses are collected and fired after the lock is released: the
        // callback hops to the pipeline queue, and calling out from inside a
        // lock that the pipeline queue also takes is how deadlocks are made.
        var fires: [Double] = []

        lock.lock()
        carry.append(contentsOf: mono)
        var offset = 0
        while carry.count - offset >= windowLength {
            var sumSq = 0.0
            for i in 0..<windowLength {
                let v = carry[offset + i]
                sumSq += v * v
            }
            let rms = (sumSq / Double(windowLength)).squareRoot() + 1e-9

            let floor = medianFloor() + 1e-9
            let db = 20 * log10(rms / floor)
            _lastDb = db

            let windowTime = startSeconds
                + Double(offset) / sampleRate
                + rmsWindowS / 2

            if _isArmed,
               db >= _thresholdDb,
               floorHistory.count >= maxFloorSamples / 2,
               windowTime - lastFireTime >= _refractoryS {
                lastFireTime = windowTime
                fires.append(windowTime)
            }

            floorHistory.append(rms)
            if floorHistory.count > maxFloorSamples { floorHistory.removeFirst() }
            offset += windowLength
        }
        // Clamped rather than trusted. The loop bound already implies
        // offset <= carry.count, but this line is the one that crashed, so it
        // does not get to depend on an invariant holding across a refactor.
        if offset > 0 { carry.removeFirst(min(offset, carry.count)) }
        // Guard against unbounded growth if the format ever changes mid-run.
        if carry.count > Int(sampleRate) {
            carry.removeFirst(min(carry.count - Int(sampleRate), carry.count))
        }
        lock.unlock()

        for windowTime in fires {
            onContact?(CMTime(seconds: windowTime, preferredTimescale: 44_100))
        }
    }

    private func medianFloor() -> Double {
        guard !floorHistory.isEmpty else { return 1e-9 }
        let sorted = floorHistory.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MARK: - PCM extraction

    private static func asbd(from sb: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let p = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        return p.pointee
    }

    /// First channel of the buffer as `Double`, handling the LPCM layouts
    /// `AVCaptureAudioDataOutput` actually produces (Int16 or Float32,
    /// interleaved or planar).
    private static func monoSamples(from sb: CMSampleBuffer) -> [Double]? {
        guard let asbd = asbd(from: sb) else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isPlanar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // Planar audio carries one AudioBuffer per channel, so the list's
        // size depends on the format — query it first. A fixed
        // single-buffer list makes the copy call fail outright on planar
        // formats, which would silently kill the trigger.
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, listSize >= MemoryLayout<AudioBufferList>.size else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let ablPtr = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let retained = blockBuffer else { return nil }

        // The sample memory belongs to the block buffer — keep it alive for
        // the whole read.
        return withExtendedLifetime(retained) { () -> [Double]? in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let first = buffers.first, let raw = first.mData else { return nil }
            let byteCount = Int(first.mDataByteSize)
            // Planar layouts put channel 0 alone in the first buffer;
            // interleaved layouts stride by channel count.
            let stride = isPlanar ? 1 : channels

            var out: [Double] = []
            if isFloat {
                let count = byteCount / MemoryLayout<Float>.size
                let p = raw.bindMemory(to: Float.self, capacity: count)
                out.reserveCapacity(count / stride)
                var i = 0
                while i < count { out.append(Double(p[i])); i += stride }
            } else {
                let count = byteCount / MemoryLayout<Int16>.size
                let p = raw.bindMemory(to: Int16.self, capacity: count)
                out.reserveCapacity(count / stride)
                var i = 0
                while i < count { out.append(Double(p[i]) / 32768.0); i += stride }
            }
            return out
        }
    }
}
