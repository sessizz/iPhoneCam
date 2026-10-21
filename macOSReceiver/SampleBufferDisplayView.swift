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

final class VideoRenderer: @unchecked Sendable {
    private let lock = NSLock()
    // The layer is main-actor isolated; its renderer is not, so the render queue feeds the renderer directly.
    private weak var videoRenderer: AVSampleBufferVideoRenderer?

    @MainActor
    func attach(to displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.videoGravity = .resizeAspect
        let videoRenderer = displayLayer.sampleBufferRenderer
        lock.lock()
        defer { lock.unlock() }
        self.videoRenderer = videoRenderer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        let renderer = self.videoRenderer
        lock.unlock()

        guard let renderer else {
            return false
        }
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        renderer.enqueue(sampleBuffer)
        return true
    }

    func reset() {
        lock.lock()
        let renderer = self.videoRenderer
        lock.unlock()
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
