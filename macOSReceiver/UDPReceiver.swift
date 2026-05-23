import Foundation
import Network

final class UDPReceiver: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onPacket: ((CameraPacket) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.udp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeoutTimer: DispatchSourceTimer?
    private var hasActiveSender = false
    private var lastPacketAt: Date?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let listener = try NWListener(using: .udp, on: 0)
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "iPhoneCam Mac",
                    type: CameraProtocol.serviceType
                )
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.onStatusChanged?("Receiver failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.timeoutTimer?.cancel()
            self?.timeoutTimer = nil
            self?.connections.values.forEach { $0.cancel() }
            self?.connections.removeAll()
            self?.hasActiveSender = false
            self?.lastPacketAt = nil
        }
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            startTimeoutTimer()
            if let port = listener?.port {
                onStatusChanged?("Waiting for iPhone on UDP \(port.rawValue)")
            } else {
                onStatusChanged?("Waiting for iPhone")
            }
        case .failed(let error):
            onStatusChanged?("Receiver failed: \(error.localizedDescription)")
        case .waiting(let error):
            onStatusChanged?("Receiver waiting: \(error.localizedDescription)")
        case .cancelled:
            onStatusChanged?("Receiver stopped")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .cancelled = state {
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, let packet = CameraPacket(data: data) {
                self.hasActiveSender = true
                self.lastPacketAt = Date()
                self.onPacket?(packet)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func startTimeoutTimer() {
        timeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkSenderTimeout()
        }
        timeoutTimer = timer
        timer.resume()
    }

    private func checkSenderTimeout() {
        guard hasActiveSender, let lastPacketAt else {
            return
        }
        guard Date().timeIntervalSince(lastPacketAt) > 1.5 else {
            return
        }
        hasActiveSender = false
        self.lastPacketAt = nil
        onStatusChanged?("Waiting for iPhone")
    }
}
