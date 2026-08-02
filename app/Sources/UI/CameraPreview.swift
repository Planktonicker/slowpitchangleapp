// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview.
///
/// `.resizeAspectFill`: the preview covers the whole screen with no letterbox.
/// The sensor is 16:9 and a modern iPhone screen is ~19.5:9, so filling crops
/// about 9% of the recorded frame off each of two edges (top/bottom in
/// landscape, left/right in portrait). That is a display crop only — the full
/// 16:9 frame is still encoded, ringed and analysed. The earlier aspect-fit
/// choice showed the whole recorded frame but wrapped it in black bars, which
/// read as a broken screen rather than an instrument.
///
/// Tap positions are converted through
/// `captureDevicePointConverted(fromLayerPoint:)`, which accounts for the fill
/// crop, the rotation and any mirroring — so measurement taps stay exact no
/// matter the gravity mode.
///
/// There is exactly **one** of these in the app, in `CaptureView`. Setup draws
/// over it rather than creating a second one. Two preview layers sharing a
/// session fight over the preview connection: the second one takes it, and
/// when that layer goes away the connection dies with it, leaving the first
/// permanently black. That was the "camera is black after setup" bug, and the
/// only robust fix is to never have a second layer.
struct CameraPreview: UIViewRepresentable {
    let controller: CaptureController
    /// Tap as a normalised camera point (for measurement and focus) and as a
    /// screen point (so a marker can be drawn exactly where the finger was —
    /// under a fill crop the two are not a simple scale of each other).
    var onTap: ((_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.controller = controller
        view.onTap = onTap
        // Note what is NOT done here: `layer.session = session`. That
        // assignment synchronously mutates a running session's graph on the
        // main thread, and against a 240fps session feeding VideoToolbox it
        // blocks for seconds — the hang when the setup screen opened.
        controller.attachPreview(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.controller = controller
        view.onTap = onTap
        // A connection that has gone away is a condition that can actually
        // become true, unlike the old identity check against a `let` session.
        if view.videoPreviewLayer.connection == nil {
            controller.attachPreview(view.videoPreviewLayer)
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.controller?.detachPreview()
    }

    final class PreviewView: UIView {
        weak var controller: CaptureController?
        var onTap: ((CGPoint, CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
            // A UIKit recognizer rather than SwiftUI's `.onTapGesture`: the
            // handler needs the layer itself to convert the touch into camera
            // coordinates, and SwiftUI never sees the layer.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let onTap else { return }
            let location = gesture.location(in: self)
            // Does the whole job: undoes the fill crop, the connection's
            // rotation, and any mirroring. Hand-rolling this is how you get a
            // bug that only reproduces in one orientation.
            let devicePoint = videoPreviewLayer
                .captureDevicePointConverted(fromLayerPoint: location)
            onTap(devicePoint, location)
        }

        /// Where a camera point lands on screen — used to draw the reticle
        /// back over the ball the detector actually found.
        func layerPoint(fromDevicePoint point: CGPoint) -> CGPoint {
            videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: point)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, videoPreviewLayer.connection == nil {
                controller?.attachPreview(videoPreviewLayer)
            }
        }
    }
}
