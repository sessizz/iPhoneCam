import AVFoundation
import Foundation
import UIKit

final class CameraCaptureController: NSObject, ObservableObject, @unchecked Sendable {
    @Published var statusText = "Camera warming up..."
    @Published var warningText: String?
    @Published var activeFormatText = "1080p60 target"
    @Published private(set) var videoRotationAngle: CGFloat = 0

    let session = AVCaptureSession()

    var onFormat: ((H264Format) -> Void)?
    var onEncodedSample: ((EncodedH264Sample) -> Void)?

    private let sessionQueue = DispatchQueue(label: "iphonecam.capture.session")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var encoder: H264Encoder?
    private var configured = false
    private var currentRotationAngle: CGFloat = 0

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
            self?.session.stopRunning()
        }
    }

    func updateVideoRotation(for orientation: UIDeviceOrientation) {
        guard let angle = Self.rotationAngle(for: orientation) else {
            return
        }
        currentRotationAngle = angle
        videoRotationAngle = angle
        sessionQueue.async { [weak self] in
            self?.applyCurrentRotation()
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
                        self?.warningText = selected.warning
                    }
                }
                self.session.startRunning()
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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraCaptureError.noBackCamera
        }

        let selected = try selectFormat(on: device)

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
    }

    private static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .landscapeRight:
            return 0
        case .landscapeLeft:
            return 180
        default:
            return nil
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
