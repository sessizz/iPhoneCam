import AVFoundation
import SwiftUI

struct SampleBufferDisplayView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> SampleBufferNSView {
        let view = SampleBufferNSView()
        renderer.attach(to: view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferNSView, context: Context) {
        renderer.attach(to: nsView.displayLayer)
    }
}

final class SampleBufferNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}

@MainActor
final class VideoRenderer {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(to displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let displayLayer else {
            return false
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else {
            return false
        }
        displayLayer.enqueue(sampleBuffer)
        return true
    }

    func reset() {
        displayLayer?.flushAndRemoveImage()
    }
}
