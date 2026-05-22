import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.configure(session: session, rotationAngle: rotationAngle)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.configure(session: session, rotationAngle: rotationAngle)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    private var pendingRotationAngle: CGFloat = 0
    private var rotationRetryWorkItem: DispatchWorkItem?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPendingRotation(retryIfNeeded: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPendingRotation(retryIfNeeded: true)
    }

    func configure(session: AVCaptureSession, rotationAngle: CGFloat) {
        if previewLayer.session !== session {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspect
            previewLayer.backgroundColor = UIColor.black.cgColor
        }

        pendingRotationAngle = rotationAngle
        applyPendingRotation(retryIfNeeded: true)
    }

    private func applyPendingRotation(retryIfNeeded: Bool) {
        guard let connection = previewLayer.connection else {
            if retryIfNeeded {
                scheduleRotationRetry()
            }
            return
        }

        rotationRetryWorkItem?.cancel()
        rotationRetryWorkItem = nil

        guard connection.isVideoRotationAngleSupported(pendingRotationAngle) else {
            return
        }
        connection.videoRotationAngle = pendingRotationAngle
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func scheduleRotationRetry() {
        guard window != nil, rotationRetryWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.rotationRetryWorkItem = nil
            self?.applyPendingRotation(retryIfNeeded: true)
        }
        rotationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }
}
