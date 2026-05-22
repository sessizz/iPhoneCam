import Foundation
import Network

final class UDPReceiver: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onPacket: ((CameraPacket) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.udp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

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
            self?.connections.values.forEach { $0.cancel() }
            self?.connections.removeAll()
        }
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
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
                self.onPacket?(packet)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }
}
