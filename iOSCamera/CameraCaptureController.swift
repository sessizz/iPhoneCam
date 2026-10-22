import AVFoundation
import Foundation
import UIKit

enum LensSwitchingMode: String, CaseIterable, Identifiable {
    case auto
    case restricted
    case locked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .restricted:
            return "Restrict"
        case .locked:
            return "Lock"
        }
    }

    var captureBehavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior {
        switch self {
        case .auto:
            return .auto
        case .restricted:
            return .restricted
        case .locked:
            return .locked
        }
    }
}

enum VideoStabilizationSetting: String, CaseIterable, Identifiable {
    case off
    case standard
    case cinematic
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .standard:
            return "Standard"
        case .cinematic:
            return "Cinematic"
        case .auto:
            return "Auto"
        }
    }

    var captureMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off:
            return .off
        case .standard:
            return .standard
        case .cinematic:
            return .cinematic
        case .auto:
            return .auto
        }
    }
}

final class CameraCaptureController: NSObject, ObservableObject, @unchecked Sendable {
    @Published var statusText = "Camera warming up..."
    @Published var warningText: String?
    @Published var activeFormatText = "1080p60 target"
    @Published private(set) var videoRotationAngle: CGFloat = 0
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var minZoomFactor: CGFloat = 1
    @Published private(set) var maxZoomFactor: CGFloat = 1
    @Published private(set) var switchOverZoomFactors: [CGFloat] = []
    @Published private(set) var cameraModeText = "Back camera"
    @Published private(set) var activeLensText = "Lens: -"
    @Published private(set) var lensSwitchingText = "Lens switching: -"
    @Published private(set) var lensSwitchingMode: LensSwitchingMode = .locked
    @Published private(set) var stabilizationMode: VideoStabilizationSetting = .off
    @Published private(set) var stabilizationModeText = "Stabilization: off requested"
    @Published private(set) var activeCodec: VideoCodecType = .hevc
    @Published private(set) var droppedCaptureFrameCount: Int = 0
    @Published private(set) var audioProfile: AudioProfile = .studio
    @Published private(set) var isAudioMuted: Bool = false
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var audioStatusText = "Mic: active"
    @Published private(set) var formatChoice = CaptureFormatChoice.standard
    /// Frame rates the active camera offers per resolution.
    @Published private(set) var supportedFrameRates: [StreamResolution: [Int]] = [:]
    @Published private(set) var cameraPosition: CameraPosition = .back
    @Published private(set) var imageControls = ImageControlsState()

    let session = AVCaptureSession()

    var onFormat: ((H264Format) -> Void)?
    var onEncodedSample: ((EncodedH264Sample) -> Void)?
    var onPreviewSample: ((CMSampleBuffer) -> Void)?
    var onAudioSample: ((EncodedAudioSample) -> Void)?
    /// 1 normally, 0.5 at serious and 0.25 at critical thermal/power pressure; scales the stream's bitrate.
    var onPressureScaleChanged: ((Double) -> Void)?

    private let sessionQueue = DispatchQueue(label: "iphonecam.capture.session")
    private let audioQueue = DispatchQueue(label: "iphonecam.capture.audio")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let audioEncoder = AudioEncoder()
    private var captureDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var requestedChoice = CaptureFormatChoice.standard
    private var requestedPosition: CameraPosition = .back
    /// The modes and values the user asked for, re-applied after a format change resets the device.
    private var requestedControls = ImageControlsState()
    private var lockedLensPosition: Float?
    private var lockedWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains?
    private var zoomPollTicks = 0
    private var encoder: H264Encoder?
    private var activeQuality: StreamQuality = .balanced
    /// The adaptive bitrate loop's current target; nil until it speaks, which means the codec default.
    private var targetBitrate: Int?
    private var pressureObservation: NSKeyValueObservation?
    private var zoomPollTimer: DispatchSourceTimer?
    private var configured = false
    private var selectedCameraFormat: SelectedCameraFormat?
    private var currentRotationAngle: CGFloat = 0
    private var displayZoomFactorMultiplier: CGFloat = 1
    private var requestedLensSwitchingMode: LensSwitchingMode = .locked
    private var requestedStabilizationMode: VideoStabilizationSetting = .off
    private var selectedFormatWarning: String?
    private var lastContinuousZoomIntensity: Double = 0
    private var lastContinuousZoomCommand = Date.distantPast
    private var lastStabilizationModePublish = Date.distantPast
    private let maximumPresentedZoomFactor: CGFloat = 8

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioAccessIfNeededAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.requestAudioAccessIfNeededAndStart()
                } else {
                    DispatchQueue.main.async {
                        self?.statusText = "Camera permission denied"
                    }
                }
            }
        default:
            statusText = "Camera permission denied"
        }
    }

    private func requestAudioAccessIfNeededAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.configureAndStart()
            }
        default:
            configureAndStart()
        }
    }

    func setAudioProfile(_ profile: AudioProfile) {
        audioProfile = profile
        audioEncoder.setProfile(profile)
        DispatchQueue.main.async { [weak self] in
            self?.audioProfile = profile
        }
        sessionQueue.async { [weak self] in
            self?.configureAudioSession(for: profile)
        }
    }

    func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        audioEncoder.isMuted = muted
        DispatchQueue.main.async { [weak self] in
            self?.isAudioMuted = muted
            self?.audioStatusText = muted ? "Mic: muted" : "Mic: active"
        }
    }

    func toggleAudioMute() {
        setAudioMuted(!isAudioMuted)
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.stopContinuousZoomOnQueue()
            self?.stopZoomPolling()
            self?.session.stopRunning()
            self?.audioEncoder.reset()
        }
    }

    func updateVideoRotation(for deviceOrientation: UIDeviceOrientation, interfaceOrientation: UIInterfaceOrientation?) {
        guard let angle = Self.rotationAngle(for: interfaceOrientation) ?? Self.rotationAngle(for: deviceOrientation) else {
            return
        }
        currentRotationAngle = angle
        videoRotationAngle = angle
        sessionQueue.async { [weak self] in
            self?.applyCurrentRotation()
        }
    }

    func rampZoom(to factor: CGFloat, duration: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else {
                return
            }

            let target = self.clampedDeviceZoomFactor(forDisplayedFactor: factor, on: device)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let current = max(device.videoZoomFactor, 0.01)
                let ratio = max(Double(target / current), 0.01)
                let rate = max(0.05, min(8, abs(log2(ratio)) / max(duration, 0.15)))
                if abs(target - current) < 0.01 {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = target
                } else {
                    device.ramp(toVideoZoomFactor: target, withRate: Float(rate))
                }
                self.publishZoom(device.videoZoomFactor)
            } catch {
                self.publishWarning(error.localizedDescription)
            }
        }
    }

    func updateContinuousZoom(intensity: Double) {
        let clampedIntensity = max(-1, min(1, intensity))
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else {
                return
            }

            guard abs(clampedIntensity) >= 0.04 else {
                self.stopContinuousZoomOnQueue()
                return
            }

            let now = Date()
            guard
                abs(clampedIntensity - self.lastContinuousZoomIntensity) >= 0.035 ||
                now.timeIntervalSince(self.lastContinuousZoomCommand) >= 0.25
            else {
                return
            }

            self.lastContinuousZoomIntensity = clampedIntensity
            self.lastContinuousZoomCommand = now
            let target = clampedIntensity > 0 ? self.maximumDeviceZoomFactor(for: device) : device.minAvailableVideoZoomFactor
            let normalizedSpeed = pow(abs(clampedIntensity), 1.25)
            let rate = Float(0.14 + normalizedSpeed * 4.2)

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            } catch {
                self.publishWarning(error.localizedDescription)
            }
        }
    }

    func stopContinuousZoom() {
        sessionQueue.async { [weak self] in
            self?.stopContinuousZoomOnQueue()
        }
    }

    func setLensSwitchingMode(_ mode: LensSwitchingMode) {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.requestedLensSwitchingMode = mode
            guard let device = self.captureDevice else {
                self.publishLensSwitchingMode(mode)
                return
            }
            self.applyLensSwitchingMode(on: device)
            self.updateZoomCapabilities(for: device)
        }
    }

    func setStabilizationMode(_ mode: VideoStabilizationSetting) {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.requestedStabilizationMode = mode
            DispatchQueue.main.async { [weak self] in
                self?.stabilizationMode = mode
            }
            guard let connection = self.videoOutput?.connection(with: .video) else {
                return
            }
            self.applyVideoStabilization(on: connection)
        }
    }

    func requestKeyFrame() {
        sessionQueue.async { [weak self] in
            self?.encoder?.requestKeyFrame()
        }
    }

    func setCodec(_ codec: VideoCodecType) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.activeCodec != codec else { return }
            self.activeCodec = codec
            DispatchQueue.main.async {
                self.activeCodec = codec
            }
            // The sender resets its bitrate policy for the new codec and reports the new target.
            self.targetBitrate = nil
            self.rebuildEncoder()
        }
    }

    func setQuality(_ quality: StreamQuality) {
        sessionQueue.async { [weak self] in
            guard let self, self.activeQuality != quality else { return }
            self.activeQuality = quality
            self.targetBitrate = nil
            self.rebuildEncoder()
        }
    }

    func setBitrate(_ bitsPerSecond: Int) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.targetBitrate = bitsPerSecond
            guard let encoder = self.encoder else { return }
            if bitsPerSecond > encoder.appliedBitrate {
                // A raise only takes effect in a fresh compression session; the cost is one keyframe.
                self.rebuildEncoder()
            } else {
                encoder.setBitrate(bitsPerSecond)
            }
        }
    }

    private func rebuildEncoder() {
        guard let selected = selectedCameraFormat else { return }
        encoder = makeEncoder(for: selected)
        let codec = activeCodec
        DispatchQueue.main.async {
            self.activeFormatText = "\(selected.width)x\(selected.height) @ \(selected.fps) FPS (\(codec.rawValue))"
        }
    }

    private func makeEncoder(for selected: SelectedCameraFormat) -> H264Encoder {
        let encoder = H264Encoder(
            codec: activeCodec,
            quality: activeQuality,
            width: selected.width,
            height: selected.height,
            fps: selected.fps,
            bitrate: targetBitrate
        )
        encoder.onFormat = { [weak self] format in
            self?.onFormat?(format)
        }
        encoder.onSample = { [weak self] sample in
            self?.onEncodedSample?(sample)
        }
        return encoder
    }

    /// Per the systemPressureState guidance: shed bitrate before the system starts shedding frames for us.
    private func observeSystemPressure(on device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let scale: Double
            switch device.systemPressureState.level {
            case .serious:
                scale = 0.5
            case .critical, .shutdown:
                scale = 0.25
            default:
                scale = 1
            }
            self?.onPressureScaleChanged?(scale)
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured {
                    let selected = try self.configureSession()
                    self.selectedCameraFormat = selected
                    self.encoder = self.makeEncoder(for: selected)
                    self.audioEncoder.onSample = { [weak self] sample in
                        self?.onAudioSample?(sample)
                    }
                    self.audioEncoder.onLevelUpdate = { [weak self] level in
                        DispatchQueue.main.async {
                            self?.audioLevel = level
                        }
                    }
                    self.configured = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.activeFormatText = "\(selected.width)x\(selected.height) @ \(selected.fps) FPS (\(self.activeCodec.rawValue))"
                    }
                }
                if let captureDevice {
                    self.setInitialZoom(on: captureDevice)
                    self.applyLensSwitchingMode(on: captureDevice)
                    self.updateZoomCapabilities(for: captureDevice)
                }
                self.session.startRunning()
                self.startZoomPolling()
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "Camera streaming"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "Camera unavailable"
                    self?.warningText = error.localizedDescription
                }
            }
        }
    }

    private func configureSession() throws -> SelectedCameraFormat {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration() }

        guard let device = Self.cameraDevices(for: requestedPosition).first else {
            throw CameraCaptureError.noCamera
        }
        let selected = try applyFormat(requestedChoice, to: device)
        captureDevice = device
        observeSystemPressure(on: device)
        selectedFormatWarning = selected.warning
        displayZoomFactorMultiplier = Self.displayZoomFactorMultiplier(for: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)
        videoInput = input

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "iphonecam.capture.frames"))
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        videoOutput = output

        configureAudioSession(for: audioProfile)

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let aInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(aInput) {
                    session.addInput(aInput)
                    audioDeviceInput = aInput
                }
            } catch {
                print("[Audio] Failed to add audio input: \(error)")
            }
        }

        let aOutput = AVCaptureAudioDataOutput()
        aOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(aOutput) {
            session.addOutput(aOutput)
            audioOutput = aOutput
        }

        applyCurrentRotation()
        setInitialZoom(on: device)
        applyLensSwitchingMode(on: device)
        updateZoomCapabilities(for: device)
        publishCameraConfiguration(device: device, selected: selected)

        return selected
    }

    private func configureAudioSession(for profile: AudioProfile) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .record,
                mode: profile.avAudioSessionMode,
                options: [.allowBluetoothHFP]
            )
            try audioSession.setPreferredSampleRate(48000.0)
            try audioSession.setPreferredIOBufferDuration(1024.0 / 48000.0)
            if audioSession.maximumInputNumberOfChannels >= 2 {
                try? audioSession.setPreferredInputNumberOfChannels(2)
            }
            if let dataSources = audioSession.inputDataSources {
                for ds in dataSources {
                    if let patterns = ds.supportedPolarPatterns, patterns.contains(.stereo) {
                        try? ds.setPreferredPolarPattern(.stereo)
                        try? audioSession.setInputDataSource(ds)
                        break
                    }
                }
            }
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioSession] Setup error: \(error)")
        }
    }

    private func applyCurrentRotation() {
        guard let connection = videoOutput?.connection(with: .video) else {
            return
        }
        if connection.isVideoRotationAngleSupported(currentRotationAngle) {
            connection.videoRotationAngle = currentRotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        applyVideoStabilization(on: connection)
    }

    private func applyVideoStabilization(on connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else {
            publishStabilizationMode("Stabilization: unsupported")
            return
        }
        connection.preferredVideoStabilizationMode = requestedStabilizationMode.captureMode
        publishStabilizationMode(for: connection)
    }

    private func publishStabilizationModeIfNeeded(for connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastStabilizationModePublish) >= 1 else {
            return
        }
        lastStabilizationModePublish = now
        publishStabilizationMode(for: connection)
    }

    private func publishStabilizationMode(for connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else {
            publishStabilizationMode("Stabilization: unsupported")
            return
        }
        let active = Self.stabilizationModeName(connection.activeVideoStabilizationMode)
        let preferred = Self.stabilizationModeName(connection.preferredVideoStabilizationMode)
        publishStabilizationMode("Stabilization: \(active) active, \(preferred) preferred")
    }

    private func publishStabilizationMode(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.stabilizationModeText = text
        }
    }

    private static func stabilizationModeName(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off:
            return "off"
        case .standard:
            return "standard"
        case .cinematic:
            return "cinematic"
        case .cinematicExtended:
            return "cinematic extended"
        case .previewOptimized:
            return "preview optimized"
        case .cinematicExtendedEnhanced:
            return "cinematic extended enhanced"
        case .lowLatency:
            return "low latency"
        case .auto:
            return "auto"
        @unknown default:
            return "unknown"
        }
    }

    private static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .landscapeLeft:
            return 0
        case .landscapeRight:
            return 180
        default:
            return nil
        }
    }

    private static func rotationAngle(for orientation: UIInterfaceOrientation?) -> CGFloat? {
        switch orientation {
        case .landscapeRight:
            return 0
        case .landscapeLeft:
            return 180
        default:
            return nil
        }
    }

    private static func cameraDevices(for position: CameraPosition) -> [AVCaptureDevice] {
        guard position == .back else {
            return [AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)].compactMap { $0 }
        }
        // Virtual devices first: they move between lenses as the zoom changes.
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )

        var devices = preferredTypes.compactMap { type in
            discovery.devices.first { $0.deviceType == type }
        }
        if
            devices.isEmpty,
            let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        {
            devices.append(wide)
        }
        return devices
    }

    private static func displayZoomFactorMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(device.displayVideoZoomFactorMultiplier, 0.01)
        }

        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera:
            guard let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first else {
                return 0.5
            }
            return 1 / max(CGFloat(truncating: firstSwitchOver), 0.01)
        default:
            return 1
        }
    }

    /// The stream is 8-bit 4:2:0; formats are listed once per pixel format, so this skips the 10-bit duplicates.
    private static func isEightBit(_ format: AVCaptureDevice.Format) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func supports(_ format: AVCaptureDevice.Format, fps: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) + 0.01 && $0.maxFrameRate >= Double(fps) - 0.01
        }
    }

    static func supportedFrameRates(on device: AVCaptureDevice) -> [StreamResolution: [Int]] {
        var rates: [StreamResolution: Set<Int>] = [:]
        for format in device.formats where isEightBit(format) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard let resolution = StreamResolution(width: dimensions.width, height: dimensions.height) else {
                continue
            }
            for fps in CaptureFormatChoice.frameRates where supports(format, fps: fps) {
                rates[resolution, default: []].insert(fps)
            }
        }
        return rates.mapValues { $0.sorted() }
    }

    /// The closest choice the camera can deliver: the requested resolution at the nearest frame rate not above
    /// the request, else 1080p, else whatever it has.
    static func resolve(_ choice: CaptureFormatChoice, within rates: [StreamResolution: [Int]]) -> CaptureFormatChoice? {
        func pick(_ resolution: StreamResolution) -> CaptureFormatChoice? {
            guard let available = rates[resolution], !available.isEmpty else { return nil }
            if available.contains(choice.fps) {
                return CaptureFormatChoice(resolution: resolution, fps: choice.fps)
            }
            let fps = available.last(where: { $0 <= choice.fps }) ?? available[0]
            return CaptureFormatChoice(resolution: resolution, fps: fps)
        }
        return pick(choice.resolution)
            ?? pick(.hd1080)
            ?? StreamResolution.allCases.lazy.compactMap(pick).first
    }

    private static func bestFormat(on device: AVCaptureDevice, for choice: CaptureFormatChoice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return isEightBit(format)
                && Int(dimensions.width) == choice.resolution.width
                && Int(dimensions.height) == choice.resolution.height
                && supports(format, fps: choice.fps)
        }
        // Full range matches the stream's pixel format; unbinned formats use the whole sensor; the lowest
        // ceiling frame rate is the least compromised format that still reaches the request.
        return candidates.min { left, right in
            let leftKey = rankKey(left)
            let rightKey = rankKey(right)
            if leftKey.0 != rightKey.0 { return leftKey.0 < rightKey.0 }
            if leftKey.1 != rightKey.1 { return leftKey.1 < rightKey.1 }
            return leftKey.2 < rightKey.2
        }
    }

    private static func rankKey(_ format: AVCaptureDevice.Format) -> (Int, Int, Double) {
        let fullRange = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return (fullRange ? 0 : 1, format.isVideoBinned ? 1 : 0, maxRate)
    }

    /// Call inside a session configuration block.
    private func applyFormat(_ choice: CaptureFormatChoice, to device: AVCaptureDevice) throws -> SelectedCameraFormat {
        guard
            let resolved = Self.resolve(choice, within: Self.supportedFrameRates(on: device)),
            let format = Self.bestFormat(on: device, for: resolved)
        else {
            throw CameraCaptureError.noFormat
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        // Locked frame durations: a sagging cadence in low light would upset rate control and timing downstream,
        // so the image gets noisier instead.
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(resolved.fps))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()

        let warning = resolved == choice ? nil : "\(choice.label) unsupported on this camera; using \(resolved.label)."
        return SelectedCameraFormat(choice: resolved, warning: warning)
    }

    private func publishCameraConfiguration(device: AVCaptureDevice, selected: SelectedCameraFormat) {
        let rates = Self.supportedFrameRates(on: device)
        let position = requestedPosition
        DispatchQueue.main.async { [weak self] in
            self?.formatChoice = selected.choice
            self?.supportedFrameRates = rates
            self?.cameraPosition = position
        }
        publishImageControls()
    }

    private func applyLensSwitchingMode(on device: AVCaptureDevice) {
        guard device.isVirtualDevice else {
            publishLensSwitchingMode(requestedLensSwitchingMode)
            return
        }
        guard device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported else {
            publishLensSwitchingMode(.auto)
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setPrimaryConstituentDeviceSwitchingBehavior(
                requestedLensSwitchingMode.captureBehavior,
                restrictedSwitchingBehaviorConditions: []
            )
            publishLensSwitchingMode(requestedLensSwitchingMode)
        } catch {
            publishWarning(error.localizedDescription)
        }
    }

    private func publishLensSwitchingMode(_ mode: LensSwitchingMode) {
        DispatchQueue.main.async { [weak self] in
            self?.lensSwitchingMode = mode
        }
    }

    private func updateZoomCapabilities(for device: AVCaptureDevice) {
        let rawMinimum = displayedZoomFactor(forDeviceZoomFactor: device.minAvailableVideoZoomFactor)
        let maximum = displayedZoomFactor(forDeviceZoomFactor: maximumDeviceZoomFactor(for: device))
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { displayedZoomFactor(forDeviceZoomFactor: CGFloat(truncating: $0)) }
            .filter { $0 > 0 && $0 <= maximum }
        let inferredUltraWideMinimum = switchOvers.first.map { $0 / 2 } ?? rawMinimum
        let minimum = min(rawMinimum, inferredUltraWideMinimum)
        let cameraText = device.isVirtualDevice ? "Virtual camera: \(device.localizedName)" : "Single camera: \(device.localizedName)"
        let activeLensText = activeLensText(for: device)
        let lensSwitchingText = lensSwitchingText(for: device, switchOvers: switchOvers)
        let virtualWarning = device.isVirtualDevice ? nil : "Virtual camera unavailable; lens switching disabled."
        let warnings = [selectedFormatWarning, virtualWarning].compactMap { $0 }
        let currentZoom = displayedZoomFactor(forDeviceZoomFactor: device.videoZoomFactor)
        let currentMode = requestedLensSwitchingMode

        DispatchQueue.main.async { [weak self] in
            self?.minZoomFactor = minimum
            self?.maxZoomFactor = maximum
            self?.switchOverZoomFactors = switchOvers
            self?.zoomFactor = currentZoom
            self?.cameraModeText = cameraText
            self?.activeLensText = activeLensText
            self?.lensSwitchingText = lensSwitchingText
            self?.lensSwitchingMode = currentMode
            self?.warningText = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        }
    }

    private func startZoomPolling() {
        stopZoomPolling()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, let device = self.captureDevice else {
                return
            }
            self.publishZoom(device.videoZoomFactor)
            // Live readings (auto focus position, ISO, shutter, white balance) for the controls panel, twice a second.
            self.zoomPollTicks += 1
            if self.zoomPollTicks % 6 == 0 {
                self.publishImageControls()
            }
        }
        zoomPollTimer = timer
        timer.resume()
    }

    private func stopZoomPolling() {
        zoomPollTimer?.cancel()
        zoomPollTimer = nil
    }

    private func publishZoom(_ zoomFactor: CGFloat) {
        let displayedZoomFactor = displayedZoomFactor(forDeviceZoomFactor: zoomFactor)
        let currentActiveLensText = captureDevice.map { activeLensText(for: $0) } ?? "Lens: -"
        DispatchQueue.main.async { [weak self] in
            self?.zoomFactor = displayedZoomFactor
            self?.activeLensText = currentActiveLensText
        }
    }

    private func activeLensText(for device: AVCaptureDevice) -> String {
        guard device.isVirtualDevice else {
            return "Lens: \(Self.lensName(for: device))"
        }
        guard let activeDevice = device.activePrimaryConstituent else {
            return "Lens: selecting"
        }
        return "Lens: \(Self.lensName(for: activeDevice))"
    }

    private func lensSwitchingText(for device: AVCaptureDevice, switchOvers: [CGFloat]) -> String {
        guard device.isVirtualDevice else {
            return "Lens switching: unavailable"
        }
        let behavior = Self.switchingBehaviorName(device.activePrimaryConstituentDeviceSwitchingBehavior)
        let configured = Self.switchingBehaviorName(device.primaryConstituentDeviceSwitchingBehavior)
        let thresholds = switchOvers.isEmpty
            ? "no thresholds"
            : switchOvers.map { String(format: "%.1fx", $0) }.joined(separator: ", ")
        return "Lens switching: \(behavior) active, \(configured) set, \(thresholds)"
    }

    private static func lensName(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInWideAngleCamera:
            return "Wide"
        case .builtInTelephotoCamera:
            return "Tele"
        case .builtInDualCamera:
            return "Dual"
        case .builtInDualWideCamera:
            return "Dual Wide"
        case .builtInTripleCamera:
            return "Triple"
        default:
            return device.localizedName
        }
    }

    private static func switchingBehaviorName(_ behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior) -> String {
        switch behavior {
        case .unsupported:
            return "unsupported"
        case .auto:
            return "auto"
        case .restricted:
            return "restricted"
        case .locked:
            return "locked"
        @unknown default:
            return "unknown"
        }
    }

    private func publishWarning(_ warning: String) {
        DispatchQueue.main.async { [weak self] in
            self?.warningText = warning
        }
    }

    private func stopContinuousZoomOnQueue() {
        guard let device = captureDevice else {
            return
        }
        lastContinuousZoomIntensity = 0
        lastContinuousZoomCommand = .distantPast
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.cancelVideoZoomRamp()
            publishZoom(device.videoZoomFactor)
        } catch {
            publishWarning(error.localizedDescription)
        }
    }

    private func setInitialZoom(on device: AVCaptureDevice) {
        let target = clampedDeviceZoomFactor(forDisplayedFactor: 1, on: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = target
        } catch {
            publishWarning(error.localizedDescription)
        }
    }

    private func clampedDeviceZoomFactor(forDisplayedFactor factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        let deviceFactor = deviceZoomFactor(forDisplayedZoomFactor: factor)
        return min(max(deviceFactor, device.minAvailableVideoZoomFactor), maximumDeviceZoomFactor(for: device))
    }

    private func maximumDeviceZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let displayedLimitAsDeviceFactor = deviceZoomFactor(forDisplayedZoomFactor: maximumPresentedZoomFactor)
        return min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor, displayedLimitAsDeviceFactor)
    }

    private func displayedZoomFactor(forDeviceZoomFactor factor: CGFloat) -> CGFloat {
        factor * displayZoomFactorMultiplier
    }

    private func deviceZoomFactor(forDisplayedZoomFactor factor: CGFloat) -> CGFloat {
        factor / displayZoomFactorMultiplier
    }
}

// MARK: - Format, camera and image controls

extension CameraCaptureController {
    func setFormat(_ choice: CaptureFormatChoice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedChoice = choice
            guard self.configured, let device = self.captureDevice else { return }
            // A new active format resets the zoom, which on a multi-lens camera would jump to the ultra wide.
            let zoom = device.videoZoomFactor
            self.stopContinuousZoomOnQueue()
            self.session.beginConfiguration()
            let selected: SelectedCameraFormat
            do {
                selected = try self.applyFormat(choice, to: device)
            } catch {
                self.session.commitConfiguration()
                self.publishWarning(error.localizedDescription)
                return
            }
            self.session.commitConfiguration()
            self.withDevice { device in
                device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), self.maximumDeviceZoomFactor(for: device))
            }
            self.applyLensSwitchingMode(on: device)
            self.didChangeCameraOrFormat(device: device, selected: selected)
        }
    }

    func setCameraPosition(_ position: CameraPosition) {
        sessionQueue.async { [weak self] in
            guard let self, self.requestedPosition != position else { return }
            let previousPosition = self.requestedPosition
            self.requestedPosition = position
            guard self.configured, let oldInput = self.videoInput else { return }
            guard let device = Self.cameraDevices(for: position).first else {
                self.requestedPosition = previousPosition
                self.publishWarning("This iPhone has no \(position.label.lowercased()) camera.")
                return
            }

            self.stopContinuousZoomOnQueue()
            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            do {
                let selected = try self.applyFormat(self.requestedChoice, to: device)
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw CameraCaptureError.cannotAddInput
                }
                self.session.addInput(input)
                self.session.commitConfiguration()

                self.videoInput = input
                self.captureDevice = device
                self.observeSystemPressure(on: device)
                self.displayZoomFactorMultiplier = Self.displayZoomFactorMultiplier(for: device)
                // A different sensor: start from auto rather than carry over values measured on the old one.
                self.requestedControls = ImageControlsState()
                self.lockedLensPosition = nil
                self.lockedWhiteBalanceGains = nil
                self.setInitialZoom(on: device)
                self.applyLensSwitchingMode(on: device)
                self.didChangeCameraOrFormat(device: device, selected: selected)
            } catch {
                if self.session.canAddInput(oldInput) {
                    self.session.addInput(oldInput)
                }
                self.session.commitConfiguration()
                self.requestedPosition = previousPosition
                self.publishWarning(error.localizedDescription)
            }
        }
    }

    /// Follow-up for a new camera or format: the encoder, rotation, zoom limits and the user's image settings all
    /// depend on the active format.
    private func didChangeCameraOrFormat(device: AVCaptureDevice, selected: SelectedCameraFormat) {
        selectedCameraFormat = selected
        selectedFormatWarning = selected.warning
        // The sender starts a new bitrate budget for the new format and reports it.
        targetBitrate = nil
        rebuildEncoder()
        applyCurrentRotation()
        updateZoomCapabilities(for: device)
        publishZoom(device.videoZoomFactor)
        withDevice { device in
            self.applyFocus(on: device)
            try self.applyExposure(on: device)
            self.applyWhiteBalance(on: device)
            try self.applyTorch(on: device)
        }
        publishCameraConfiguration(device: device, selected: selected)
    }

    // MARK: Focus

    func setFocusMode(_ mode: FocusControlMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.focusMode = mode
            self.lockedLensPosition = nil
            self.withDevice { self.applyFocus(on: $0) }
        }
    }

    func setLensPosition(_ position: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.focusMode = .locked
            self.lockedLensPosition = min(max(position, 0), 1)
            self.withDevice { self.applyFocus(on: $0) }
        }
    }

    /// `point` is normalized in the streamed picture, (0, 0) at its top-left.
    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Point of interest coordinates follow the sensor, which matches the picture at 0° and is flipped at 180°.
            let devicePoint = self.currentRotationAngle == 180 ? CGPoint(x: 1 - point.x, y: 1 - point.y) : point
            self.requestedControls.focusMode = .auto
            self.lockedLensPosition = nil
            if self.requestedControls.exposureMode == .locked {
                self.requestedControls.exposureMode = .auto
            }
            self.withDevice { device in
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                self.applyFocus(on: device)
                if self.requestedControls.exposureMode == .auto, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                try self.applyExposure(on: device)
            }
        }
    }

    private func applyFocus(on device: AVCaptureDevice) {
        switch requestedControls.focusMode {
        case .auto:
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        case .locked:
            if let lensPosition = lockedLensPosition, device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
            } else if device.isFocusModeSupported(.locked) {
                // Lock where auto focus is now, and remember it for later re-applies.
                lockedLensPosition = device.lensPosition
                device.focusMode = .locked
            }
        }
    }

    // MARK: Exposure

    func setExposureMode(_ mode: ExposureControlMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if mode == .manual {
                self.seedManualExposureFromCamera()
            }
            self.requestedControls.exposureMode = mode
            self.withDevice { try self.applyExposure(on: $0) }
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.exposureBias = bias
            self.withDevice { self.applyExposureBias(on: $0) }
        }
    }

    func setISO(_ iso: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.seedManualExposureFromCamera()
            self.requestedControls.exposureMode = .manual
            self.requestedControls.iso = iso
            self.withDevice { try self.applyExposure(on: $0) }
        }
    }

    func setShutter(seconds: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.seedManualExposureFromCamera()
            self.requestedControls.exposureMode = .manual
            self.requestedControls.shutterSeconds = seconds
            self.withDevice { try self.applyExposure(on: $0) }
        }
    }

    /// One third of a stop per step: exposure bias in auto, ISO in manual.
    func adjustExposure(steps: Int) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            if self.requestedControls.exposureMode == .manual {
                let iso = self.requestedControls.iso * pow(2, Float(steps) / 3)
                self.requestedControls.iso = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                self.withDevice { try self.applyExposure(on: $0) }
            } else {
                let bias = self.requestedControls.exposureBias + Float(steps) / 3
                self.requestedControls.exposureBias = min(max(bias, -3), 3)
                self.withDevice { self.applyExposureBias(on: $0) }
            }
        }
    }

    /// Manual starts from what auto exposure was doing, so switching to it does not jump the picture.
    private func seedManualExposureFromCamera() {
        guard requestedControls.exposureMode != .manual, let device = captureDevice else { return }
        requestedControls.iso = device.iso
        let seconds = device.exposureDuration.seconds
        if seconds.isFinite, seconds > 0 {
            requestedControls.shutterSeconds = seconds
        }
    }

    private func longestShutterSeconds(on device: AVCaptureDevice) -> Double {
        // Anything longer than a frame would slow the frame rate.
        let frame = 1.0 / Double(selectedCameraFormat?.fps ?? 30)
        return max(device.activeFormat.minExposureDuration.seconds, min(device.activeFormat.maxExposureDuration.seconds, frame))
    }

    private func applyExposure(on device: AVCaptureDevice) throws {
        switch requestedControls.exposureMode {
        case .auto:
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        case .locked:
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        case .manual:
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let iso = min(max(requestedControls.iso, format.minISO), format.maxISO)
            let shutter = min(max(requestedControls.shutterSeconds, format.minExposureDuration.seconds), longestShutterSeconds(on: device))
            device.setExposureModeCustom(
                duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000_000),
                iso: iso,
                completionHandler: nil
            )
        }
        applyExposureBias(on: device)
    }

    private func applyExposureBias(on device: AVCaptureDevice) {
        let bias = min(max(requestedControls.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(bias, completionHandler: nil)
    }

    // MARK: White balance

    func setWhiteBalanceMode(_ mode: WhiteBalanceControlMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if mode == .manual, self.requestedControls.whiteBalanceMode != .manual, let device = self.captureDevice {
                self.requestedControls.temperature = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
            }
            self.requestedControls.whiteBalanceMode = mode
            self.lockedWhiteBalanceGains = nil
            self.withDevice { self.applyWhiteBalance(on: $0) }
        }
    }

    func setTemperature(_ kelvin: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.whiteBalanceMode = .manual
            self.requestedControls.temperature = kelvin
            self.withDevice { self.applyWhiteBalance(on: $0) }
        }
    }

    /// Locks white balance so the scene averages to neutral: point the camera at white paper or a gray card first.
    func calibrateWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.withDevice { device in
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                let gains = Self.clamped(device.grayWorldDeviceWhiteBalanceGains, on: device)
                self.lockedWhiteBalanceGains = gains
                self.requestedControls.whiteBalanceMode = .locked
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance(on device: AVCaptureDevice) {
        switch requestedControls.whiteBalanceMode {
        case .auto:
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        case .locked:
            if let gains = lockedWhiteBalanceGains, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                device.setWhiteBalanceModeLocked(with: Self.clamped(gains, on: device), completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.locked) {
                lockedWhiteBalanceGains = device.deviceWhiteBalanceGains
                device.whiteBalanceMode = .locked
            }
        case .manual:
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: requestedControls.temperature, tint: 0)
            device.setWhiteBalanceModeLocked(with: Self.clamped(device.deviceWhiteBalanceGains(for: values), on: device), completionHandler: nil)
        }
    }

    private static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, on device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ value: Float) -> Float { min(max(value, 1), device.maxWhiteBalanceGain) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain), greenGain: clamp(gains.greenGain), blueGain: clamp(gains.blueGain))
    }

    // MARK: Torch

    func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.torchOn = on
            self.withDevice { try self.applyTorch(on: $0) }
        }
    }

    func setTorchLevel(_ level: Float) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.torchLevel = level
            self.requestedControls.torchOn = true
            self.withDevice { try self.applyTorch(on: $0) }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.torchOn.toggle()
            self.withDevice { try self.applyTorch(on: $0) }
        }
    }

    private func applyTorch(on device: AVCaptureDevice) throws {
        guard device.hasTorch, device.isTorchModeSupported(.on) else { return }
        if requestedControls.torchOn {
            // iOS may cap the torch lower while the phone is hot.
            let ceiling = min(1, AVCaptureDevice.maxAvailableTorchLevel)
            try device.setTorchModeOn(level: min(max(requestedControls.torchLevel, 0.05), ceiling))
        } else if device.torchMode != .off {
            device.torchMode = .off
        }
    }

    // MARK: Remote shortcuts

    /// Locks focus and exposure where they are, or hands both back to auto when either is already fixed.
    func toggleFocusExposureLock() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let anyFixed = self.requestedControls.focusMode != .auto || self.requestedControls.exposureMode != .auto
            self.requestedControls.focusMode = anyFixed ? .auto : .locked
            self.requestedControls.exposureMode = anyFixed ? .auto : .locked
            self.lockedLensPosition = nil
            self.withDevice { device in
                self.applyFocus(on: device)
                try self.applyExposure(on: device)
            }
        }
    }

    func toggleWhiteBalanceLock() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedControls.whiteBalanceMode = self.requestedControls.whiteBalanceMode == .auto ? .locked : .auto
            self.lockedWhiteBalanceGains = nil
            self.withDevice { self.applyWhiteBalance(on: $0) }
        }
    }

    func resetImageControls() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let torchOn = self.requestedControls.torchOn
            let torchLevel = self.requestedControls.torchLevel
            self.requestedControls = ImageControlsState()
            self.requestedControls.torchOn = torchOn
            self.requestedControls.torchLevel = torchLevel
            self.lockedLensPosition = nil
            self.lockedWhiteBalanceGains = nil
            self.withDevice { device in
                let center = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = center
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = center
                }
                self.applyFocus(on: device)
                try self.applyExposure(on: device)
                self.applyWhiteBalance(on: device)
            }
        }
    }

    // MARK: Plumbing

    /// Runs `body` with the device locked for configuration, then publishes the new state. Session queue only.
    private func withDevice(_ body: (AVCaptureDevice) throws -> Void) {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try body(device)
        } catch {
            publishWarning(error.localizedDescription)
        }
        publishImageControls()
    }

    /// Requested modes plus the camera's live readings, for the controls panel. Session queue only.
    func publishImageControls() {
        guard let device = captureDevice else { return }
        let format = device.activeFormat
        var state = requestedControls
        state.supportsFocusLock = device.isFocusModeSupported(.locked)
        state.lensPosition = device.lensPosition
        state.supportsManualExposure = device.isExposureModeSupported(.custom)
        state.exposureBias = device.exposureTargetBias
        state.exposureBiasRange = max(device.minExposureTargetBias, -3)...min(device.maxExposureTargetBias, 3)
        state.isoRange = format.minISO...max(format.minISO, format.maxISO)
        state.iso = device.iso
        state.shutterRange = format.minExposureDuration.seconds...longestShutterSeconds(on: device)
        let shutter = device.exposureDuration.seconds
        if shutter.isFinite, shutter > 0 {
            state.shutterSeconds = shutter
        }
        state.supportsWhiteBalanceLock = device.isWhiteBalanceModeSupported(.locked)
        if requestedControls.whiteBalanceMode != .manual {
            state.temperature = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
        }
        state.hasTorch = device.hasTorch && device.isTorchModeSupported(.on)
        state.torchOn = device.torchMode == .on
        DispatchQueue.main.async { [weak self] in
            guard let self, self.imageControls != state else { return }
            self.imageControls = state
        }
    }
}

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            encoder?.encode(sampleBuffer)
            onPreviewSample?(sampleBuffer)
            publishStabilizationModeIfNeeded(for: connection)
        } else if output == audioOutput {
            audioEncoder.encode(sampleBuffer: sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCaptureFrameCount += 1
            }
        }
    }
}

private struct SelectedCameraFormat {
    let choice: CaptureFormatChoice
    let warning: String?

    var width: Int { choice.resolution.width }
    var height: Int { choice.resolution.height }
    var fps: Int { choice.fps }
}

private enum CameraCaptureError: LocalizedError {
    case noCamera
    case noFormat
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera was found at that position."
        case .noFormat:
            return "This camera has no 720p, 1080p or 4K format."
        case .cannotAddInput:
            return "The camera input could not be added."
        case .cannotAddOutput:
            return "The video output could not be added."
        }
    }
}
