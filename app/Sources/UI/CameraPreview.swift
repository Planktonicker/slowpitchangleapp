import ARKit
import AVFoundation
import SceneKit
import SwiftUI
import UIKit

/// Live camera preview.
///
/// `.resizeAspect` rather than `.resizeAspectFill`: framing matters here — the
/// protocol asks for the plate about a third in from the edge — and a fill
/// crop would hide part of what is actually being recorded.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.videoPreviewLayer.session !== session {
            view.videoPreviewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = videoPreviewLayer.connection else { return }
            let angle: CGFloat
            switch window?.windowScene?.interfaceOrientation {
            case .landscapeLeft:      angle = 180
            case .landscapeRight:     angle = 0
            case .portraitUpsideDown: angle = 270
            default:                  angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }
}

/// ARKit preview for the distance step of the wizard.
///
/// The sensor owns the `ARSession` and keeps running it; this view only
/// renders it, so moving between wizard steps does not restart tracking.
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        // Feature points make it obvious when there is too little texture for
        // ARKit to lock on, which is the usual cause of a bad distance.
        view.debugOptions = [.showFeaturePoints]
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
    }
}
