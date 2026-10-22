import CoreMedia
import Foundation
import Network

/// TCP server the receivers dial: OBS or the Mac app over Wi-Fi (the iPhone's IP or its Bonjour name) or through
/// usbmuxd over the cable. Each receiver gets its own bounded queue, so a receiver that falls behind skips
/// frames instead of building up latency, and only that receiver pays for it.
final class NetworkVideoSender: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onStatsChanged: ((String) -> Void)?
    var onControlCommand: ((CameraControlPayload) -> Void)?
    var onInterfaceChanged: ((String, Bool) -> Void)?
    var onRequestKeyFrame: (() -> Void)?
    var onBitrateChanged: ((Int) -> Void)?
    var onAddressesChanged: (([String]) -> Void)?
    var onReceiverCountChanged: ((Int) -> Void)?

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var framer = TCPPacketFramer()
        var isReady = false
        var transport: String?
        var name: String?
        /// Video frames handed to the connection whose send has not completed yet.
        var inFlightFrames = 0
        /// After a skipped frame every following frame references one this receiver never got, so nothing but a
        /// keyframe is worth sending until one arrives.
        var waitingForKeyFrame = true
        var sentFormat: H264Format?
        var droppedFrames = 0
        var maxSendDelayNanos: UInt64 = 0
        /// When a frame send last completed; a full queue with no progress means the receiver stopped reading.
        var lastProgressNanos = DispatchTime.now().uptimeNanoseconds
        var completedSinceTick = 0

        init(connection: NWConnection) {
            self.connection = connection
        }

        /// usbmuxd hands cable connections to the listener from loopback; `identify` says so explicitly.
        var isUSB: Bool {
            if let transport {
                return transport == CameraProtocol.transportUSB
            }
            guard case .hostPort(let host, _) = connection.endpoint else {
                return false
            }
            switch host {
            case .ipv4(let address):
                return address.isLoopback
            case .ipv6(let address):
                return address.isLoopback || address.asIPv4?.isLoopback == true
            default:
                return false
            }
        }

        var displayName: String {
            "\(name ?? "Receiver") (\(isUSB ? "USB" : "Wi-Fi"))"
        }
    }

    /// A deep queue is invisible latency; past this, frames are skipped rather than queued.
    private static let maxInFlightFrames = 12
    private static let maxClients = 4
    /// A receiver that has not accepted a frame for this long is hung (OBS frozen, a dead link TCP has not
    /// noticed yet); dropping it lets it reconnect instead of dragging the shared bitrate down for everyone.
    private static let stalledClientNanos: UInt64 = 5_000_000_000

    private let queue = DispatchQueue(label: "iphonecam.network.sender", qos: .userInteractive)
    private var isRunning = false
    private var listener: NWListener?
    private var listenGeneration = 0
    private var bindRetries = 0
    private var clients: [Client] = []
    private var latestFormat: H264Format?
    private var nextFrameSequence: UInt64 = 0
    private var tickTimer: DispatchSourceTimer?
    private var tickCount = 0
    private var quality: StreamQuality = .balanced
    private var pressureScale = 1.0
    private var bitrate: AdaptiveBitrate?
    private var addresses: [String] = []
    private var encodedFramesSinceStats = 0
    private var encodedBytesSinceStats = 0
    private var droppedFramesSinceStats = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var deviceName: String = DeviceIdentity.displayName

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.bindRetries = 0
            self.listenGeneration += 1
            self.listen(advertise: true)
            self.startTicking()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.listenGeneration += 1
            self.tickTimer?.cancel()
            self.tickTimer = nil
            self.listener?.cancel()
            self.listener = nil
            let clients = self.clients
            self.clients.removeAll()
            clients.forEach { $0.connection.cancel() }
            self.nextFrameSequence = 0
            self.onStatusChanged?("Stopped")
            self.onInterfaceChanged?("Not connected", false)
            self.onReceiverCountChanged?(0)
        }
    }

    func updateDeviceName(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceName = name
            if let listener = self.listener, listener.service != nil {
                listener.service = NWListener.Service(name: name, type: CameraProtocol.phoneServiceType)
            }
            self.clients.filter(\.isReady).forEach { self.sendHello(to: $0) }
        }
    }

    func setQuality(_ quality: StreamQuality) {
        queue.async { [weak self] in
            guard let self, self.quality != quality else { return }
            self.quality = quality
            self.resetBitrate()
        }
    }

    func setPressureScale(_ scale: Double) {
        queue.async { [weak self] in
            self?.pressureScale = scale
            self?.bitrate?.pressureScale = scale
        }
    }

    func updateFormat(_ format: H264Format) {
        queue.async { [weak self] in
            self?.noteFormat(format)
        }
    }

    func send(_ sample: EncodedH264Sample) {
        queue.async { [weak self] in
            guard let self else { return }
            let sequence = self.nextFrameSequence
            self.nextFrameSequence &+= 1
            self.encodedFramesSinceStats += 1
            self.encodedBytesSinceStats += sample.data.count
            if let format = sample.format {
                self.noteFormat(format)
            }

            let packet = CameraPacket(
                kind: .frameFragment,
                flags: sample.isKeyFrame ? .keyFrame : [],
                streamId: CameraProtocol.streamId,
                frameId: sequence,
                ptsNanos: sample.ptsNanos,
                payload: sample.data
            )
            let header = packet.framedTCPHeader()
            var needsKeyFrame = false
            for client in self.clients where client.isReady {
                if let format = self.latestFormat, client.sentFormat.map({ !$0.describesSameStream(as: format) }) ?? true {
                    self.sendFormat(format, to: client)
                }
                // The cap covers keyframes too: every skip asks for a keyframe, so exempting them would queue
                // keyframes into a stalled connection without bound.
                if client.inFlightFrames >= Self.maxInFlightFrames {
                    client.droppedFrames += 1
                    client.waitingForKeyFrame = true
                    self.droppedFramesSinceStats += 1
                    continue
                }
                if sample.isKeyFrame {
                    client.waitingForKeyFrame = false
                } else if client.waitingForKeyFrame {
                    needsKeyFrame = true
                    continue
                }
                self.sendFrame(header: header, payload: sample.data, to: client)
            }
            if needsKeyFrame {
                self.onRequestKeyFrame?()
            }
        }
    }

    func sendAudio(_ sample: EncodedAudioSample) {
        queue.async { [weak self] in
            guard let self else { return }
            let framed = CameraPacket(
                kind: .audio,
                streamId: CameraProtocol.streamId,
                ptsNanos: sample.ptsNanos,
                payload: sample.data
            ).framedForTCP()
            for client in self.clients where client.isReady && client.inFlightFrames < Self.maxInFlightFrames {
                self.send(framed, to: client)
            }
        }
    }

    // MARK: - Listener

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Without keepalive a silently dead link (Wi-Fi drop, no RST) keeps a receiver "connected" for minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func listen(advertise: Bool) {
        guard isRunning, let port = NWEndpoint.Port(rawValue: CameraProtocol.streamPort) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.tcpParameters(), on: port)
        } catch {
            onStatusChanged?("Could not open port \(port.rawValue): \(error.localizedDescription)")
            scheduleRelisten(advertise: advertise, after: 2)
            return
        }
        if advertise {
            listener.service = NWListener.Service(name: deviceName, type: CameraProtocol.phoneServiceType)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.bindRetries = 0
                self.refreshAddresses(force: true)
                self.publishClients()
            case .failed(let error):
                if advertise, case .dns = error {
                    // Advertising needs the Local Network permission; listening does not, so typed-IP and USB
                    // connections keep working without it.
                    self.onStatusChanged?("Bonjour unavailable, connect by IP (check Local Network permission)")
                    self.scheduleRelisten(advertise: false, after: 0.3)
                    return
                }
                // The port can still be held by the socket just given up; that resolves itself within a second.
                if case .posix(let code) = error, code == .EADDRINUSE, self.bindRetries < 4 {
                    self.bindRetries += 1
                    self.scheduleRelisten(advertise: advertise, after: 0.5)
                    return
                }
                self.onStatusChanged?("Listener failed: \(error.localizedDescription)")
                self.scheduleRelisten(advertise: advertise, after: 2)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func scheduleRelisten(advertise: Bool, after delay: TimeInterval) {
        listener?.cancel()
        listener = nil
        let generation = listenGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.listenGeneration == generation, self.listener == nil else { return }
            self.listen(advertise: advertise)
        }
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        guard isRunning else {
            connection.cancel()
            return
        }
        if clients.count >= Self.maxClients, let oldest = clients.first {
            remove(oldest)
        }
        let client = Client(connection: connection)
        clients.append(client)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                client.isReady = true
                self.sendHello(to: client)
                if let format = self.latestFormat {
                    self.sendFormat(format, to: client)
                }
                self.onRequestKeyFrame?()
                self.receive(on: client)
                self.publishClients()
            case .failed, .cancelled:
                self.remove(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ client: Client) {
        guard let index = clients.firstIndex(where: { $0 === client }) else { return }
        clients.remove(at: index)
        client.connection.cancel()
        // One encoder serves every receiver, so the rate follows the worst of them; once the one that held it
        // down is gone, measure the remaining links afresh instead of climbing back 10% at a time.
        if client.isReady {
            resetBitrate()
        }
        publishClients()
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, self.clients.contains(where: { $0 === client }) else { return }
            if let data, !data.isEmpty {
                client.framer.append(data)
                while let packet = client.framer.nextPacket() {
                    self.handle(packet, from: client)
                }
            }
            if isComplete || error != nil {
                self.remove(client)
                return
            }
            self.receive(on: client)
        }
    }

    private func handle(_ packet: CameraPacket, from client: Client) {
        switch packet.kind {
        case .control:
            guard let command = try? decoder.decode(CameraControlPayload.self, from: packet.payload) else { return }
            switch command.action {
            case .identify:
                client.transport = command.transport
                client.name = command.clientName
                publishClients()
            case .requestKeyFrame:
                onRequestKeyFrame?()
            default:
                onControlCommand?(command)
            }
        case .timeSyncRequest:
            var echo = Data()
            var requestClock = packet.ptsNanos.bigEndian
            Swift.withUnsafeBytes(of: &requestClock) { echo.append(contentsOf: $0) }
            let response = CameraPacket(
                kind: .timeSyncResponse,
                streamId: CameraProtocol.streamId,
                ptsNanos: Self.hostClockNanos(),
                payload: echo
            )
            send(response.framedForTCP(), to: client)
        default:
            break
        }
    }

    /// The clock capture timestamps come from, so a receiver can relate frame timestamps to its own clock.
    private static func hostClockNanos() -> UInt64 {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(max(0, CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value))
    }

    // MARK: - Sending

    private func sendFrame(header: Data, payload: Data, to client: Client) {
        client.inFlightFrames += 1
        let connection = client.connection
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        // Header and payload go out as two writes so the frame is not copied just to gain a 40-byte prefix.
        connection.batch {
            connection.send(content: header, completion: .idempotent)
            connection.send(content: payload, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client else { return }
                client.inFlightFrames = max(0, client.inFlightFrames - 1)
                client.lastProgressNanos = DispatchTime.now().uptimeNanoseconds
                client.completedSinceTick += 1
                // TCP hides congestion in the socket buffer long before this queue fills; the time a send takes
                // to be accepted exposes it.
                client.maxSendDelayNanos = max(client.maxSendDelayNanos, DispatchTime.now().uptimeNanoseconds - enqueuedAt)
                if let error, !Self.isCancellation(error) {
                    self.remove(client)
                }
            })
        }
    }

    private func send(_ data: Data, to client: Client) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, let error, !Self.isCancellation(error) else { return }
            self.remove(client)
        })
    }

    private static func isCancellation(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .ECANCELED {
            return true
        }
        return false
    }

    private func sendHello(to client: Client) {
        let payload = HelloPayload(
            deviceName: deviceName,
            codec: latestFormat?.codec ?? CameraProtocol.defaultCodec,
            width: latestFormat?.width ?? CameraProtocol.targetWidth,
            height: latestFormat?.height ?? CameraProtocol.targetHeight,
            fps: latestFormat?.fps ?? CameraProtocol.targetFPS,
            bitrate: bitrate?.current ?? latestFormat?.bitrate ?? CameraProtocol.targetBitrate
        )
        guard let data = try? encoder.encode(payload) else { return }
        send(CameraPacket(kind: .hello, streamId: CameraProtocol.streamId, payload: data).framedForTCP(), to: client)
    }

    private func sendFormat(_ format: H264Format, to client: Client) {
        guard let data = try? encoder.encode(format.payload) else { return }
        client.sentFormat = format
        send(CameraPacket(kind: .format, streamId: CameraProtocol.streamId, payload: data).framedForTCP(), to: client)
    }

    private func noteFormat(_ format: H264Format) {
        let codecChanged = latestFormat?.codec != format.codec
        latestFormat = format
        guard codecChanged else { return }
        resetBitrate()
        clients.filter(\.isReady).forEach { sendHello(to: $0) }
    }

    // MARK: - Adaptive bitrate and status

    private func resetBitrate() {
        guard let format = latestFormat else { return }
        let base = format.codec == CameraProtocol.codecHEVCHVCC ? CameraProtocol.targetBitrateHEVC : CameraProtocol.targetBitrateH264
        var policy = AdaptiveBitrate(baseBitrate: base, quality: quality)
        policy.pressureScale = pressureScale
        bitrate = policy
        onBitrateChanged?(policy.current)
    }

    private func startTicking() {
        tickTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        tickTimer = timer
    }

    private func tick() {
        tickCount += 1
        let now = DispatchTime.now().uptimeNanoseconds
        for client in clients where client.isReady && client.inFlightFrames >= Self.maxInFlightFrames {
            if now - client.lastProgressNanos > Self.stalledClientNanos {
                print("[NetworkVideoSender] Dropping stalled receiver \(client.displayName)")
                remove(client)
            }
        }
        let ready = clients.filter(\.isReady)

        if tickCount % 2 == 0 {
            let ping = CameraPacket(kind: .ping, streamId: CameraProtocol.streamId, payload: Data()).framedForTCP()
            ready.forEach { send(ping, to: $0) }
        }
        if tickCount % 5 == 0 {
            refreshAddresses(force: false)
        }

        // A receiver whose queue is full and accepted nothing this second has stopped reading; while another
        // receiver is healthy, leave it out so one hung receiver does not starve the rest. Alone, it counts:
        // then it is the link that is congested.
        let progressing = ready.filter { $0.completedSinceTick > 0 || $0.inFlightFrames < Self.maxInFlightFrames }
        let measured = progressing.isEmpty ? ready : progressing
        if !measured.isEmpty, var policy = bitrate {
            let sample = AdaptiveBitrate.Sample(
                droppedFrames: measured.reduce(0) { $0 + $1.droppedFrames },
                maxSendDelayMs: Int((measured.map(\.maxSendDelayNanos).max() ?? 0) / 1_000_000),
                allUSB: measured.allSatisfy(\.isUSB)
            )
            if let next = policy.update(sample) {
                onBitrateChanged?(next)
            }
            bitrate = policy
        }
        for client in ready {
            client.droppedFrames = 0
            client.maxSendDelayNanos = 0
            client.completedSinceTick = 0
        }

        let megabits = Double(encodedBytesSinceStats * 8) / 1_000_000
        let target = Double(bitrate?.current ?? 0) / 1_000_000
        onStatsChanged?(String(
            format: "%d fps, %.1f Mbps (target %.1f), %d skipped, %d receiver%@",
            encodedFramesSinceStats, megabits, target, droppedFramesSinceStats, ready.count, ready.count == 1 ? "" : "s"
        ))
        encodedFramesSinceStats = 0
        encodedBytesSinceStats = 0
        droppedFramesSinceStats = 0
    }

    private func refreshAddresses(force: Bool) {
        let current = NetworkInfo.reachableIPv4Addresses()
        guard force || current != addresses else { return }
        addresses = current
        onAddressesChanged?(current)
        publishClients()
    }

    private func publishClients() {
        guard isRunning else { return }
        let ready = clients.filter(\.isReady)
        onReceiverCountChanged?(ready.count)
        if ready.isEmpty {
            let target = addresses.first.map { "\($0):\(CameraProtocol.streamPort)" } ?? "port \(CameraProtocol.streamPort)"
            onStatusChanged?(listener == nil ? "Starting listener..." : "Waiting for OBS or Mac at \(target)")
            onInterfaceChanged?("Not connected", false)
        } else {
            onStatusChanged?("Connected: " + ready.map(\.displayName).joined(separator: ", "))
            let usb = ready.contains(where: \.isUSB)
            onInterfaceChanged?(usb ? "USB cable" : "Wi-Fi", usb)
        }
    }
}
