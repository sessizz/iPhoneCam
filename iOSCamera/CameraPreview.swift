import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.backgroundColor = UIColor.black.cgColor
        view.apply(rotationAngle: rotationAngle)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.apply(rotationAngle: rotationAngle)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func apply(rotationAngle: CGFloat) {
        guard
            let connection = previewLayer.connection,
            connection.isVideoRotationAngleSupported(rotationAngle)
        else {
            return
        }
        connection.videoRotationAngle = rotationAngle
    }
}
