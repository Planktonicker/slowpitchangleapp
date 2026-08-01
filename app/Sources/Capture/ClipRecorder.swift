import AVFoundation
import CoreMedia
import Foundation

/// Commits one swing to disk: the pre-roll held in the ring, plus everything
/// up to `postRoll` seconds after contact.
///
/// Samples are accumulated in memory and the file is written in one go when
/// the window closes. Writing while capturing at 240fps would mean juggling
/// `isReadyForMoreMediaData` back-pressure against a live encoder, and
/// dropping a pre-roll frame to satisfy the writer is exactly the wrong
/// trade — a swing is only ~2 s of encoded video.
final class ClipRecorder {

    struct Output: Sendable {
        var url: URL
        /// Seconds from the start of the clip to the contact impulse.
        var contactOffset: Double
        var duration: Double
    }

    private(set) var isRecording = false

    private var videoSamples: [CMSampleBuffer] = []
    private var audioSamples: [CMSampleBuffer] = []
    private var startPTS: CMTime = .invalid
    private var contactPTS: CMTime = .invalid
    private var deadline: CMTime = .invalid
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private let queue = DispatchQueue(label: "swinglab.cliprecorder")

    /// Begin a clip. `videoRing`/`audioRing` are the pre-roll, oldest first.
    func begin(videoRing: [CMSampleBuffer],
               audioRing: [CMSampleBuffer],
               contactPTS: CMTime,
               postRoll: Double) {
        guard !isRecording else { return }
        videoSamples = videoRing
        audioSamples = audioRing
        self.contactPTS = contactPTS
        deadline = CMTimeAdd(contactPTS, CMTime(seconds: postRoll, preferredTimescale: 600))
        startPTS = videoRing.first.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? contactPTS
        videoFormat = videoRing.first.flatMap { CMSampleBufferGetFormatDescription($0) }
        audioFormat = audioRing.first.flatMap { CMSampleBufferGetFormatDescription($0) }
        isRecording = true
    }

    /// - Returns: true once the post-roll window has closed.
    func appendVideo(_ sb: CMSampleBuffer) -> Bool {
        guard isRecording else { return false }
        if videoFormat == nil { videoFormat = CMSampleBufferGetFormatDescription(sb) }
        if !startPTS.isValid {
            startPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        }
        videoSamples.append(sb)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        return pts.isNumeric && deadline.isNumeric && CMTimeCompare(pts, deadline) >= 0
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard isRecording else { return }
        if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sb) }
        audioSamples.append(sb)
    }

    func cancel() {
        isRecording = false
        videoSamples.removeAll()
        audioSamples.removeAll()
    }

    /// Write the accumulated samples out. Calls back on an arbitrary queue.
    func finish(url: URL, completion: @escaping (Result<Output, Error>) -> Void) {
        guard isRecording else {
            completion(.failure(RecorderError.notRecording))
            return
        }
        isRecording = false

        let video = videoSamples
        let audio = audioSamples
        let vFmt = videoFormat
        let aFmt = audioFormat
        let start = startPTS
        let contact = contactPTS
        videoSamples.removeAll()
        audioSamples.removeAll()

        queue.async {
            do {
                guard !video.isEmpty, let vFmt else { throw RecorderError.nothingToWrite }
                try? FileManager.default.removeItem(at: url)

                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                // Passthrough: the frames are already encoded, and re-encoding
                // would soften exactly the ball edge the sub-pixel diameter
                // measurement reads.
                let vIn = AVAssetWriterInput(mediaType: .video,
                                             outputSettings: nil,
                                             sourceFormatHint: vFmt)
                vIn.expectsMediaDataInRealTime = false
                guard writer.canAdd(vIn) else { throw RecorderError.cannotAddInput }
                writer.add(vIn)

                var aIn: AVAssetWriterInput?
                if let aFmt, !audio.isEmpty {
                    let input = AVAssetWriterInput(mediaType: .audio,
                                                   outputSettings: nil,
                                                   sourceFormatHint: aFmt)
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        writer.add(input)
                        aIn = input
                    }
                }

                guard writer.startWriting() else {
                    throw writer.error ?? RecorderError.writeFailed
                }
                writer.startSession(atSourceTime: start)

                let group = DispatchGroup()

                group.enter()
                var vi = 0
                let vQueue = DispatchQueue(label: "swinglab.write.video")
                vIn.requestMediaDataWhenReady(on: vQueue) {
                    while vIn.isReadyForMoreMediaData {
                        if vi >= video.count {
                            vIn.markAsFinished()
                            group.leave()
                            return
                        }
                        vIn.append(video[vi])
                        vi += 1
                    }
                }

                if let aIn {
                    group.enter()
                    var ai = 0
                    let aQueue = DispatchQueue(label: "swinglab.write.audio")
                    aIn.requestMediaDataWhenReady(on: aQueue) {
                        while aIn.isReadyForMoreMediaData {
                            if ai >= audio.count {
                                aIn.markAsFinished()
                                group.leave()
                                return
                            }
                            // Audio that predates the video session start
                            // would be rejected; skip it rather than fail.
                            let pts = CMSampleBufferGetPresentationTimeStamp(audio[ai])
                            if pts.isNumeric && CMTimeCompare(pts, start) >= 0 {
                                aIn.append(audio[ai])
                            }
                            ai += 1
                        }
                    }
                }

                group.notify(queue: self.queue) {
                    writer.finishWriting {
                        if writer.status == .completed {
                            let last = video.last.map { CMSampleBufferGetPresentationTimeStamp($0) }
                            let duration = (last?.isNumeric ?? false)
                                ? last!.seconds - start.seconds : 0
                            let offset = contact.isNumeric && start.isNumeric
                                ? max(0, contact.seconds - start.seconds) : 0
                            completion(.success(Output(url: url,
                                                       contactOffset: offset,
                                                       duration: duration)))
                        } else {
                            completion(.failure(writer.error ?? RecorderError.writeFailed))
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    enum RecorderError: LocalizedError {
        case notRecording, nothingToWrite, cannotAddInput, writeFailed

        var errorDescription: String? {
            switch self {
            case .notRecording: return "No clip in progress."
            case .nothingToWrite: return "No frames were captured for this swing."
            case .cannotAddInput: return "Could not set up the clip file."
            case .writeFailed: return "Saving the clip failed."
            }
        }
    }
}
