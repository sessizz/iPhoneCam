import AVFoundation
import Foundation

// MARK: - StreamReceiverEngine (Dedicated Background Pipeline)
final class StreamReceiverEngine: @unchecked Sendable {
    var onStatusChanged: ((String) -> Void)?
    var onFormatChanged: ((String) -> Void)?
    var onStatsChanged: ((String) -> Void)?
    var onWaitingForKeyFrameChanged: ((Bool) -> Void)?
    var onConnectionModeChanged: ((_ isConnected: Bool, _ isUSB: Bool) -> Void)?
    var onCodecChanged: ((String) -> Void)?
    var onDiscoveredDevicesChanged: (([String]) -> Void)?

    let renderer = VideoRenderer()

    private let receiver = UDPReceiver()
    private let usbReceiver = USBMuxReceiver()
    private let packetProcessor = ReceiverPacketProcessor()
    private let renderQueue = DispatchQueue(label: "iphonecam.receiver.render", qos: .userInteractive)
    private var isUSBMuxConnected = false
    private var isWiredNetwork = false
    private var isUSBMode: Bool { isUSBMuxConnected || isWiredNetwork }
    private var targetDeviceName = "Auto"
    private var discoveredDeviceNames = Set<String>()

    // State accessed exclusively on renderQueue:
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
    private var started = false

    func sendControlCommand(_ command: CameraControlPayload) {
        if isUSBMuxConnected {
            usbReceiver.sendControlCommand(command)
        } else {
            receiver.sendControlCommand(command)
        }
    }

    private func requestKeyFrameFromSender() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyFrameRequestDate) > 0.5 else { return }
        lastKeyFrameRequestDate = now
        let cmd = CameraControlPayload(action: .requestKeyFrame)
        sendControlCommand(cmd)
    }

    func setTargetDevice(_ name: String) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.targetDeviceName = name
            self.usbReceiver.setTargetDevice(name)
            self.receiver.setTargetDevice(name)
            self.packetProcessor.reset()
            self.lastEnqueuedFrameId = 0
            self.isWaitingForKeyFrame = true
            self.onWaitingForKeyFrameChanged?(true)
        }
    }

    func start() {
        renderQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.startIdleTimerIfNeeded()

            self.usbReceiver.onDiscoveredDevicesChanged = { [weak self] devices in
                self?.renderQueue.async {
                    guard let self else { return }
                    for d in devices { self.discoveredDeviceNames.insert(d) }
                    self.onDiscoveredDevicesChanged?(Array(self.discoveredDeviceNames).sorted())
                }
            }

            self.usbReceiver.onStatusChanged = { [weak self] status in
                self?.renderQueue.async {
                    self?.onStatusChanged?(status)
                }
            }
            self.usbReceiver.onConnectedChanged = { [weak self] connected in
                self?.renderQueue.async {
                    guard let self else { return }
                    let wasConnected = self.isUSBMuxConnected
                    self.isUSBMuxConnected = connected
                    self.lastEnqueuedFrameId = 0
                    if connected {
                        self.packetProcessor.reset()
                        self.isWaitingForKeyFrame = true
                        self.onWaitingForKeyFrameChanged?(true)
                        self.onConnectionModeChanged?(true, self.isUSBMode)
                        self.onStatusChanged?("Connected via USB Cable (High-Speed)")
                        self.requestKeyFrameFromSender()
                    } else if wasConnected {
                        self.packetProcessor.reset()
                        self.isWaitingForKeyFrame = true
                        self.onWaitingForKeyFrameChanged?(true)
                        self.onConnectionModeChanged?(true, self.isUSBMode)
                        self.onStatusChanged?("USB Disconnected - Switched to Wi-Fi")
                        self.requestKeyFrameFromSender()
                    }
                }
            }
            self.usbReceiver.onPacket = { [weak self] packet in
                self?.renderQueue.async {
                    guard let self, self.isUSBMuxConnected else { return }
                    self.packetProcessor.accept(packet)
                }
            }
            self.usbReceiver.start()

            self.receiver.onStatusChanged = { [weak self] status in
                self?.renderQueue.async {
                    guard let self, !self.isUSBMuxConnected else { return }
                    self.onStatusChanged?(status)
                }
            }
            self.receiver.onInterfaceChanged = { [weak self] interfaceDesc, isWired in
                self?.renderQueue.async {
                    guard let self else { return }
                    self.isWiredNetwork = isWired
                    if !self.isUSBMuxConnected {
                        self.onConnectionModeChanged?(true, isWired)
                        self.onStatusChanged?("Connected: \(interfaceDesc)")
                    }
                }
            }
            self.receiver.onPacket = { [weak self] packet in
                self?.renderQueue.async {
                    guard let self, !self.isUSBMuxConnected else { return }
                    self.packetProcessor.accept(packet)
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

            self.receiver.start()
        }
    }

    func stop() {
        receiver.stop()
        usbReceiver.stop()
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.packetProcessor.reset()
            self.renderer.reset()
            self.stopIdleTimer()
            self.sampleBuilder = nil
            self.isWaitingForKeyFrame = true
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
        discoveredDeviceNames.insert(hello.deviceName)
        onDiscoveredDevicesChanged?(Array(discoveredDeviceNames).sorted())

        if targetDeviceName != "Auto" && !targetDeviceName.isEmpty && hello.deviceName != targetDeviceName {
            return
        }

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
            onConnectionModeChanged?(true, isUSBMode)
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

        onConnectionModeChanged?(true, isUSBMode)
        guard let sampleBuilder else {
            isWaitingForKeyFrame = true
            requestKeyFrameFromSender()
            return
        }

        do {
            let sampleBuffer = try sampleBuilder.makeSampleBuffer(from: frame)
            if renderer.enqueue(sampleBuffer) {
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

        let text = String(
            format: "%d frames, %.1f FPS, %d net drop, %d disp drop",
            displayed,
            fps,
            dropped,
            displayDropped
        )
        onStatsChanged?(text)
    }
}

// MARK: - ReceiverViewModel (UI-facing @MainActor)
@MainActor
final class ReceiverViewModel: ObservableObject {
    @Published var statusText = "Waiting for iPhone"
    @Published var formatText = "No stream"
    @Published var statsText = "0 frames, 0 dropped"
    @Published var waitingForKeyFrame = true
    @Published var isUSBActive = false
    @Published var isConnected = false
    @Published var activeCodec = "HEVC"
    @Published var availableDevices: [String] = ["Auto"]
    @Published var selectedDevice: String = "Auto"

    var renderer: VideoRenderer { engine.renderer }

    private let engine = StreamReceiverEngine()
    private var started = false

    func selectDevice(_ device: String) {
        selectedDevice = device
        engine.setTargetDevice(device)
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
        engine.onDiscoveredDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                var list = ["Auto"]
                for d in devices where !list.contains(d) {
                    list.append(d)
                }
                self.availableDevices = list
            }
        }

        engine.start()
    }

    func stop() {
        engine.stop()
        started = false
        isUSBActive = false
        isConnected = false
    }
}
