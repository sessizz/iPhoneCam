import AVFoundation
import Foundation

enum StreamResolution: String, CaseIterable, Identifiable, Sendable {
    case hd720
    case hd1080
    case uhd4k

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hd720:
            return "720p"
        case .hd1080:
            return "1080p"
        case .uhd4k:
            return "4K"
        }
    }

    var width: Int {
        switch self {
        case .hd720:
            return 1280
        case .hd1080:
            return 1920
        case .uhd4k:
            return 3840
        }
    }

    var height: Int {
        switch self {
        case .hd720:
            return 720
        case .hd1080:
            return 1080
        case .uhd4k:
            return 2160
        }
    }

    init?(width: Int32, height: Int32) {
        guard let match = Self.allCases.first(where: { $0.width == Int(width) && $0.height == Int(height) }) else {
            return nil
        }
        self = match
    }
}

struct CaptureFormatChoice: Equatable, Sendable {
    var resolution: StreamResolution
    var fps: Int

    static let standard = CaptureFormatChoice(resolution: .hd1080, fps: 60)

    /// Frame rates offered when the camera supports them at the chosen resolution.
    static let frameRates = [24, 30, 60, 120, 240]

    var label: String {
        "\(resolution.label)\(fps)"
    }
}

enum CameraPosition: String, CaseIterable, Identifiable, Sendable {
    case back
    case front

    var id: String { rawValue }

    var label: String {
        switch self {
        case .back:
            return "Back"
        case .front:
            return "Front"
        }
    }

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .back:
            return .back
        case .front:
            return .front
        }
    }
}

enum FocusControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case locked

    var id: String { rawValue }
    var label: String { self == .auto ? "Auto" : "Lock" }
}

enum ExposureControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case locked
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .locked:
            return "Lock"
        case .manual:
            return "Manual"
        }
    }
}

enum WhiteBalanceControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case locked
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .locked:
            return "Lock"
        case .manual:
            return "Kelvin"
        }
    }
}

/// What the camera controls panel shows: the requested modes plus the camera's live readings and ranges.
struct ImageControlsState: Equatable, Sendable {
    var focusMode: FocusControlMode = .auto
    var lensPosition: Float = 0.5
    var supportsFocusLock = false

    var exposureMode: ExposureControlMode = .auto
    var exposureBias: Float = 0
    var exposureBiasRange: ClosedRange<Float> = -2...2
    var iso: Float = 100
    var isoRange: ClosedRange<Float> = 25...2000
    var shutterSeconds: Double = 1.0 / 60
    var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    var supportsManualExposure = false

    var whiteBalanceMode: WhiteBalanceControlMode = .auto
    var temperature: Float = 5000
    var supportsWhiteBalanceLock = false
    /// Kelvin and gray-card calibration lock to custom gains, which some front cameras do not allow.
    var supportsCustomWhiteBalance = false

    var hasTorch = false
    var torchOn = false
    var torchLevel: Float = 1
}

/// Format and camera state for the format sheet and toolbar, kept apart from the capture controller's
/// fast-changing readings (zoom, audio level) so those do not re-render the menus while they are open.
final class CameraFormatState: ObservableObject {
    @Published var formatChoice = CaptureFormatChoice.standard
    /// Frame rates the active camera offers per resolution.
    @Published var supportedFrameRates: [StreamResolution: [Int]] = [:]
    @Published var cameraPosition: CameraPosition = .back
}

/// The image controls panel's state, published at most twice a second and only when it changes.
final class ImageControlsStore: ObservableObject {
    @Published var state = ImageControlsState()
}
