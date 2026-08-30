// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreMedia
import Foundation
import VideoToolbox

/// Hardware video encoder feeding the pre-roll ring.
///
/// Raw 1080p frames are ~3 MB each; at 240fps a few seconds of ring would be
/// gigabytes, so frames are compressed the moment they arrive and the ring
/// holds encoded samples.
///
/// Frame reordering is disabled on purpose: with no B-frames, presentation
/// order equals decode order, which is what makes it safe for the ring to
/// drop everything before a keyframe.
final class VideoEncoder {

    enum EncoderError: LocalizedError {
        case sessionCreateFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .sessionCreateFailed(let s):
                return "Could not start the video encoder (status \(s))."
            }
        }
    }

    /// Called on the encoder's own queue for every encoded frame.
    var onEncoded: ((CMSampleBuffer) -> Void)?

    /// Guarded by `sessionLock`: `encode` runs on the 240fps video queue
    /// while `invalidate` runs on the session queue during stop/reconfigure,
    /// and an unsynchronized strong `var` read against its release is a data
    /// race — at best encoding into a session mid-teardown, at worst a torn
    /// reference. The lock covers only the pointer handoff; the encode call
    /// itself runs on a local strong reference, and VideoToolbox returns an
    /// error (not UB) for a frame submitted to an invalidated session.
    private var session: VTCompressionSession?
    private let sessionLock = NSLock()
    private(set) var codec: CMVideoCodecType = kCMVideoCodecType_HEVC

    init(width: Int, height: Int, fps: Double, bitrate: Int? = nil) throws {
        let targetBitrate = bitrate ?? Self.defaultBitrate(width: width, height: height, fps: fps)

        // HEVC halves the bitrate for the same quality, but fall back to H.264
        // rather than refusing to record.
        for candidate in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: candidate,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,      // required: using the block-based encode API
                refcon: nil,
                compressionSessionOut: &s
            )
            if status == noErr, let created = s {
                session = created
                codec = candidate
                break
            }
        }
        guard let session else { throw EncoderError.sessionCreateFailed(-1) }

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: targetBitrate))
        // A keyframe four times a second: the ring can trim to a keyframe
        // without throwing away much pre-roll.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(value: max(1, Int(fps / 4))))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0.25))
        if codec == kCMVideoCodecType_HEVC {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private static func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        // ~0.08 bits per pixel per frame keeps 1080p240 readable without
        // smearing the ball edge the sub-pixel measurement depends on.
        let bpp = 0.08
        return Int(Double(width * height) * fps * bpp)
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        sessionLock.lock()
        let session = self.session
        sessionLock.unlock()
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sb = sampleBuffer else { return }
            self?.onEncoded?(sb)
        }
    }

    func invalidate() {
        sessionLock.lock()
        let session = self.session
        self.session = nil
        sessionLock.unlock()
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    deinit { invalidate() }
}

extension CMSampleBuffer {
    /// True for a keyframe (no `NotSync` attachment).
    var isSyncSample: Bool {
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
        else { return true }
        let array = raw as NSArray
        guard let first = array.firstObject as? NSDictionary else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync as NSString] as? Bool ?? false
        return !notSync
    }
}
