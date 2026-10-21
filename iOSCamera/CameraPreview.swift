import AVFoundation
import SwiftUI
import UIKit

final class CameraPreviewRenderer: ObservableObject {
    private let lock = NSLock()
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    // The layer is main-actor isolated; its renderer is not, so the capture queue feeds the renderer directly.
    private weak var videoRenderer: AVSampleBufferVideoRenderer?

    @MainActor
    func attach(to displayLayer: AVSampleBufferDisplayLayer) {
        let videoRenderer = displayLayer.sampleBufferRenderer
        lock.lock()
        self.displayLayer = displayLayer
        self.videoRenderer = videoRenderer
        lock.unlock()
    }

    func detach(from displayLayer: AVSampleBufferDisplayLayer) {
        lock.lock()
        if self.displayLayer === displayLayer {
            self.displayLayer = nil
            self.videoRenderer = nil
        }
        lock.unlock()
    }

    func display(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let renderer = videoRenderer
        lock.unlock()

        guard let renderer else {
            return
        }
        if renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else {
            return
        }
        markForImmediateDisplay(sampleBuffer)
        renderer.enqueue(sampleBuffer)
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0,
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary?.self)
        else {
            return
        }
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

struct CameraPreview: UIViewRepresentable {
    let renderer: CameraPreviewRenderer

    func makeUIView(context: Context) -> SampleBufferPreviewView {
        let view = SampleBufferPreviewView()
        view.configure()
        renderer.attach(to: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferPreviewView, context: Context) {
        uiView.configure()
        renderer.attach(to: uiView.displayLayer)
    }

    static func dismantleUIView(_ uiView: SampleBufferPreviewView, coordinator: ()) {
        uiView.flush()
    }
}

final class SampleBufferPreviewView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(displayLayer)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    func configure() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    func flush() {
        displayLayer.flush()
    }
}
