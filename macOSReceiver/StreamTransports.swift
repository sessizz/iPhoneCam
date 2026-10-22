import Foundation
import Network

enum ReceiverIdentity {
    static func identify(transport: String) -> CameraControlPayload {
        let host = Host.current().localizedName ?? "Mac"
        return CameraControlPayload(action: .identify, transport: transport, clientName: "iPhoneCam Receiver on \(host)")
    }
}

// MARK: - PhoneConnection (dials the iPhone over the network)

/// Dials the iPhone's stream listener by Bonjour name or IP address and keeps redialing until told to stop.
final class PhoneConnection: @unchecked Sendable {
    enum Target: Equatable {
        case service(String)
        case address(String)

        var description: String {
            switch self {
            case .service(let name):
                return name
            case .address(let address):
                return address
            }
        }
    }

    var onPacket: ((CameraPacket) -> Void)?
    var onStateChanged: ((_ connected: Bool, _ status: String) -> Void)?

    /// The iPhone pings every 2 s, so this much silence means the link is gone even if TCP has not noticed.
    private static let idleTimeout: TimeInterval = 6
    private static let retryDelay: TimeInterval = 1

    private let queue = DispatchQueue(label: "iphonecam.receiver.phone", qos: .userInteractive)
    private var target: Target?
    private var connection: NWConnection?
    private var framer = TCPPacketFramer()
    /// Identifies the current attempt; callbacks from older connections are ignored.
    private var generation = 0
    private var isConnected = false
    private var lastDataAt = Date.distantPast
    private var watchdog: DispatchSourceTimer?

    func connect(to target: Target) {
        queue.async { [weak self] in
            guard let self, self.target != target || self.connection == nil else { return }
            self.target = target
            self.open()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self, self.target != nil else { return }
            self.target = nil
            self.generation += 1
            self.closeConnection()
            self.stopWatchdog()
        }
    }

    func send(_ command: CameraControlPayload) {
        guard let payload = try? JSONEncoder().encode(command) else { return }
        send(CameraPacket(kind: .control, streamId: CameraProtocol.streamId, payload: payload))
    }

    func send(_ packet: CameraPacket) {
        let framed = packet.framedForTCP()
        queue.async { [weak self] in
            guard let self, self.isConnected, let connection = self.connection else { return }
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    private static func endpoint(for target: Target) -> NWEndpoint? {
        switch target {
        case .service(let name):
            return .service(name: name, type: CameraProtocol.phoneServiceType, domain: "local.", interface: nil)
        case .address(let text):
            var host = text.trimmingCharacters(in: .whitespaces)
            var port = CameraProtocol.streamPort
            if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                let rest = host[host.index(after: close)...]
                if rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()) {
                    port = value
                }
                host = String(host[host.index(after: host.startIndex)..<close])
            } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
                guard let value = UInt16(host[host.index(after: colon)...]) else { return nil }
                port = value
                host = String(host[..<colon])
            }
            guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func open() {
        closeConnection()
        generation += 1
        guard let target else { return }
        guard let endpoint = Self.endpoint(for: target) else {
            onStateChanged?(false, "Invalid address: \(target.description)")
            return
        }

        let generation = generation
        let connection = NWConnection(to: endpoint, using: Self.parameters())
        self.connection = connection
        framer.reset()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.lastDataAt = Date()
                self.onStateChanged?(true, "Connected to \(target.description) via Wi-Fi")
                self.startWatchdog()
                self.receive(on: connection, generation: generation)
                self.send(ReceiverIdentity.identify(transport: CameraProtocol.transportWiFi))
            case .waiting(let error):
                // Typically "connection refused" while iPhoneCam is not open; redial on our own schedule.
                self.onStateChanged?(false, "Waiting for \(target.description): \(error.localizedDescription)")
                self.reconnectLater(generation)
            case .failed(let error):
                self.onStateChanged?(false, "Lost \(target.description): \(error.localizedDescription)")
                self.reconnectLater(generation)
            default:
                break
            }
        }
        onStateChanged?(false, "Connecting to \(target.description)...")
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, generation: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.generation == generation else { return }
            if let data, !data.isEmpty {
                self.lastDataAt = Date()
                self.framer.append(data)
                while let packet = self.framer.nextPacket() {
                    self.onPacket?(packet)
                }
            }
            if isComplete || error != nil || self.framer.isDesynced {
                self.onStateChanged?(false, "Disconnected from \(self.target?.description ?? "iPhone"), reconnecting...")
                self.reconnectLater(generation)
                return
            }
            self.receive(on: connection, generation: generation)
        }
    }

    private func reconnectLater(_ generation: Int) {
        guard self.generation == generation else { return }
        closeConnection()
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.generation == generation, self.target != nil else { return }
            self.open()
        }
    }

    private func closeConnection() {
        isConnected = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected, Date().timeIntervalSince(self.lastDataAt) > Self.idleTimeout else { return }
            self.onStateChanged?(false, "No data from \(self.target?.description ?? "iPhone"), reconnecting...")
            self.reconnectLater(self.generation)
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}

// MARK: - PhoneBrowser (Bonjour discovery of iPhones running iPhoneCam)

final class PhoneBrowser: @unchecked Sendable {
    var onPhonesChanged: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "iphonecam.receiver.browser")
    private var browser: NWBrowser?
    private var isRunning = false

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.browser?.cancel()
            self.browser = nil
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: CameraProtocol.phoneServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint {
                    return name
                }
                return nil
            }
            self?.onPhonesChanged?(Array(Set(names)).sorted())
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, case .failed = state else { return }
            browser?.cancel()
            self.browser = nil
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isRunning, self.browser == nil else { return }
                self.startBrowser()
            }
        }
        self.browser = browser
        browser.start(queue: queue)
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
        guard let payload = try? JSONEncoder().encode(command) else { return }
        send(CameraPacket(kind: .control, streamId: CameraProtocol.streamId, payload: payload))
    }

    func send(_ packet: CameraPacket) {
        queue.async { [weak self] in
            guard let self, self.streamFd >= 0 else { return }
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
                    print("[USBMux] /var/run/usbmuxd is unavailable under the macOS App Sandbox; connect over Wi-Fi instead.")
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

        let portInt = Int(CameraProtocol.streamPort.bigEndian)
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
        sendControlCommand(ReceiverIdentity.identify(transport: CameraProtocol.transportUSB))

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
                defer {
                    if self.framer.isDesynced {
                        // Out of sync; the read loop sees the shutdown, closes and redials.
                        shutdown(fd, SHUT_RDWR)
                    }
                }
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
