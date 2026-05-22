import AVFoundation
import Foundation

@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published var statusText = "Waiting for iPhone"
    @Published var formatText = "No stream"
    @Published var statsText = "0 frames, 0 dropped"
    @Published var waitingForKeyFrame = true

    let renderer = VideoRenderer()

    private let receiver = UDPReceiver()
    private let packetProcessor = ReceiverPacketProcessor()
    private var sampleBuilder: H264SampleBuilder?
    private var displayedFrames = 0
    private var droppedFrames = 0
    private var displayDroppedFrames = 0
    private var lastStatsDate = Date()
    private var framesSinceStats = 0
    private var started = false

    func start() {
        guard !started else {
            return
        }
        started = true

        receiver.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }
        receiver.onPacket = { [weak self] packet in
            self?.packetProcessor.accept(packet)
        }
        packetProcessor.onHello = { [weak self] hello in
            Task { @MainActor in
                self?.handle(hello)
            }
        }
        packetProcessor.onFormat = { [weak self] format in
            Task { @MainActor in
                self?.handle(format)
            }
        }
        packetProcessor.onFrame = { [weak self] frame, droppedFrames in
            Task { @MainActor in
                self?.handle(frame, droppedFrames: droppedFrames)
            }
        }
        receiver.start()
    }

    func stop() {
        receiver.stop()
        packetProcessor.reset()
        renderer.reset()
        started = false
    }

    private func handle(_ hello: HelloPayload) {
        statusText = "Connected: \(hello.deviceName)"
        formatText = "\(hello.width)x\(hello.height) @ \(hello.fps) FPS, \(hello.bitrate / 1_000_000) Mbps"
    }

    private func handle(_ format: FormatPayload) {
        do {
            sampleBuilder = try H264SampleBuilder(format: format)
            waitingForKeyFrame = true
            formatText = "\(format.width)x\(format.height) @ \(format.fps) FPS, \(format.bitrate / 1_000_000) Mbps"
        } catch {
            statusText = "Format error: \(error.localizedDescription)"
        }
    }

    private func handle(_ frame: EncodedVideoFrame, droppedFrames: Int) {
        self.droppedFrames = droppedFrames
        guard let sampleBuilder else {
            waitingForKeyFrame = true
            updateStats()
            return
        }
        if waitingForKeyFrame && !frame.isKeyFrame {
            updateStats()
            return
        }
        waitingForKeyFrame = false
        do {
            let sampleBuffer = try sampleBuilder.makeSampleBuffer(from: frame)
            if renderer.enqueue(sampleBuffer) {
                displayedFrames += 1
                framesSinceStats += 1
            } else {
                displayDroppedFrames += 1
            }
            updateStats()
        } catch {
            statusText = "Decode sample error: \(error.localizedDescription)"
            waitingForKeyFrame = true
        }
    }

    private func updateStats() {
        let now = Date()
        guard now.timeIntervalSince(lastStatsDate) >= 1 else {
            return
        }
        let fps = Double(framesSinceStats) / now.timeIntervalSince(lastStatsDate)
        statsText = String(
            format: "%d frames, %.1f FPS, %d net dropped, %d display dropped",
            displayedFrames,
            fps,
            droppedFrames,
            displayDroppedFrames
        )
        framesSinceStats = 0
        lastStatsDate = now
    }
}
