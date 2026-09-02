// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// The two plate markers, in capture-device coordinates.
struct PlateMarkerPair: Equatable {
    var start: CGPoint
    var end: CGPoint
}

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
///
/// It is built as a plain container around an inner view whose backing layer is
/// the preview layer, and the split is load-bearing. The display zoom is a
/// transform, SwiftUI assigns a representable's view `frame` on every layout
/// pass, and `frame` is undefined for a view with a non-identity `transform` —
/// so the transformed thing must not be the view SwiftUI is laying out.
///
/// The zoom is a **display** transform, not `videoZoomFactor`. Sensor zoom is a
/// centre crop that cannot be panned, and the plate sits about a third of the
/// way in from the frame edge by protocol, so at 3x it would leave the picture
/// entirely. It also changes the buffers and the field of view the placement
/// wizard read once at configure time, which would quietly invalidate every
/// distance on the screen doing the zooming.
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
    /// Non-nil puts the preview in plate mode: handles are drawn, pinch and pan
    /// are enabled, and taps stop being read as "the ball is here".
    var plateMarkers: PlateMarkerPair?
    /// Which handle moved (0 = start, 1 = end) and where to, clamped to 0...1.
    var onPlateMarkerMoved: ((Int, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.controller = controller
        view.onTap = onTap
        view.onPlateMarkerMoved = onPlateMarkerMoved
        view.skeleton = skeleton
        view.plateMarkers = plateMarkers
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
        view.onPlateMarkerMoved = onPlateMarkerMoved
        view.skeleton = skeleton
        view.plateMarkers = plateMarkers
        // A connection that has gone away is a condition that can actually
        // become true, unlike the old identity check against a `let` session.
        if view.videoPreviewLayer.connection == nil {
            controller.attachPreview(view.videoPreviewLayer)
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        // Leaving a transform on the way out would hand the next attach a
        // preview that is already zoomed into a corner of a picture nobody
        // asked to zoom.
        view.resetZoom()
        view.controller?.detachPreview()
    }

    // MARK: - Container

    /// Owns the touches and the zoom. Never transformed itself.
    final class PreviewView: UIView, UIGestureRecognizerDelegate {
        weak var controller: CaptureController?
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onPlateMarkerMoved: ((Int, CGPoint) -> Void)?

        var skeleton: [PoseJoint: CGPoint]? {
            didSet { inner.skeleton = skeleton }
        }

        var plateMarkers: PlateMarkerPair? {
            didSet {
                guard plateMarkers != oldValue else { return }
                let enabled = plateMarkers != nil
                pinch.isEnabled = enabled
                pan.isEnabled = enabled
                // A write that lands mid-drag is the round trip of the drag
                // itself, one SwiftUI update behind the finger. Applying it
                // would snap the handle backwards.
                if case .handle = panMode { return }
                inner.plateMarkers = plateMarkers
                if !enabled { resetZoom() }
            }
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer { inner.videoPreviewLayer }

        private let inner = PreviewLayerView()
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))

        /// What the current pan is doing. A pan that starts on neither a handle
        /// nor a zoomed picture does nothing at all, rather than being cancelled
        /// — `UIGestureRecognizer.state` is not settable from outside a
        /// subclass, and toggling `isEnabled` to force a cancel drops the
        /// recogniser's own state on the floor.
        private enum PanMode { case idle, handle(Int), canvas }
        private var panMode: PanMode = .idle
        private var lastMarkerReport: CFTimeInterval = 0

        private var zoomScale: CGFloat = 1
        private var zoomOffset: CGPoint = .zero
        private var pinchStartScale: CGFloat = 1
        private var pinchAnchor: CGPoint = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            addSubview(inner)
            // UIKit recognizers rather than SwiftUI gestures: the handlers need
            // the layer itself to convert touches into camera coordinates, and
            // SwiftUI never sees the layer.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(tap)
            pinch.delegate = self
            pan.delegate = self
            pinch.isEnabled = false
            pan.isEnabled = false
            addGestureRecognizer(pinch)
            addGestureRecognizer(pan)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // `bounds` and `center`, never `frame`: a view's frame is undefined
            // while its transform is not the identity, and this one's is.
            inner.transform = .identity
            inner.bounds = CGRect(origin: .zero, size: bounds.size)
            inner.center = CGPoint(x: bounds.midX, y: bounds.midY)
            clampOffset()
            applyZoom()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, videoPreviewLayer.connection == nil {
                controller?.attachPreview(videoPreviewLayer)
            }
        }

        /// Pinch and pan have to run together, or laying a marker accurately
        /// means zooming, letting go, panning, letting go, and dragging.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Zoom

        func resetZoom() {
            zoomScale = 1
            zoomOffset = .zero
            applyZoom()
        }

        /// Keep the scaled inner view covering the container, so no gap ever
        /// shows at an edge.
        private func clampOffset() {
            let maxX = (zoomScale - 1) * bounds.width / 2
            let maxY = (zoomScale - 1) * bounds.height / 2
            zoomOffset.x = min(max(zoomOffset.x, -maxX), maxX)
            zoomOffset.y = min(max(zoomOffset.y, -maxY), maxY)
        }

        private func applyZoom() {
            inner.transform = CGAffineTransform(translationX: zoomOffset.x, y: zoomOffset.y)
                .scaledBy(x: zoomScale, y: zoomScale)
            inner.zoomScale = zoomScale
        }

        // MARK: Touches

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            // In plate mode the picture is being marked, not measured.
            guard plateMarkers == nil, let onTap else { return }
            // `location(in: inner)` is what undoes the zoom transform; the layer
            // conversion then does the fill crop, the rotation and the mirroring.
            let devicePoint = videoPreviewLayer
                .captureDevicePointConverted(fromLayerPoint: gesture.location(in: inner))
            onTap(devicePoint, gesture.location(in: self))
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                if let index = nearestHandle(to: gesture.location(in: inner)) {
                    panMode = .handle(index)
                } else if zoomScale > 1 {
                    panMode = .canvas
                } else {
                    panMode = .idle
                }
            case .changed:
                switch panMode {
                case .handle(let index):
                    moveHandle(index, to: gesture.location(in: inner), report: throttleReport())
                case .canvas:
                    let delta = gesture.translation(in: self)
                    zoomOffset.x += delta.x
                    zoomOffset.y += delta.y
                    gesture.setTranslation(.zero, in: self)
                    clampOffset()
                    applyZoom()
                case .idle:
                    break
                }
            case .ended, .cancelled, .failed:
                if case .handle(let index) = panMode {
                    moveHandle(index, to: gesture.location(in: inner), report: true)
                }
                panMode = .idle
            default:
                break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStartScale = zoomScale
                pinchAnchor = gesture.location(in: inner)
            case .changed:
                let scale = min(max(pinchStartScale * gesture.scale, 1), 4)
                // An inner point `a` lands at `c + s·(a − c) + offset`, so
                // holding the fingers over the same piece of picture means
                // solving that for the offset at the anchor.
                let here = gesture.location(in: self)
                zoomScale = scale
                zoomOffset = CGPoint(x: here.x - bounds.midX - scale * (pinchAnchor.x - bounds.midX),
                                     y: here.y - bounds.midY - scale * (pinchAnchor.y - bounds.midY))
                clampOffset()
                applyZoom()
            default:
                break
            }
        }

        /// True at most ten times a second. The wizard recomputes the scale on
        /// every marker move, and a 60 Hz drag does not need 60 recomputes.
        private func throttleReport() -> Bool {
            let now = CACurrentMediaTime()
            guard now - lastMarkerReport >= 0.1 else { return false }
            lastMarkerReport = now
            return true
        }

        private func nearestHandle(to point: CGPoint) -> Int? {
            guard let markers = inner.plateMarkers else { return nil }
            let a = videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: markers.start)
            let b = videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: markers.end)
            // In inner coordinates, so the touch target stays the same size on
            // screen however far the picture is zoomed in.
            let tolerance = 24 / zoomScale
            let da = hypot(point.x - a.x, point.y - a.y)
            let db = hypot(point.x - b.x, point.y - b.y)
            if da <= tolerance, da <= db { return 0 }
            if db <= tolerance { return 1 }
            return nil
        }

        private func moveHandle(_ index: Int, to layerPoint: CGPoint, report: Bool) {
            guard var markers = inner.plateMarkers else { return }
            var device = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            device.x = min(max(device.x, 0), 1)
            device.y = min(max(device.y, 0), 1)
            if index == 0 { markers.start = device } else { markers.end = device }
            // Drawn immediately, reported on a throttle: the handle must track
            // the finger even on the frames the wizard is not being told about.
            inner.plateMarkers = markers
            if report { onPlateMarkerMoved?(index, device) }
        }
    }

    // MARK: - The layer

    /// The view whose backing layer IS the preview layer. Transformed by its
    /// container; never laid out by SwiftUI directly.
    final class PreviewLayerView: UIView {

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        var skeleton: [PoseJoint: CGPoint]? {
            didSet { redrawSkeleton() }
        }

        var plateMarkers: PlateMarkerPair? {
            didSet { redrawPlate() }
        }

        /// The container's display zoom. Strokes are divided by it so they stay
        /// the same thickness on screen — a 2 pt line drawn at 4x is a slab,
        /// and a marker you cannot see past is a marker you cannot place.
        var zoomScale: CGFloat = 1 {
            didSet {
                guard zoomScale != oldValue else { return }
                redrawPlate()
            }
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

        private let plateLineLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = Theme.yellowUI.cgColor
            l.lineWidth = 2
            return l
        }()

        private let plateHandleLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = Theme.yellowUI.withAlphaComponent(0.25).cgColor
            l.strokeColor = Theme.yellowUI.cgColor
            l.lineWidth = 3
            return l
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(skeletonLayer)
            layer.addSublayer(jointLayer)
            layer.addSublayer(plateLineLayer)
            layer.addSublayer(plateHandleLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            skeletonLayer.frame = bounds
            jointLayer.frame = bounds
            plateLineLayer.frame = bounds
            plateHandleLayer.frame = bounds
            redrawSkeleton()
            redrawPlate()
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

        private func redrawPlate() {
            guard let plateMarkers, bounds.width > 1 else {
                plateLineLayer.path = nil
                plateHandleLayer.path = nil
                return
            }
            let a = videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: plateMarkers.start)
            let b = videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: plateMarkers.end)
            let line = CGMutablePath()
            line.move(to: a)
            line.addLine(to: b)
            let r = 14 / zoomScale
            let handles = CGMutablePath()
            handles.addEllipse(in: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2))
            handles.addEllipse(in: CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plateLineLayer.lineWidth = 2 / zoomScale
            plateLineLayer.lineDashPattern = [NSNumber(value: Double(6 / zoomScale)),
                                              NSNumber(value: Double(4 / zoomScale))]
            plateHandleLayer.lineWidth = 3 / zoomScale
            plateLineLayer.path = line
            plateHandleLayer.path = handles
            CATransaction.commit()
        }
    }
}
