import Foundation
import Network

final class UDPReceiver: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onPacket: ((CameraPacket) -> Void)?
    var onInterfaceChanged: ((_ interfaceDescription: String, _ isWired: Bool) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.udp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeoutTimer: DispatchSourceTimer?
    private var hasActiveSender = false
    private var activeConnectionId: ObjectIdentifier?
    private var lastPacketAt: Date?
    private var targetDeviceName: String = ""

    func setTargetDevice(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targetDeviceName = (name == "Auto" ? "" : name)
            self.updateBonjourService()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let parameters = NWParameters.udp
                parameters.includePeerToPeer = true
                parameters.serviceClass = .interactiveVideo
                let listener = try NWListener(using: parameters, on: 0)
                let target = self.targetDeviceName.isEmpty ? "*" : self.targetDeviceName
                var txtDict: [String: Data] = [:]
                if let targetData = target.data(using: .utf8) {
                    txtDict["target"] = targetData
                }
                let txtRecordData = NetService.data(fromTXTRecord: txtDict)
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "iPhoneCam Mac",
                    type: CameraProtocol.serviceType,
                    txtRecord: txtRecordData
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

    private func updateBonjourService() {
        guard let listener else { return }
        let target = targetDeviceName.isEmpty ? "*" : targetDeviceName
        var txtDict: [String: Data] = [:]
        if let targetData = target.data(using: .utf8) {
            txtDict["target"] = targetData
        }
        let txtRecordData = NetService.data(fromTXTRecord: txtDict)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "iPhoneCam Mac",
            type: CameraProtocol.serviceType,
            txtRecord: txtRecordData
        )
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
            self?.activeConnectionId = nil
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

    func sendControlCommand(_ command: CameraControlPayload) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let payload = try? JSONEncoder().encode(command) else { return }
            let packet = CameraPacket(kind: .control, streamId: CameraProtocol.streamId, payload: payload)
            let data = packet.encoded()
            if let activeId = self.activeConnectionId, let conn = self.connections[activeId] {
                conn.send(content: data, completion: .contentProcessed({ _ in }))
            } else {
                for conn in self.connections.values {
                    conn.send(content: data, completion: .contentProcessed({ _ in }))
                }
            }
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

    private func isWiredUSBConnection(_ connection: NWConnection) -> Bool {
        if let path = connection.currentPath {
            if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular) {
                return false
            }
            if path.usesInterfaceType(.wiredEthernet) {
                return true
            }
            let hasUSBInterface = path.availableInterfaces.contains { iface in
                iface.type == .wiredEthernet ||
                iface.name.lowercased().contains("usb") ||
                (iface.name.lowercased().hasPrefix("en") && iface.name != "en0")
            }
            if hasUSBInterface {
                return true
            }
        }
        return false
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            let id = ObjectIdentifier(connection)

            if let data, let packet = CameraPacket(data: data) {
                let now = Date()
                if self.activeConnectionId == nil || self.activeConnectionId == id {
                    let wasInactive = !self.hasActiveSender
                    self.activeConnectionId = id
                    self.hasActiveSender = true
                    self.lastPacketAt = now
                    if wasInactive {
                        let isWired = self.isWiredUSBConnection(connection)
                        self.onInterfaceChanged?(isWired ? "USB (High-Speed Cable)" : "Wi-Fi", isWired)
                    }
                    self.onPacket?(packet)
                } else if let last = self.lastPacketAt, now.timeIntervalSince(last) > 1.5 {
                    self.activeConnectionId = id
                    self.hasActiveSender = true
                    self.lastPacketAt = now
                    let isWired = self.isWiredUSBConnection(connection)
                    self.onInterfaceChanged?(isWired ? "USB (High-Speed Cable)" : "Wi-Fi", isWired)
                    self.onPacket?(packet)
                }
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
        activeConnectionId = nil
        self.lastPacketAt = nil
        onStatusChanged?("Waiting for iPhone")
    }
}

// MARK: - USBMuxReceiver (Direct USB Cable Receiver via /var/run/usbmuxd)
final class USBMuxReceiver: @unchecked Sendable {
    struct AttachedDevice {
        let deviceID: Int
        let serialNumber: String
        var deviceName: String?
    }

    var onPacket: ((CameraPacket) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onConnectedChanged: ((Bool) -> Void)?
    var onDiscoveredDevicesChanged: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.usbmux", qos: .userInteractive)
    private var isRunning = false
    private var listenFd: Int32 = -1
    private var streamFd: Int32 = -1
    private var framer = TCPPacketFramer()
    private var attachedDevices: [Int: AttachedDevice] = [:]
    private var activeDeviceID: Int?
    private var targetDeviceName: String = ""

    func setTargetDevice(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let cleaned = (name == "Auto" ? "" : name)
            guard self.targetDeviceName != cleaned else { return }
            self.targetDeviceName = cleaned
            self.reevaluateActiveConnection()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startListeningLoop()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.closeStream()
            self.closeListen()
            self.activeDeviceID = nil
            self.attachedDevices.removeAll()
        }
    }

    func sendControlCommand(_ command: CameraControlPayload) {
        queue.async { [weak self] in
            guard let self, self.streamFd >= 0 else { return }
            guard let payload = try? JSONEncoder().encode(command) else { return }
            let packet = CameraPacket(kind: .control, streamId: CameraProtocol.streamId, payload: payload)
            let framed = packet.framedForTCP()
            framed.withUnsafeBytes { raw in
                _ = Darwin.send(self.streamFd, raw.baseAddress!, raw.count, 0)
            }
        }
    }

    private var isSandboxRestricted = false

    private func connectToUsbmuxd() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        let pathLen = path.utf8.count
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cstr in
                ptr.initialize(from: cstr, count: pathLen + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathLen + 1)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        guard res == 0 else {
            let err = errno
            close(fd)
            if err == EPERM || err == EACCES {
                if !isSandboxRestricted {
                    isSandboxRestricted = true
                    print("[USBMux] /var/run/usbmuxd is unavailable under macOS App Sandbox. Direct USB cable streaming will operate via peer-to-peer USB Ethernet.")
                }
            }
            return nil
        }
        return fd
    }

    private func sendPlist(_ dict: [String: Any], on fd: Int32, tag: UInt32 = 1) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return false
        }
        let totalLen = UInt32(16 + data.count)
        var header = Data()
        var lenLE = totalLen.littleEndian
        var verLE = UInt32(1).littleEndian
        var msgLE = UInt32(8).littleEndian // MESSAGE_PLIST
        var tagLE = tag.littleEndian
        Swift.withUnsafeBytes(of: &lenLE) { header.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &verLE) { header.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &msgLE) { header.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &tagLE) { header.append(contentsOf: $0) }
        header.append(data)

        return header.withUnsafeBytes { raw in
            Darwin.send(fd, raw.baseAddress!, raw.count, 0) == raw.count
        }
    }

    private func readPlist(from fd: Int32) -> [String: Any]? {
        var hdrBuf = [UInt8](repeating: 0, count: 16)
        var totalRead = 0
        while totalRead < 16 {
            let n = Darwin.recv(fd, &hdrBuf[totalRead], 16 - totalRead, 0)
            if n <= 0 { return nil }
            totalRead += n
        }
        let totalLen = Int(UInt32(hdrBuf[0]) | (UInt32(hdrBuf[1]) << 8) | (UInt32(hdrBuf[2]) << 16) | (UInt32(hdrBuf[3]) << 24))
        guard totalLen >= 16 else { return nil }
        let payloadLen = totalLen - 16
        if payloadLen == 0 { return [:] }

        var payloadBuf = [UInt8](repeating: 0, count: payloadLen)
        var payloadRead = 0
        while payloadRead < payloadLen {
            let n = Darwin.recv(fd, &payloadBuf[payloadRead], payloadLen - payloadRead, 0)
            if n <= 0 { return nil }
            payloadRead += n
        }
        let data = Data(payloadBuf)
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    private func startListeningLoop() {
        guard let lfd = connectToUsbmuxd() else {
            if isSandboxRestricted {
                return
            }
            queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRunning else { return }
                self.startListeningLoop()
            }
            return
        }
        self.listenFd = lfd

        let listenMsg: [String: Any] = [
            "MessageType": "Listen",
            "ClientVersionString": "iPhoneCam",
            "ProgName": "iPhoneCam"
        ]
        guard sendPlist(listenMsg, on: lfd) else {
            closeListen()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let self, self.isRunning && self.listenFd == lfd {
                guard let plist = self.readPlist(from: lfd) else { break }
                self.handleListenPlist(plist)
            }
            self?.queue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.closeListen()
                self.startListeningLoop()
            }
        }
    }

    private func handleListenPlist(_ plist: [String: Any]) {
        guard let msgType = plist["MessageType"] as? String else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if msgType == "Attached", let devID = plist["DeviceID"] as? Int {
                if let props = plist["Properties"] as? [String: Any],
                   let connType = props["ConnectionType"] as? String,
                   connType == "USB" {
                    let serial = props["SerialNumber"] as? String ?? ""
                    self.attachedDevices[devID] = AttachedDevice(deviceID: devID, serialNumber: serial, deviceName: nil)
                    self.notifyDiscoveredDevices()
                    if self.activeDeviceID == nil {
                        self.reevaluateActiveConnection()
                    }
                }
            } else if msgType == "Detached", let devID = plist["DeviceID"] as? Int {
                self.attachedDevices.removeValue(forKey: devID)
                self.notifyDiscoveredDevices()
                if self.activeDeviceID == devID {
                    self.activeDeviceID = nil
                    self.closeStream()
                    self.onConnectedChanged?(false)
                    self.reevaluateActiveConnection()
                }
            }
        }
    }

    private func reevaluateActiveConnection() {
        guard isRunning else { return }

        // If current active stream doesn't match target, disconnect
        if let activeID = activeDeviceID, let dev = attachedDevices[activeID] {
            if !targetDeviceName.isEmpty, let devName = dev.deviceName, devName != targetDeviceName {
                closeStream()
                activeDeviceID = nil
                onConnectedChanged?(false)
            } else if targetDeviceName.isEmpty || dev.deviceName == targetDeviceName {
                return
            }
        }

        // Search for a matching attached device
        if !targetDeviceName.isEmpty {
            if let matchID = attachedDevices.first(where: { $0.value.deviceName == targetDeviceName })?.key {
                tryConnectToDevice(matchID)
            } else if activeDeviceID == nil {
                // If we haven't discovered all device names yet, connect to the unknown ones to identify them
                if let unknownID = attachedDevices.first(where: { $0.value.deviceName == nil })?.key {
                    tryConnectToDevice(unknownID)
                }
            }
        } else {
            // Auto mode: connect to first attached device
            if activeDeviceID == nil, let firstID = attachedDevices.keys.first {
                tryConnectToDevice(firstID)
            }
        }
    }

    private func notifyDiscoveredDevices() {
        let names = attachedDevices.values.compactMap { $0.deviceName }.filter { !$0.isEmpty }
        onDiscoveredDevicesChanged?(Array(Set(names)).sorted())
    }

    private func tryConnectToDevice(_ devID: Int) {
        guard isRunning else { return }
        closeStream()

        guard let cfd = connectToUsbmuxd() else {
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.attachedDevices[devID] != nil else { return }
                self.reevaluateActiveConnection()
            }
            return
        }

        let portInt = Int(UInt16(CameraProtocol.usbMuxPort).bigEndian)
        let connectMsg: [String: Any] = [
            "MessageType": "Connect",
            "ClientVersionString": "iPhoneCam",
            "ProgName": "iPhoneCam",
            "DeviceID": devID,
            "PortNumber": portInt
        ]

        guard sendPlist(connectMsg, on: cfd) else {
            close(cfd)
            return
        }

        guard let resp = readPlist(from: cfd),
              let result = resp["Number"] as? Int else {
            close(cfd)
            return
        }

        if result != 0 {
            close(cfd)
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.attachedDevices[devID] != nil else { return }
                self.reevaluateActiveConnection()
            }
            return
        }

        self.streamFd = cfd
        self.activeDeviceID = devID
        self.framer.reset()
        self.onConnectedChanged?(true)
        let displayName = self.attachedDevices[devID]?.deviceName ?? "iPhone"
        self.onStatusChanged?("Connected to \(displayName) via USB Cable")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.readStreamLoop(cfd, devID: devID)
        }
    }

    private func readStreamLoop(_ fd: Int32, devID: Int) {
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while isRunning && streamFd == fd {
            let n = Darwin.recv(fd, &buffer, bufferSize, 0)
            if n <= 0 {
                break
            }
            let chunk = Data(bytes: buffer, count: n)
            queue.async { [weak self] in
                guard let self, self.streamFd == fd else { return }
                self.framer.append(chunk)
                while let packet = self.framer.nextPacket() {
                    if packet.kind == .hello, let hello = try? JSONDecoder().decode(HelloPayload.self, from: packet.payload) {
                        self.attachedDevices[devID]?.deviceName = hello.deviceName
                        self.notifyDiscoveredDevices()
                        if !self.targetDeviceName.isEmpty && hello.deviceName != self.targetDeviceName {
                            self.closeStream()
                            self.activeDeviceID = nil
                            self.onConnectedChanged?(false)
                            self.reevaluateActiveConnection()
                            return
                        }
                    }
                    self.onPacket?(packet)
                }
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            if self.streamFd == fd {
                self.closeStream()
                self.onConnectedChanged?(false)
                if self.activeDeviceID == devID {
                    self.activeDeviceID = nil
                    self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.isRunning else { return }
                        self.reevaluateActiveConnection()
                    }
                }
            }
        }
    }

    private func closeListen() {
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
    }

    private func closeStream() {
        if streamFd >= 0 {
            close(streamFd)
            streamFd = -1
        }
    }
}
