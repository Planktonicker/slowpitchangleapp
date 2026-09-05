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

    /// Fired with the presentation time of the impulse and how far it stood
    /// over the rolling floor.
    ///
    /// The dB is carried because the level alone decides whether a clip was
    /// triggered by the hit or by something else that happened to be loud.
    /// Measured on IMG_6703: a 17.1 dB noise fires the trigger half a second
    /// before a 37.0 dB bat crack, and without the number at fire time nothing
    /// downstream can tell that clip from one triggered correctly.
    var onContact: ((CMTime, Double) -> Void)?

    /// Everything below is touched from two queues: audio buffers arrive on
    /// the capture queue and run `process`, while arming and disarming happen
    /// on the pipeline queue and call `reset`. Without this lock, arming while
    /// the microphone was mid-buffer emptied `carry` underneath `process` and
    /// trapped on "Can't remove more items from a collection than it has" —
    /// which is what made pressing ARM kill the app.
    private let lock = NSLock()

    private var _lastDb: Double = 0
    private var _peakDb: Double = -.infinity
    private var _peakSinceArm: Double = -.infinity
    /// Live level for the UI, in dB over the rolling floor.
    /// The loudest 5 ms window since the last call, then the hold resets.
    ///
    /// `lastDb` is only the FINAL window of the most recent buffer — a bat
    /// crack occupies one or two windows in the middle of a ~23 ms buffer, so
    /// any consumer sampling `lastDb` at UI rate reads the ring-out, tens of
    /// dB under the impulse. Calibration was built on exactly that misread and
    /// suggested thresholds the live trigger — which sees every window — then
    /// blew straight through.
    func consumePeakDb() -> Double {
        lock.lock(); defer { lock.unlock() }
        let peak = _peakDb == -.infinity ? _lastDb : _peakDb
        _peakDb = -.infinity
        return peak
    }

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
    /// Ignore further impulses for this long after one is CONFIRMED — the ball
    /// hitting a net or the ground would otherwise re-trigger immediately.
    ///
    /// Confirmed, not merely detected. See `attemptRefractoryS`.
    var refractoryS: Double {
        get { lock.lock(); defer { lock.unlock() }; return _refractoryS }
        set { lock.lock(); _refractoryS = newValue; lock.unlock() }
    }

    /// How long a detected impulse suppresses the next one while the decision
    /// to record is still being made.
    ///
    /// The full refractory used to be stamped here, at detection, and that is
    /// where a great many swings went. `onContact` hops to the pipeline queue,
    /// and `CaptureController.startClip` can then refuse the impulse on four
    /// separate grounds — the controller is not armed, the hitter gate saw
    /// nobody, the recorder is already busy, the video ring is empty. Every one
    /// of those refusals still cost two full seconds of deafness for a clip
    /// that was never written, and two seconds is most of a slow-pitch at-bat.
    ///
    /// So detection now buys only this, which exists for one reason: a bat
    /// crack spans several 5 ms windows and the hop to the pipeline queue is
    /// not instant, so without it the same impulse would be reported half a
    /// dozen times. The full refractory is stamped by `confirmFire` once a clip
    /// is actually being written, and a refused impulse costs nothing beyond
    /// this quarter-second.
    static let attemptRefractoryS = 0.25

    /// DISARMED until somebody arms it. This defaulted to true, and
    /// `CaptureController` only synced it when its own `isArmed` CHANGED — so
    /// from the moment the camera configured until the first press of ARM, the
    /// trigger was live while the screen said "2 · Arm". A bat drop, a clap,
    /// or a door recorded a clip from a ring buffer that was still discarding
    /// late frames, on a phone whose owner had not armed anything.
    private var _isArmed = false
    var isArmed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isArmed }
        set { lock.lock(); _isArmed = newValue; lock.unlock() }
    }

    private let rmsWindowS = 0.005      // 5 ms
    private let floorWindowS = 0.5      // rolling median span
    private var floorHistory: [Double] = []
    private var maxFloorSamples: Int { max(8, Int(floorWindowS / rmsWindowS)) }
    /// Anchor for the full refractory. Written only by `confirmFire`.
    private var lastFireTime: Double = -.infinity
    /// Anchor for `attemptRefractoryS`. Written when an impulse is detected,
    /// whatever becomes of it.
    private var lastAttemptTime: Double = -.infinity
    private var carry: [Double] = []    // leftover samples between callbacks

    init(thresholdDb: Double = SLA.triggerDb) {
        self._thresholdDb = thresholdDb
    }

    /// A new armed stretch: forget the venue and start listening from scratch.
    ///
    /// Only at the START of a round. Doing it after every clip is what put a
    /// quarter-second hole in the trigger each time it recorded one — the fire
    /// test refuses to run until `floorHistory` is half full, which is 50
    /// windows of 5 ms, and a hitter who swings again quickly lands in it.
    func resetForRound() {
        lock.lock()
        floorHistory.removeAll()
        carry.removeAll()
        lastFireTime = -.infinity
        lastAttemptTime = -.infinity
        _peakSinceArm = -.infinity
        lock.unlock()
    }

    /// Back to listening after a clip, WITHOUT forgetting the venue.
    ///
    /// The noise floor measured a moment ago is the best estimate available of
    /// the noise floor now — the field did not change while the clip was being
    /// written. Keeping it is what removes the dead zone. `lastFireTime` is
    /// kept too, deliberately: the refractory exists to stop the ball rattling
    /// a fence from starting a second clip, and that is exactly the moment this
    /// runs.
    func rearm() {
        lock.lock()
        _peakSinceArm = -.infinity
        lock.unlock()
    }

    /// The impulse at `time` became a clip. Start the full refractory.
    ///
    /// Called from the recording path once it has committed, so an impulse that
    /// is refused downstream never reaches here and never costs the refractory.
    func confirmFire(at time: Double) {
        lock.lock()
        lastFireTime = time
        lock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let mono = Self.monoSamples(from: sampleBuffer) else { return }
        guard let asbd = Self.asbd(from: sampleBuffer) else { return }
        let sampleRate = asbd.mSampleRate
        guard sampleRate > 0 else { return }

        let startPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startSeconds = startPTS.isNumeric ? startPTS.seconds : 0

        for (windowTime, db) in process(samples: mono,
                                        sampleRate: sampleRate,
                                        startSeconds: startSeconds) {
            onContact?(CMTime(seconds: windowTime, preferredTimescale: 44_100), db)
        }
    }

    /// The measurement, with the buffer plumbing lifted off it.
    ///
    /// Split out for one reason: `CMSampleBuffer` carrying LPCM is awkward to
    /// build in a unit test and the microphone is not available on a simulator,
    /// so with the two welded together none of this had a test at all — and it
    /// decides when the app records, which is upstream of every measurement the
    /// app makes. `process(sampleBuffer:)` is now PCM extraction and nothing
    /// else.
    ///
    /// Returns the impulses detected in this batch, as (time, dB over the
    /// floor). The caller reports them; they are returned rather than called
    /// back from inside the lock, because the callback hops to the pipeline
    /// queue and calling out from under a lock that queue also takes is how
    /// deadlocks are made.
    func process(samples: [Double], sampleRate: Double,
                 startSeconds: Double) -> [(Double, Double)] {
        guard sampleRate > 0 else { return [] }
        let mono = samples
        let windowLength = max(1, Int(rmsWindowS * sampleRate))
        var fires: [(Double, Double)] = []

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
            if db > _peakDb { _peakDb = db }

            let windowTime = startSeconds
                + Double(offset) / sampleRate
                + rmsWindowS / 2

            if _isArmed,
               db >= _thresholdDb,
               floorHistory.count >= maxFloorSamples / 2,
               windowTime - lastFireTime >= _refractoryS,
               windowTime - lastAttemptTime >= Self.attemptRefractoryS {
                lastAttemptTime = windowTime
                fires.append((windowTime, db))
            }
            // Measured even when the trigger is disarmed, which is the state
            // it is in for the whole of a clip. The loudest thing heard while
            // recording is the evidence that the thing which STARTED the
            // recording was not the hit — on IMG_6703 the trigger fired on
            // 17.1 dB and the bat crack 0.5 s later reached 37.0, and by then
            // the trigger had been disarmed and never saw it.
            if db > _peakSinceArm { _peakSinceArm = db }

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
        return fires
    }

    /// The loudest window since this was last called, over the rolling floor.
    /// Unlike `consumePeakDb` this is not reset by the UI meter — it exists so
    /// the recording path can ask "was anything in that clip much louder than
    /// what triggered it" without racing the meter for the same value.
    func consumePeakSinceArm() -> Double {
        lock.lock(); defer { lock.unlock() }
        let peak = _peakSinceArm
        _peakSinceArm = -.infinity
        return peak
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
