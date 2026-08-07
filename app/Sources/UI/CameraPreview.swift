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
    /// Live skeleton in capture-device coordinates, or `nil` to draw nothing.
    ///
    /// Drawn inside the preview view rather than as a SwiftUI overlay, because
    /// the conversion from camera space to screen space is
    /// `layerPointConverted(fromCaptureDevicePoint:)` — a method on the preview
    /// layer, which SwiftUI never sees. Hand-rolling that mapping means getting
    /// the fill crop, the rotation and the mirroring right in two places
    /// instead of none.
    var skeleton: [PoseJoint: CGPoint]?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.controller = controller
        view.onTap = onTap
        view.skeleton = skeleton
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
        view.skeleton = skeleton
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

        var skeleton: [PoseJoint: CGPoint]? {
            didSet { redrawSkeleton() }
        }

        private let skeletonLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = Theme.yellowUI.withAlphaComponent(0.95).cgColor
            l.lineWidth = 3
            l.lineCap = .round
            l.lineJoin = .round
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.8
            l.shadowRadius = 3
            l.shadowOffset = .zero
            return l
        }()

        private let jointLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = Theme.yellowUI.cgColor
            l.strokeColor = UIColor.black.withAlphaComponent(0.6).cgColor
            l.lineWidth = 1
            return l
        }()

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
            layer.addSublayer(skeletonLayer)
            layer.addSublayer(jointLayer)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            skeletonLayer.frame = bounds
            jointLayer.frame = bounds
            redrawSkeleton()
        }

        /// Stroke the segments `PoseJoint.segments` names, skipping any whose
        /// endpoints the model was not confident about — a skeleton with a
        /// missing shin is honest; one drawn through a guessed ankle is not.
        private func redrawSkeleton() {
            guard let skeleton, !skeleton.isEmpty, bounds.width > 1 else {
                skeletonLayer.path = nil
                jointLayer.path = nil
                return
            }
            let layerPoint = { [videoPreviewLayer] (j: PoseJoint) -> CGPoint? in
                guard let p = skeleton[j] else { return nil }
                return videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: p)
            }

            let bones = CGMutablePath()
            for chain in PoseJoint.segments {
                var pending: CGPoint?
                for joint in chain {
                    guard let here = layerPoint(joint) else { pending = nil; continue }
                    if let from = pending {
                        bones.move(to: from)
                        bones.addLine(to: here)
                    }
                    pending = here
                }
            }
            let dots = CGMutablePath()
            for joint in PoseJoint.allCases {
                guard let p = layerPoint(joint) else { continue }
                dots.addEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            }
            // No implicit animation: at 10 Hz a default 0.25 s position tween
            // makes every joint lag the body it belongs to.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            skeletonLayer.path = bones
            jointLayer.path = dots
            CATransaction.commit()
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
