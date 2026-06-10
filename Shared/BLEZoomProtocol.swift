import Foundation

public enum BLEZoomProtocol {
    public static let deviceName = "iPhoneCam Zoom"
    public static let serviceUUIDString = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A0"
    public static let joystickCharacteristicUUIDString = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A1"
    public static let displayCharacteristicUUIDString = "7D2F6C7E-1B2F-4B3A-9E23-55F2C66B71A2"
}

public struct BLEZoomJoystickFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let resetZoom = BLEZoomJoystickFlags(rawValue: 1 << 0)
    public static let calibrated = BLEZoomJoystickFlags(rawValue: 1 << 1)
}

public struct BLEZoomJoystickReport: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let byteLength = 8

    public let flags: BLEZoomJoystickFlags
    public let x: Int16
    public let y: Int16
    public let sequence: UInt16

    public init(flags: BLEZoomJoystickFlags = [], x: Int16, y: Int16, sequence: UInt16) {
        self.flags = flags
        self.x = x
        self.y = y
        self.sequence = sequence
    }

    public init?(data: Data) {
        guard data.count >= Self.byteLength, data[0] == Self.version else {
            return nil
        }
        flags = BLEZoomJoystickFlags(rawValue: data[1])
        x = Self.readInt16LE(data, at: 2)
        y = Self.readInt16LE(data, at: 4)
        sequence = Self.readUInt16LE(data, at: 6)
    }

    public var normalizedX: Double {
        Self.normalizedAxis(x)
    }

    public var normalizedY: Double {
        Self.normalizedAxis(y)
    }

    private static func normalizedAxis(_ value: Int16) -> Double {
        if value == Int16.min {
            return -1
        }
        return max(-1, min(1, Double(value) / Double(Int16.max)))
    }

    private static func readInt16LE(_ data: Data, at offset: Int) -> Int16 {
        let raw = readUInt16LE(data, at: offset)
        return Int16(bitPattern: raw)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}

public struct BLEZoomSettings: Equatable, Sendable {
    public var deadzone: Double
    public var minimumSpeed: Double
    public var maximumSpeed: Double
    public var curveExponent: Double
    public var swapAxes: Bool
    public var invertZoomAxis: Bool
    public var invertSnapAxis: Bool

    public init(
        deadzone: Double = 0.08,
        minimumSpeed: Double = 0.12,
        maximumSpeed: Double = 1.0,
        curveExponent: Double = 1.6,
        swapAxes: Bool = false,
        invertZoomAxis: Bool = false,
        invertSnapAxis: Bool = false
    ) {
        self.deadzone = deadzone
        self.minimumSpeed = minimumSpeed
        self.maximumSpeed = maximumSpeed
        self.curveExponent = curveExponent
        self.swapAxes = swapAxes
        self.invertZoomAxis = invertZoomAxis
        self.invertSnapAxis = invertSnapAxis
    }

    public static let defaults = BLEZoomSettings()
}

public struct BLEZoomMappingResult: Equatable, Sendable {
    public let intensity: Double

    public init(intensity: Double) {
        self.intensity = max(-1, min(1, intensity))
    }

    public var signedSpeedPercent: Int {
        Int((intensity * 100).rounded())
    }

    public var isActive: Bool {
        abs(intensity) > 0.0001
    }
}

public enum BLEZoomSnapDirection: Equatable, Sendable {
    case down
    case up
}

public struct BLEZoomSnapResult: Equatable, Sendable {
    public let direction: BLEZoomSnapDirection
    public let targetZoomFactor: Double

    public init(direction: BLEZoomSnapDirection, targetZoomFactor: Double) {
        self.direction = direction
        self.targetZoomFactor = targetZoomFactor
    }
}

public enum BLEZoomMapper {
    public static func map(report: BLEZoomJoystickReport, settings: BLEZoomSettings) -> BLEZoomMappingResult {
        BLEZoomMappingResult(intensity: intensity(forAxis: zoomAxis(from: report, settings: settings), settings: settings))
    }

    public static func zoomAxis(from report: BLEZoomJoystickReport, settings: BLEZoomSettings) -> Double {
        let axis = settings.swapAxes ? report.normalizedX : report.normalizedY
        return settings.invertZoomAxis ? -axis : axis
    }

    public static func snapAxis(from report: BLEZoomJoystickReport, settings: BLEZoomSettings) -> Double {
        let axis = settings.swapAxes ? report.normalizedY : report.normalizedX
        return settings.invertSnapAxis ? -axis : axis
    }

    public static func intensity(forAxis axis: Double, settings: BLEZoomSettings) -> Double {
        let clampedAxis = max(-1, min(1, axis))
        let magnitude = abs(clampedAxis)
        let deadzone = max(0, min(0.95, settings.deadzone))

        guard magnitude > deadzone else {
            return 0
        }

        let adjusted = (magnitude - deadzone) / max(0.01, 1 - deadzone)
        let exponent = max(0.2, min(5.0, settings.curveExponent))
        let curved = pow(adjusted, exponent)
        let minimumSpeed = max(0.01, min(1, settings.minimumSpeed))
        let maximumSpeed = max(minimumSpeed, min(1, settings.maximumSpeed))
        let speed = minimumSpeed + curved * (maximumSpeed - minimumSpeed)
        return clampedAxis >= 0 ? speed : -speed
    }

    public static func snapTarget(
        forAxis axis: Double,
        currentZoomFactor: Double,
        minZoomFactor: Double,
        maxZoomFactor: Double,
        activationThreshold: Double = 0.70
    ) -> BLEZoomSnapResult? {
        let clampedAxis = max(-1, min(1, axis))
        let threshold = max(0.2, min(0.99, activationThreshold))
        guard abs(clampedAxis) >= threshold else {
            return nil
        }

        let direction: BLEZoomSnapDirection = clampedAxis < 0 ? .down : .up
        let nearestInteger = currentZoomFactor.rounded()
        let isAlreadyInteger = abs(currentZoomFactor - nearestInteger) < 0.0001
        let rounded: Double
        if direction == .down {
            rounded = isAlreadyInteger ? nearestInteger - 1 : floor(currentZoomFactor)
        } else {
            rounded = isAlreadyInteger ? nearestInteger + 1 : ceil(currentZoomFactor)
        }
        let lowerBound = min(minZoomFactor, maxZoomFactor)
        let upperBound = max(minZoomFactor, maxZoomFactor)
        let target = min(max(rounded, lowerBound), upperBound)
        return BLEZoomSnapResult(direction: direction, targetZoomFactor: target)
    }
}

public struct BLEZoomDisplayFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let connected = BLEZoomDisplayFlags(rawValue: 1 << 0)
    public static let zooming = BLEZoomDisplayFlags(rawValue: 1 << 1)
}

public struct BLEZoomDisplayState: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let byteLength = 8

    public let flags: BLEZoomDisplayFlags
    public let zoomFactor: Double
    public let signedSpeedPercent: Int
    public let sequence: UInt16

    public init(flags: BLEZoomDisplayFlags, zoomFactor: Double, signedSpeedPercent: Int, sequence: UInt16) {
        self.flags = flags
        self.zoomFactor = max(0, zoomFactor)
        self.signedSpeedPercent = max(-100, min(100, signedSpeedPercent))
        self.sequence = sequence
    }

    public init(zoomFactor: Double, intensity: Double, connected: Bool, sequence: UInt16) {
        var flags: BLEZoomDisplayFlags = connected ? .connected : []
        if abs(intensity) > 0.0001 {
            flags.insert(.zooming)
        }
        self.init(
            flags: flags,
            zoomFactor: zoomFactor,
            signedSpeedPercent: Int((max(-1, min(1, intensity)) * 100).rounded()),
            sequence: sequence
        )
    }

    public func encoded() -> Data {
        let zoomCenti = UInt16(max(0, min(655.35, zoomFactor)) * 100)
        var data = Data()
        data.reserveCapacity(Self.byteLength)
        data.append(Self.version)
        data.append(flags.rawValue)
        data.appendUInt16LE(zoomCenti)
        data.append(UInt8(bitPattern: Int8(max(-100, min(100, signedSpeedPercent)))))
        data.append(0)
        data.appendUInt16LE(sequence)
        return data
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value & 0xFF00) >> 8))
    }
}
