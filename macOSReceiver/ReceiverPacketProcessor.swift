import Foundation

final class ReceiverPacketProcessor: @unchecked Sendable {
    var onHello: ((HelloPayload) -> Void)?
    var onFormat: ((FormatPayload) -> Void)?
    var onFrame: ((EncodedVideoFrame, Int) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.packet.processor", qos: .userInitiated)
    private let reassembler = FrameReassembler(timeout: 0.12)
    private let decoder = JSONDecoder()

    func accept(_ packet: CameraPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handle(packet)
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.reassembler.reset()
        }
    }

    private func handle(_ packet: CameraPacket) {
        switch packet.kind {
        case .hello:
            if let hello = try? decoder.decode(HelloPayload.self, from: packet.payload) {
                onHello?(hello)
            }
        case .format:
            if let format = try? decoder.decode(FormatPayload.self, from: packet.payload) {
                reassembler.reset()
                onFormat?(format)
            }
        case .frameFragment:
            if let frame = reassembler.accept(packet) {
                onFrame?(frame, reassembler.droppedFrameCount)
            }
        }
    }
}
