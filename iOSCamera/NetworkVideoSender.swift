import Foundation
import Network
import UIKit

final class NetworkVideoSender: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onStatsChanged: ((String) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.network.sender")
    private var connection: NWConnection?
    private var ready = false
    private var latestFormat: H264Format?
    private var sentFrames = 0
    private var sentBytes = 0
    private var lastStatsDate = Date()
    private var connectionAttemptId = UUID()
    private let encoder = JSONEncoder()

    func connect(to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.connection?.endpoint.debugDescription == endpoint.debugDescription {
                return
            }
            self.ready = false
            let attemptId = UUID()
            self.connectionAttemptId = attemptId
            self.connection?.cancel()
            let connection = NWConnection(to: endpoint, using: .udp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: self.queue)
            self.onStatusChanged?("Connecting to \(endpoint.debugDescription)")
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.connectionAttemptId == attemptId, !self.ready else {
                    return
                }
                self.onStatusChanged?("Still connecting. Check Mac app, firewall, and same Wi-Fi.")
            }
        }
    }

    func updateFormat(_ format: H264Format) {
        queue.async { [weak self] in
            self?.latestFormat = format
            self?.sendHelloIfReady()
            self?.sendFormatIfReady(format)
        }
    }

    func send(_ sample: EncodedH264Sample) {
        queue.async { [weak self] in
            guard let self, self.ready else {
                return
            }
            if let format = sample.format {
                self.latestFormat = format
                self.sendFormatIfReady(format)
            }
            self.sendFrame(sample)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.ready = false
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            onStatusChanged?("Connected to Mac")
            sendHelloIfReady()
            if let latestFormat {
                sendFormatIfReady(latestFormat)
            }
        case .failed(let error):
            ready = false
            onStatusChanged?("Connection failed: \(error.localizedDescription)")
        case .waiting(let error):
            ready = false
            onStatusChanged?("Connection waiting: \(error.localizedDescription)")
        case .cancelled:
            ready = false
            onStatusChanged?("Disconnected")
        default:
            break
        }
    }

    private func sendHelloIfReady() {
        guard ready else { return }
        let payload = HelloPayload(
            deviceName: ProcessInfo.processInfo.hostName,
            codec: CameraProtocol.codecH264AVCC,
            width: latestFormat?.width ?? CameraProtocol.targetWidth,
            height: latestFormat?.height ?? CameraProtocol.targetHeight,
            fps: latestFormat?.fps ?? CameraProtocol.targetFPS,
            bitrate: latestFormat?.bitrate ?? CameraProtocol.targetBitrate
        )
        guard let data = try? encoder.encode(payload) else { return }
        let packet = CameraPacket(kind: .hello, streamId: CameraProtocol.streamId, payload: data)
        sendDatagram(packet.encoded())
    }

    private func sendFormatIfReady(_ format: H264Format) {
        guard ready, let data = try? encoder.encode(format.payload) else {
            return
        }
        let packet = CameraPacket(kind: .format, streamId: CameraProtocol.streamId, payload: data)
        sendDatagram(packet.encoded())
    }

    private func sendFrame(_ sample: EncodedH264Sample) {
        let maxPayloadSize = CameraPacket.maxPayloadSize
        let packetCount = max(1, Int(ceil(Double(sample.data.count) / Double(maxPayloadSize))))
        guard packetCount <= Int(UInt16.max) else {
            return
        }

        for index in 0..<packetCount {
            let start = index * maxPayloadSize
            let end = min(sample.data.count, start + maxPayloadSize)
            let payload = sample.data.subdata(in: start..<end)
            let packet = CameraPacket(
                kind: .frameFragment,
                flags: sample.isKeyFrame ? .keyFrame : [],
                streamId: CameraProtocol.streamId,
                frameId: sample.frameId,
                ptsNanos: sample.ptsNanos,
                packetIndex: UInt16(index),
                packetCount: UInt16(packetCount),
                payload: payload
            )
            sendDatagram(packet.encoded())
        }

        sentFrames += 1
        sentBytes += sample.data.count
        let now = Date()
        if now.timeIntervalSince(lastStatsDate) >= 1 {
            let mbps = Double(sentBytes * 8) / 1_000_000.0 / now.timeIntervalSince(lastStatsDate)
            onStatsChanged?(String(format: "%d frames sent, %.1f Mbps", sentFrames, mbps))
            sentBytes = 0
            lastStatsDate = now
        }
    }

    private func sendDatagram(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
