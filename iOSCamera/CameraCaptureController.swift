import AVFoundation
import Foundation
import UIKit

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

    let session = AVCaptureSession()

    var onFormat: ((H264Format) -> Void)?
    var onEncodedSample: ((EncodedH264Sample) -> Void)?

    private let sessionQueue = DispatchQueue(label: "iphonecam.capture.session")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?
    private var encoder: H264Encoder?
    private var zoomPollTimer: DispatchSourceTimer?
    private var configured = false
    private var currentRotationAngle: CGFloat = 0
    private var displayZoomFactorMultiplier: CGFloat = 1
    private var lastContinuousZoomIntensity: Double = 0
    private var lastContinuousZoomCommand = Date.distantPast
    private let maximumPresentedZoomFactor: CGFloat = 8

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndStart()
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

    func stop() {
        sessionQueue.async { [weak self] in
            self?.stopContinuousZoomOnQueue()
            self?.stopZoomPolling()
            self?.session.stopRunning()
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

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured {
                    let selected = try self.configureSession()
                    let encoder = H264Encoder(
                        width: selected.width,
                        height: selected.height,
                        fps: selected.fps,
                        bitrate: CameraProtocol.targetBitrate
                    )
                    encoder.onFormat = { [weak self] format in
                        self?.onFormat?(format)
                    }
                    encoder.onSample = { [weak self] sample in
                        self?.onEncodedSample?(sample)
                    }
                    self.encoder = encoder
                    self.configured = true
                    DispatchQueue.main.async { [weak self] in
                        self?.activeFormatText = "\(selected.width)x\(selected.height) @ \(selected.fps) FPS"
                    }
                }
                if let captureDevice {
                    self.setInitialZoom(on: captureDevice)
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

        let selection = try selectBackCamera()
        let device = selection.device
        let selected = selection.format
        captureDevice = device
        displayZoomFactorMultiplier = Self.displayZoomFactorMultiplier(for: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

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

        applyCurrentRotation()
        setInitialZoom(on: device)
        updateZoomCapabilities(for: device, selectedFormat: selected)

        return selected
    }

    private func applyCurrentRotation() {
        guard let connection = videoOutput?.connection(with: .video) else {
            return
        }
        if connection.isVideoRotationAngleSupported(currentRotationAngle) {
            connection.videoRotationAngle = currentRotationAngle
        }
        connection.isVideoMirrored = false
        applyVideoStabilization(on: connection)
    }

    private func applyVideoStabilization(on connection: AVCaptureConnection) {
        guard connection.isVideoStabilizationSupported else {
            return
        }
        connection.preferredVideoStabilizationMode = .standard
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

    private func selectBackCamera() throws -> (device: AVCaptureDevice, format: SelectedCameraFormat) {
        let devices = Self.preferredBackCameras()
        guard !devices.isEmpty else {
            throw CameraCaptureError.noBackCamera
        }

        for device in devices {
            if let format = try? selectFormat(on: device) {
                return (device, format)
            }
        }

        throw CameraCaptureError.no1080pFormat
    }

    private static func preferredBackCameras() -> [AVCaptureDevice] {
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

    private func selectFormat(on device: AVCaptureDevice) throws -> SelectedCameraFormat {
        let targetWidth = Int32(CameraProtocol.targetWidth)
        let targetHeight = Int32(CameraProtocol.targetHeight)

        let matchingFormats = device.formats.compactMap { format -> (AVCaptureDevice.Format, Double)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == targetWidth, dimensions.height == targetHeight else {
                return nil
            }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS > 0 else {
                return nil
            }
            return (format, maxFPS)
        }

        guard let best = matchingFormats.sorted(by: { left, right in
            abs(left.1 - Double(CameraProtocol.targetFPS)) < abs(right.1 - Double(CameraProtocol.targetFPS))
        }).first else {
            throw CameraCaptureError.no1080pFormat
        }

        let fps = Int(min(Double(CameraProtocol.targetFPS), best.1).rounded(.down))
        try device.lockForConfiguration()
        device.activeFormat = best.0
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()

        let warning = fps == CameraProtocol.targetFPS ? nil : "1080p60 unsupported; using 1080p\(fps)."
        return SelectedCameraFormat(width: CameraProtocol.targetWidth, height: CameraProtocol.targetHeight, fps: fps, warning: warning)
    }

    private func updateZoomCapabilities(for device: AVCaptureDevice, selectedFormat: SelectedCameraFormat) {
        let minimum = displayedZoomFactor(forDeviceZoomFactor: device.minAvailableVideoZoomFactor)
        let maximum = displayedZoomFactor(forDeviceZoomFactor: maximumDeviceZoomFactor(for: device))
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { displayedZoomFactor(forDeviceZoomFactor: CGFloat(truncating: $0)) }
            .filter { $0 >= minimum && $0 <= maximum }
        let cameraText = device.isVirtualDevice ? "Virtual camera: \(device.localizedName)" : "Single camera: \(device.localizedName)"
        let virtualWarning = device.isVirtualDevice ? nil : "Virtual camera unavailable; lens switching disabled."
        let warnings = [selectedFormat.warning, virtualWarning].compactMap { $0 }
        let currentZoom = displayedZoomFactor(forDeviceZoomFactor: device.videoZoomFactor)

        DispatchQueue.main.async { [weak self] in
            self?.minZoomFactor = minimum
            self?.maxZoomFactor = maximum
            self?.switchOverZoomFactors = switchOvers
            self?.zoomFactor = currentZoom
            self?.cameraModeText = cameraText
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
        DispatchQueue.main.async { [weak self] in
            self?.zoomFactor = displayedZoomFactor
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

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder?.encode(sampleBuffer)
    }
}

private struct SelectedCameraFormat {
    let width: Int
    let height: Int
    let fps: Int
    let warning: String?
}

private enum CameraCaptureError: LocalizedError {
    case noBackCamera
    case no1080pFormat
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noBackCamera:
            return "No back camera was found."
        case .no1080pFormat:
            return "This device does not expose a 1920x1080 capture format."
        case .cannotAddInput:
            return "The camera input could not be added."
        case .cannotAddOutput:
            return "The video output could not be added."
        }
    }
}
