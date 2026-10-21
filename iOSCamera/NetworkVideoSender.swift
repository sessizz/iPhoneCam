import Foundation
import Network
import UIKit

final class NetworkVideoSender: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onStatsChanged: ((String) -> Void)?
    var onControlCommand: ((CameraControlPayload) -> Void)?
    var onInterfaceChanged: ((String, Bool) -> Void)?
    var onRequestKeyFrame: (() -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.network.sender")
    private var connection: NWConnection?
    private var ready = false
    private var latestFormat: H264Format?
    private var sentFrames = 0
    private var sentBytes = 0
    private var lastStatsDate = Date()
    private var connectionAttemptId = UUID()
    private var receivingControlMessages = false
    private var targetEndpoint: NWEndpoint?
    private var usbListener: NWListener?
    private var usbConnection: NWConnection?
    private var isUSBConnected = false
    private var usbFramer = TCPPacketFramer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var deviceName: String = DeviceIdentity.displayName

    func updateDeviceName(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceName = name
            self.sendHelloIfReady()
        }
    }

    func startUSBServer() {
        queue.async { [weak self] in
            guard let self, self.usbListener == nil else { return }
            do {
                let tcpParams = NWParameters.tcp
                tcpParams.allowLocalEndpointReuse = true
                guard let port = NWEndpoint.Port(rawValue: CameraProtocol.usbMuxPort) else { return }
                let listener = try NWListener(using: tcpParams, on: port)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        print("[USBMux] Listener ready on port \(port)")
                    case .failed(let err):
                        print("[USBMux] Listener failed: \(err)")
                    case .waiting(let err):
                        print("[USBMux] Listener waiting: \(err)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.acceptUSBConnection(connection)
                }
                self.usbListener = listener
                listener.start(queue: self.queue)
            } catch {
                print("[USBMux] Listener start failed: \(error)")
            }
        }
    }

    func stopUSBServer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.usbConnection?.cancel()
            self.usbConnection = nil
            self.isUSBConnected = false
            self.usbListener?.cancel()
            self.usbListener = nil
        }
    }

    func connect(to endpoint: NWEndpoint, force: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if !force, self.connection?.endpoint.debugDescription == endpoint.debugDescription {
                return
            }
            self.targetEndpoint = endpoint
            self.ready = false
            let attemptId = UUID()
            self.connectionAttemptId = attemptId
            self.connection?.cancel()
            self.receivingControlMessages = false

            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            parameters.serviceClass = .interactiveVideo
            if let udpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolUDP.Options {
                udpOptions.preferNoChecksum = true
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.pathUpdateHandler = { [weak self] path in
                self?.handlePathUpdate(path)
            }
            connection.start(queue: self.queue)
            self.onStatusChanged?("Connecting to \(endpoint.debugDescription)")
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.connectionAttemptId == attemptId, !self.ready, !self.isUSBConnected else {
                    return
                }
                self.onStatusChanged?("Still connecting. Check Mac app, firewall, Wi-Fi or USB cable.")
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
            guard let self, self.ready || self.isUSBConnected else {
                return
            }
            if let format = sample.format {
                self.latestFormat = format
                self.sendFormatIfReady(format)
            }
            self.sendFrame(sample)
        }
    }

    func sendAudio(_ sample: EncodedAudioSample) {
        queue.async { [weak self] in
            guard let self, self.ready || self.isUSBConnected else {
                return
            }
            let packet = CameraPacket(
                kind: .audio,
                streamId: CameraProtocol.streamId,
                ptsNanos: sample.ptsNanos,
                payload: sample.data
            )
            self.sendPacket(packet)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.ready = false
            self?.receivingControlMessages = false
            self?.sentFrames = 0
            self?.sentBytes = 0
            self?.lastStatsDate = Date()
        }
    }

    private func acceptUSBConnection(_ connection: NWConnection) {
        usbConnection?.cancel()
        usbConnection = connection
        usbFramer.reset()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isUSBConnected = true
                self.onInterfaceChanged?("USB (Direct Cable)", true)
                self.onStatusChanged?("Connected to Mac via USB Cable")
                self.sendHelloIfReady()
                if let format = self.latestFormat {
                    self.sendFormatIfReady(format)
                }
                self.onRequestKeyFrame?()
                self.receiveUSBControlMessages(on: connection)
            case .failed, .cancelled:
                if self.usbConnection === connection {
                    self.isUSBConnected = false
                    self.usbConnection = nil
                    if let path = self.connection?.currentPath {
                        self.handlePathUpdate(path)
                    } else {
                        self.onInterfaceChanged?("Wi-Fi", false)
                    }
                    self.sendHelloIfReady()
                    if let format = self.latestFormat {
                        self.sendFormatIfReady(format)
                    }
                    self.onRequestKeyFrame?()
                }
            default:
                break
            }
        }
        connection.start(queue: self.queue)
    }

    private func receiveUSBControlMessages(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.usbConnection === connection else { return }
            if let data, !data.isEmpty {
                self.usbFramer.append(data)
                while let packet = self.usbFramer.nextPacket() {
                    if packet.kind == .control, let command = try? self.decoder.decode(CameraControlPayload.self, from: packet.payload) {
                        if command.action == .requestKeyFrame {
                            if let format = self.latestFormat {
                                self.sendFormatIfReady(format)
                            }
                            self.onRequestKeyFrame?()
                        } else {
                            self.onControlCommand?(command)
                        }
                    }
                }
            }
            if !isComplete && error == nil {
                self.receiveUSBControlMessages(on: connection)
            }
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            if !isUSBConnected {
                onStatusChanged?("Connected to Mac")
            }
            if let path = connection?.currentPath {
                handlePathUpdate(path)
            }
            if let connection, !receivingControlMessages {
                receivingControlMessages = true
                receiveControlMessages(on: connection)
            }
            sendHelloIfReady()
            if let latestFormat {
                sendFormatIfReady(latestFormat)
            }
        case .failed(let error):
            ready = false
            receivingControlMessages = false
            if !isUSBConnected {
                onStatusChanged?("Connection failed: \(error.localizedDescription)")
            }
        case .waiting(let error):
            ready = false
            if !isUSBConnected {
                onStatusChanged?("Connection waiting: \(error.localizedDescription)")
            }
        case .cancelled:
            ready = false
            receivingControlMessages = false
            if !isUSBConnected {
                onStatusChanged?("Disconnected")
            }
        default:
            break
        }
    }

    private func receiveControlMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection else {
                return
            }

            if
                let data,
                let packet = CameraPacket(data: data),
                packet.kind == .control,
                let command = try? self.decoder.decode(CameraControlPayload.self, from: packet.payload)
            {
                if command.action == .requestKeyFrame {
                    if let format = self.latestFormat {
                        self.sendFormatIfReady(format)
                    }
                    self.onRequestKeyFrame?()
                } else {
                    self.onControlCommand?(command)
                }
            }

            if error == nil {
                self.receiveControlMessages(on: connection)
            } else {
                self.receivingControlMessages = false
            }
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        if isUSBConnected {
            onInterfaceChanged?("USB (Direct Cable)", true)
            return
        }

        var isWired = false
        if !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.cellular) {
            if path.usesInterfaceType(.wiredEthernet) {
                isWired = true
            } else {
                isWired = path.availableInterfaces.contains { iface in
                    iface.type == .wiredEthernet ||
                    iface.name.lowercased().contains("usb") ||
                    (iface.name.lowercased().hasPrefix("en") && iface.name != "en0")
                }
            }
        }

        let description: String
        if isWired {
            description = "USB (High-Speed Cable)"
        } else if path.usesInterfaceType(.wifi) {
            description = "Wi-Fi"
        } else if path.usesInterfaceType(.cellular) {
            description = "Cellular"
        } else {
            description = "P2P Direct"
        }

        onInterfaceChanged?(description, isWired)
    }

    private func sendHelloIfReady() {
        guard ready || isUSBConnected else { return }
        let payload = HelloPayload(
            deviceName: deviceName,
            codec: latestFormat?.codec ?? CameraProtocol.defaultCodec,
            width: latestFormat?.width ?? CameraProtocol.targetWidth,
            height: latestFormat?.height ?? CameraProtocol.targetHeight,
            fps: latestFormat?.fps ?? CameraProtocol.targetFPS,
            bitrate: latestFormat?.bitrate ?? CameraProtocol.targetBitrate
        )
        guard let data = try? encoder.encode(payload) else { return }
        let packet = CameraPacket(kind: .hello, streamId: CameraProtocol.streamId, payload: data)
        sendPacket(packet)
    }

    private func sendFormatIfReady(_ format: H264Format) {
        guard ready || isUSBConnected, let data = try? encoder.encode(format.payload) else {
            return
        }
        let packet = CameraPacket(kind: .format, streamId: CameraProtocol.streamId, payload: data)
        sendPacket(packet)
    }

    private func sendFrame(_ sample: EncodedH264Sample) {
        let maxPayloadSize = CameraPacket.maxPayloadSize
        let packetCount = max(1, Int(ceil(Double(sample.data.count) / Double(maxPayloadSize))))
        guard packetCount <= Int(UInt16.max) else {
            return
        }

        let sendFragments = {
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
                self.sendPacket(packet)
            }
        }

        if isUSBConnected, let usb = usbConnection {
            usb.batch {
                sendFragments()
            }
        } else if ready, let _ = connection {
            sendFragments()
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

    private func sendPacket(_ packet: CameraPacket) {
        if isUSBConnected, let usb = usbConnection {
            let framed = packet.framedForTCP()
            usb.send(content: framed, completion: .contentProcessed { _ in })
        } else if ready, let udp = connection {
            let encoded = packet.encoded()
            udp.send(content: encoded, completion: .contentProcessed { _ in })
        }
    }
}
