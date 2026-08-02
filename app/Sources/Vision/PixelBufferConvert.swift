// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import CoreImage
import CoreVideo
import Foundation

/// Converts camera frames to 32BGRA for the detector.
///
/// The capture output runs at the device-native pixel format (bi-planar YUV):
/// the encoder takes those buffers directly, and forcing BGRA on the capture
/// output would convert all 240 frames a second — twice, since VideoToolbox
/// wants YUV back. But `PixelImage` reads BGRA only, so the live "tap the ball"
/// measurement had no frame it could actually read. That is why live
/// measurement returned "couldn't find the ball" for every tap ever made: no
/// pixel was ever examined.
///
/// Conversion happens here instead, on demand, at roughly 10 Hz and only while
/// the setup overlay is on screen.
///
/// Deliberately CoreImage rather than a hand-written YUV→RGB loop: the
/// conversion has to get the colour matrix (601 vs 709) and range (video 16-235
/// vs full 0-255) right, and getting either subtly wrong would make the *live*
/// scale disagree with the *offline* scale measured from the same ball — the
/// exact class of silent error this project exists to avoid.
enum PixelBufferConvert {

    private static let context: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false,
                            .cacheIntermediates: false])
    }()

    private static let poolLock = NSLock()
    private static var pool: CVPixelBufferPool?
    private static var poolWidth = 0
    private static var poolHeight = 0

    /// BGRA view of `pb`.
    ///
    /// Returns the input untouched when it is already BGRA, so the offline
    /// analysis path (`ClipAnalyzer` asks the asset reader for BGRA directly)
    /// pays nothing for this existing.
    static func toBGRA(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA {
            return pb
        }
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        guard width > 0, height > 0,
              let out = dequeue(width: width, height: height) else { return nil }

        context.render(CIImage(cvPixelBuffer: pb), to: out)
        return out
    }

    private static func dequeue(width: Int, height: Int) -> CVPixelBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }

        if pool == nil || poolWidth != width || poolHeight != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
                attrs as CFDictionary,
                &created
            )
            guard status == kCVReturnSuccess, let created else { return nil }
            pool = created
            poolWidth = width
            poolHeight = height
        }

        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
                == kCVReturnSuccess else { return nil }
        return out
    }
}
