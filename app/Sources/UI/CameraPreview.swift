// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview.
///
/// `.resizeAspect` rather than `.resizeAspectFill`: framing matters here — the
/// protocol asks for the plate about a third in from the edge — and a fill
/// crop would hide part of what is actually being recorded.
///
/// There is exactly **one** of these in the app, in `CaptureView`. Setup draws
/// over it rather than creating a second one. Two preview layers sharing a
/// session fight over the preview connection: the second one takes it, and
/// when that layer goes away the connection dies with it, leaving the first
/// permanently black. That was the "camera is black after setup" bug, and the
/// only robust fix is to never have a second layer.
struct CameraPreview: UIViewRepresentable {
    let controller: CaptureController
    /// Tap in image-pixel coordinates of the capture buffer, plus the
    /// normalised device point for focus/exposure.
    var onTap: ((_ devicePoint: CGPoint) -> Void)?

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
        var onTap: ((CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspect
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
            // Does the whole job: undoes the `.resizeAspect` letterbox, the
            // connection's rotation, and any mirroring. Hand-rolling this is
            // how you get a bug that only reproduces in one orientation.
            let devicePoint = videoPreviewLayer
                .captureDevicePointConverted(fromLayerPoint: location)
            onTap(devicePoint)
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
