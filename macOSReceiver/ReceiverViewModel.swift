import AVFoundation
import Foundation

/// Where the receiver gets its stream from.
enum ReceiverSource: Hashable, Sendable {
    /// USB when a cable is attached, otherwise the first iPhone found on the network.
    case auto
    case usb
    case phone(String)
    case address(String)

    var storageValue: String {
        switch self {
        case .auto:
            return "auto"
        case .usb:
            return "usb"
        case .phone(let name):
            return "phone:" + name
        case .address(let address):
            return "address:" + address
        }
    }

    init(storageValue: String) {
        if storageValue == "usb" {
            self = .usb
        } else if storageValue.hasPrefix("phone:") {
            self = .phone(String(storageValue.dropFirst("phone:".count)))
        } else if storageValue.hasPrefix("address:") {
            self = .address(String(storageValue.dropFirst("address:".count)))
        } else {
            self = .auto
        }
    }
}

// MARK: - StreamReceiverEngine (Dedicated Background Pipeline)
final class StreamReceiverEngine: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onFormatChanged: ((String) -> Void)?
    var onStatsChanged: ((String) -> Void)?
    var onWaitingForKeyFrameChanged: ((Bool) -> Void)?
    var onConnectionModeChanged: ((_ isConnected: Bool, _ isUSB: Bool) -> Void)?
    var onCodecChanged: ((String) -> Void)?
    var onPhonesChanged: (([String]) -> Void)?

    let renderer = VideoRenderer()

    private let phoneConnection = PhoneConnection()
    private let browser = PhoneBrowser()
    private let usbReceiver = USBMuxReceiver()
    private let packetProcessor = ReceiverPacketProcessor()
    private let renderQueue = DispatchQueue(label: "iphonecam.receiver.render", qos: .userInteractive)

    // State accessed exclusively on renderQueue:
    private var source: ReceiverSource = .auto
    private var discoveredPhones: [String] = []
    /// Auto mode sticks with the phone it picked while that phone stays visible.
    private var autoPhone: String?
    private var isUSBMuxConnected = false
    private var isPhoneConnected = false
    private var usesUSB: Bool { source == .usb || source == .auto }
    private var sampleBuilder: H264SampleBuilder?
    private var isWaitingForKeyFrame = true
    private var displayedFrames = 0
    private var droppedFrames = 0
    private var displayDroppedFrames = 0
    private var lastEnqueuedFrameId: UInt64 = 0
    private var lastKeyFrameRequestDate = Date.distantPast
    private var lastStatsDate = Date()
    private var lastFrameReceivedAt = Date.distantPast
    private var idleCheckTimer: DispatchSourceTimer?
    private var framesSinceStats = 0
    private var clock = ClockOffsetEstimator()
    /// Capture on the iPhone to the frame being queued for display, smoothed; nil until the clock is synced.
    private var latencyMs: Double?
    private var started = false

    func sendControlCommand(_ command: CameraControlPayload) {
        renderQueue.async { [weak self] in
            self?.sendControlCommandOnQueue(command)
        }
    }

    private func sendControlCommandOnQueue(_ command: CameraControlPayload) {
        if isUSBMuxConnected && usesUSB {
            usbReceiver.sendControlCommand(command)
        } else {
            phoneConnection.send(command)
        }
    }

    private static func monotonicNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func sendTimeSyncRequest() {
        let request = CameraPacket(kind: .timeSyncRequest, streamId: CameraProtocol.streamId, ptsNanos: Self.monotonicNanos(), payload: Data())
        if isUSBMuxConnected && usesUSB {
            usbReceiver.send(request)
        } else if isPhoneConnected {
            phoneConnection.send(request)
        }
    }

    private func handleTimeSyncResponse(_ packet: CameraPacket) {
        guard let sentAt = ClockOffsetEstimator.echoedClock(in: packet.payload) else { return }
        clock.addSample(localSendNanos: sentAt, phoneNanos: packet.ptsNanos, localReceiveNanos: Self.monotonicNanos())
    }

    private func noteFrameLatency(_ frame: EncodedVideoFrame) {
        let now = Self.monotonicNanos()
        guard let capturedAt = clock.localNanos(forPhoneNanos: frame.ptsNanos), capturedAt <= now else { return }
        let sample = Double(now - capturedAt) / 1_000_000
        latencyMs = latencyMs.map { $0 * 0.9 + sample * 0.1 } ?? sample
    }

    /// Time-sync packets are answered here; everything else is the stream.
    private func acceptOnQueue(_ packet: CameraPacket) {
        if packet.kind == .timeSyncResponse {
            handleTimeSyncResponse(packet)
        } else {
            packetProcessor.accept(packet)
        }
    }

    private func requestKeyFrameFromSender() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyFrameRequestDate) > 0.5 else { return }
        lastKeyFrameRequestDate = now
        sendControlCommandOnQueue(CameraControlPayload(action: .requestKeyFrame))
    }

    func setSource(_ source: ReceiverSource) {
        renderQueue.async { [weak self] in
            guard let self, self.source != source else { return }
            self.source = source
            self.autoPhone = nil
            self.resetStreamState()
            self.applySource()
        }
    }

    /// Starts or stops the transports so exactly one of them carries the stream.
    private func applySource() {
        guard started else { return }
        switch source {
        case .usb:
            phoneConnection.disconnect()
            usbReceiver.start()
            if !isUSBMuxConnected {
                onStatusChanged?("Waiting for an iPhone on USB (open iPhoneCam on the phone)")
            }
        case .auto:
            usbReceiver.start()
            if isUSBMuxConnected {
                phoneConnection.disconnect()
                return
            }
            if autoPhone == nil || !discoveredPhones.contains(autoPhone!) {
                autoPhone = discoveredPhones.first
            }
            if let autoPhone {
                phoneConnection.connect(to: .service(autoPhone))
            } else {
                phoneConnection.disconnect()
                onStatusChanged?("Looking for iPhones running iPhoneCam...")
            }
        case .phone(let name):
            usbReceiver.stop()
            isUSBMuxConnected = false
            phoneConnection.connect(to: .service(name))
        case .address(let address):
            usbReceiver.stop()
            isUSBMuxConnected = false
            phoneConnection.connect(to: .address(address))
        }
    }

    private func resetStreamState() {
        // A new link may reach another iPhone or a restarted app; measure the clock afresh.
        clock.reset()
        latencyMs = nil
        packetProcessor.reset()
        lastEnqueuedFrameId = 0
        isWaitingForKeyFrame = true
        onWaitingForKeyFrameChanged?(true)
    }

    func start() {
        renderQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startIdleTimerIfNeeded()

            self.browser.onPhonesChanged = { [weak self] phones in
                self?.renderQueue.async { [weak self] in
                    guard let self else { return }
                    self.discoveredPhones = phones
                    self.onPhonesChanged?(phones)
                    if self.source == .auto {
                        self.applySource()
                    }
                }
            }
            self.usbReceiver.onStatusChanged = { [weak self] status in
                self?.renderQueue.async { [weak self] in
                    guard let self, self.usesUSB, self.isUSBMuxConnected || self.source == .usb else { return }
                    self.onStatusChanged?(status)
                }
            }
            self.usbReceiver.onConnectedChanged = { [weak self] connected in
                self?.renderQueue.async { [weak self] in
                    guard let self else { return }
                    let wasConnected = self.isUSBMuxConnected
                    self.isUSBMuxConnected = connected
                    guard self.usesUSB, connected != wasConnected else { return }
                    self.resetStreamState()
                    if connected {
                        self.onConnectionModeChanged?(true, true)
                        self.onStatusChanged?("Connected via USB cable")
                        self.requestKeyFrameFromSender()
                    } else {
                        self.onConnectionModeChanged?(false, false)
                        self.onStatusChanged?("USB disconnected")
                    }
                    // Auto mode moves between the cable and the network as the cable comes and goes.
                    self.applySource()
                }
            }
            self.usbReceiver.onPacket = { [weak self] packet in
                self?.renderQueue.async { [weak self] in
                    guard let self, self.isUSBMuxConnected, self.usesUSB else { return }
                    self.acceptOnQueue(packet)
                }
            }
            self.phoneConnection.onStateChanged = { [weak self] connected, status in
                self?.renderQueue.async { [weak self] in
                    guard let self, !(self.usesUSB && self.isUSBMuxConnected) else { return }
                    if connected != self.isPhoneConnected {
                        self.isPhoneConnected = connected
                        self.resetStreamState()
                    }
                    self.onConnectionModeChanged?(connected, false)
                    self.onStatusChanged?(status)
                }
            }
            self.phoneConnection.onPacket = { [weak self] packet in
                self?.renderQueue.async { [weak self] in
                    guard let self, !(self.usesUSB && self.isUSBMuxConnected) else { return }
                    self.acceptOnQueue(packet)
                }
            }
            self.packetProcessor.onHello = { [weak self] hello in
                self?.handleHelloOnQueue(hello)
            }
            self.packetProcessor.onFormat = { [weak self] format in
                self?.handleFormatOnQueue(format)
            }
            self.packetProcessor.onFrame = { [weak self] frame, droppedCount in
                self?.handleFrameOnQueue(frame, droppedFrames: droppedCount)
            }

            self.browser.start()
            self.applySource()
        }
    }

    func stop() {
        phoneConnection.disconnect()
        usbReceiver.stop()
        browser.stop()
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.packetProcessor.reset()
            self.renderer.reset()
            self.stopIdleTimer()
            self.sampleBuilder = nil
            self.isWaitingForKeyFrame = true
            self.isUSBMuxConnected = false
            self.isPhoneConnected = false
            self.displayedFrames = 0
            self.droppedFrames = 0
            self.displayDroppedFrames = 0
            self.lastEnqueuedFrameId = 0
            self.lastKeyFrameRequestDate = .distantPast
            self.framesSinceStats = 0
            self.started = false
        }
    }

    private func handleHelloOnQueue(_ hello: HelloPayload) {
        let isUSBMode = isUSBMuxConnected && usesUSB
        let codecLabel = hello.codec == CameraProtocol.codecHEVCHVCC ? "HEVC" : "H.264"
        onCodecChanged?(codecLabel)
        let mode = isUSBMode ? "USB (Cable)" : "Wi-Fi"
        onStatusChanged?("Connected: \(hello.deviceName) via \(mode)")
        onConnectionModeChanged?(true, isUSBMode)
        let text = "\(hello.width)x\(hello.height) @ \(hello.fps) FPS (\(codecLabel)), \(hello.bitrate / 1_000_000) Mbps"
        onFormatChanged?(text)
    }

    private func handleFormatOnQueue(_ format: FormatPayload) {
        do {
            sampleBuilder = try H264SampleBuilder(format: format)
            isWaitingForKeyFrame = true
            lastEnqueuedFrameId = 0
            requestKeyFrameFromSender()

            let codecLabel = format.codec == CameraProtocol.codecHEVCHVCC ? "HEVC" : "H.264"
            onCodecChanged?(codecLabel)
            onConnectionModeChanged?(true, isUSBMuxConnected && usesUSB)
            let text = "\(format.width)x\(format.height) @ \(format.fps) FPS (\(codecLabel)), \(format.bitrate / 1_000_000) Mbps"
            onFormatChanged?(text)
            onWaitingForKeyFrameChanged?(true)
        } catch {
            let errorMsg = error.localizedDescription
            onStatusChanged?("Format error: \(errorMsg)")
        }
    }

    private func handleFrameOnQueue(_ frame: EncodedVideoFrame, droppedFrames: Int) {
        lastFrameReceivedAt = Date()

        // 1. Drop stale/out-of-order frames (never feed backward PTS to AVSampleBufferDisplayLayer)
        if lastEnqueuedFrameId > 0 && frame.frameId <= lastEnqueuedFrameId {
            return
        }

        // 2. Check for frame loss / gap and request recovery keyframe in background without freezing
        let hadLoss = (droppedFrames > self.droppedFrames) ||
                      (lastEnqueuedFrameId > 0 && frame.frameId > lastEnqueuedFrameId + 1)
        self.droppedFrames = droppedFrames

        if hadLoss {
            requestKeyFrameFromSender()
        }

        // 3. Only if waiting for initial stream keyframe (before decoder format is ready), discard P-frames
        if isWaitingForKeyFrame {
            guard frame.isKeyFrame else {
                return
            }
            isWaitingForKeyFrame = false
            onWaitingForKeyFrameChanged?(false)
        }

        onConnectionModeChanged?(true, isUSBMuxConnected && usesUSB)
        guard let sampleBuilder else {
            isWaitingForKeyFrame = true
            requestKeyFrameFromSender()
            return
        }

        do {
            let sampleBuffer = try sampleBuilder.makeSampleBuffer(from: frame)
            if renderer.enqueue(sampleBuffer) {
                noteFrameLatency(frame)
                lastEnqueuedFrameId = frame.frameId
                displayedFrames += 1
                framesSinceStats += 1
            } else {
                displayDroppedFrames += 1
                isWaitingForKeyFrame = true
                requestKeyFrameFromSender()
            }
            updateStatsOnQueue()
        } catch {
            displayDroppedFrames += 1
            isWaitingForKeyFrame = true
            requestKeyFrameFromSender()
            updateStatsOnQueue()
        }
    }

    private func startIdleTimerIfNeeded() {
        guard idleCheckTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendTimeSyncRequest()
            if self.lastFrameReceivedAt != .distantPast && Date().timeIntervalSince(self.lastFrameReceivedAt) > 2.0 {
                self.onConnectionModeChanged?(false, false)
                self.onStatusChanged?("Waiting for iPhone")
            }
        }
        idleCheckTimer = timer
        timer.resume()
    }

    private func stopIdleTimer() {
        idleCheckTimer?.cancel()
        idleCheckTimer = nil
        lastFrameReceivedAt = .distantPast
    }

    private func updateStatsOnQueue() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsDate)
        guard elapsed >= 1.0 else { return }

        let fps = Double(framesSinceStats) / elapsed
        let displayed = displayedFrames
        let dropped = droppedFrames
        let displayDropped = displayDroppedFrames

        framesSinceStats = 0
        lastStatsDate = now

        var text = String(
            format: "%d frames, %.1f FPS, %d net drop, %d disp drop",
            displayed,
            fps,
            dropped,
            displayDropped
        )
        if let latencyMs, let roundTrip = clock.roundTripNanos {
            text += String(format: "\nLatency %.0f ms (capture to display queue), clock RTT %.1f ms", latencyMs, Double(roundTrip) / 1_000_000)
        } else {
            text += "\nLatency: measuring..."
        }
        onStatsChanged?(text)
    }
}

// MARK: - ReceiverViewModel (UI-facing @MainActor)
@MainActor
final class ReceiverViewModel: ObservableObject {
    private enum SettingsKey {
        static let source = "receiver.source"
        static let manualAddress = "receiver.manualAddress"
    }

    @Published var statusText = "Waiting for iPhone"
    @Published var formatText = "No stream"
    @Published var statsText = "0 frames, 0 dropped"
    @Published var waitingForKeyFrame = true
    @Published var isUSBActive = false
    @Published var isConnected = false
    @Published var activeCodec = "HEVC"
    @Published var phones: [String] = []
    @Published private(set) var selectedSource: ReceiverSource
    @Published var manualAddress: String

    var renderer: VideoRenderer { engine.renderer }

    private let engine = StreamReceiverEngine()
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        selectedSource = ReceiverSource(storageValue: defaults.string(forKey: SettingsKey.source) ?? "auto")
        manualAddress = defaults.string(forKey: SettingsKey.manualAddress) ?? ""
    }

    func selectSource(_ source: ReceiverSource) {
        selectedSource = source
        UserDefaults.standard.set(source.storageValue, forKey: SettingsKey.source)
        engine.setSource(source)
    }

    func connectToManualAddress() {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        UserDefaults.standard.set(address, forKey: SettingsKey.manualAddress)
        selectSource(.address(address))
    }

    func start() {
        guard !started else { return }
        started = true

        engine.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }
        engine.onFormatChanged = { [weak self] format in
            Task { @MainActor in
                self?.formatText = format
            }
        }
        engine.onStatsChanged = { [weak self] stats in
            Task { @MainActor in
                self?.statsText = stats
            }
        }
        engine.onWaitingForKeyFrameChanged = { [weak self] waiting in
            Task { @MainActor in
                self?.waitingForKeyFrame = waiting
            }
        }
        engine.onConnectionModeChanged = { [weak self] isConnected, isUSB in
            Task { @MainActor in
                self?.isConnected = isConnected
                self?.isUSBActive = isUSB
            }
        }
        engine.onCodecChanged = { [weak self] codec in
            Task { @MainActor in
                self?.activeCodec = codec
            }
        }
        engine.onPhonesChanged = { [weak self] phones in
            Task { @MainActor in
                self?.phones = phones
            }
        }

        engine.setSource(selectedSource)
        engine.start()
    }

    func stop() {
        engine.stop()
        started = false
        isUSBActive = false
        isConnected = false
    }
}
