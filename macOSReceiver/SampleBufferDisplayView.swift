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
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(to displayLayer: AVSampleBufferDisplayLayer) {
        lock.lock()
        defer { lock.unlock() }
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        let layer = self.displayLayer
        lock.unlock()

        guard let layer else {
            return false
        }
        if layer.status == .failed {
            layer.flush()
            return false
        }
        layer.enqueue(sampleBuffer)
        return true
    }

    func reset() {
        lock.lock()
        let layer = self.displayLayer
        lock.unlock()
        layer?.flushAndRemoveImage()
    }
}
