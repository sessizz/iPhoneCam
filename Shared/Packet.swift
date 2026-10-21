import Foundation

public enum CameraPacketKind: UInt8, Sendable {
    case hello = 1
    case format = 2
    case frameFragment = 3
    case control = 4
    case audio = 5
}

public struct CameraPacketFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let keyFrame = CameraPacketFlags(rawValue: 1 << 0)
}

public struct CameraPacket: Equatable, Sendable {
    public static let magic: UInt32 = 0x4950434D
    public static let version: UInt8 = 1
    public static let headerLength = 36
    public static let targetDatagramSize = 1_400
    public static let maxPayloadSize = targetDatagramSize - headerLength

    public let kind: CameraPacketKind
    public let flags: CameraPacketFlags
    public let streamId: UInt32
    /// For frame fragments: a per-connection send sequence that goes up by one for every encoded frame,
    /// so a gap means the receiver missed a frame and must wait for the next keyframe.
    public let frameId: UInt64
    public let ptsNanos: UInt64
    public let packetIndex: UInt16
    public let packetCount: UInt16
    public let payload: Data

    public init(
        kind: CameraPacketKind,
        flags: CameraPacketFlags = [],
        streamId: UInt32,
        frameId: UInt64 = 0,
        ptsNanos: UInt64 = 0,
        packetIndex: UInt16 = 0,
        packetCount: UInt16 = 1,
        payload: Data
    ) {
        self.kind = kind
        self.flags = flags
        self.streamId = streamId
        self.frameId = frameId
        self.ptsNanos = ptsNanos
        self.packetIndex = packetIndex
        self.packetCount = packetCount
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerLength + payload.count)
        data.appendUInt32BE(Self.magic)
        data.append(Self.version)
        data.append(kind.rawValue)
        data.appendUInt16BE(flags.rawValue)
        data.appendUInt32BE(streamId)
        data.appendUInt64BE(frameId)
        data.appendUInt64BE(ptsNanos)
        data.appendUInt16BE(packetIndex)
        data.appendUInt16BE(packetCount)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public init?(data: Data) {
        guard data.count >= Self.headerLength else {
            return nil
        }
        guard data.readUInt32BE(at: 0) == Self.magic else {
            return nil
        }
        guard data[4] == Self.version else {
            return nil
        }
        guard let kind = CameraPacketKind(rawValue: data[5]) else {
            return nil
        }
        guard
            let flags = data.readUInt16BE(at: 6),
            let streamId = data.readUInt32BE(at: 8),
            let frameId = data.readUInt64BE(at: 12),
            let ptsNanos = data.readUInt64BE(at: 20),
            let packetIndex = data.readUInt16BE(at: 28),
            let packetCount = data.readUInt16BE(at: 30),
            let payloadLength = data.readUInt32BE(at: 32)
        else {
            return nil
        }
        let expectedLength = Self.headerLength + Int(payloadLength)
        guard data.count == expectedLength else {
            return nil
        }
        self.kind = kind
        self.flags = CameraPacketFlags(rawValue: flags)
        self.streamId = streamId
        self.frameId = frameId
        self.ptsNanos = ptsNanos
        self.packetIndex = packetIndex
        self.packetCount = packetCount
        self.payload = data.subdata(in: Self.headerLength..<expectedLength)
    }
}

public struct HelloPayload: Codable, Equatable, Sendable {
    public let deviceName: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int

    public init(deviceName: String, codec: String, width: Int, height: Int, fps: Int, bitrate: Int) {
        self.deviceName = deviceName
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }
}

public struct FormatPayload: Codable, Equatable, Sendable {
    public let codec: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int
    public let sps: Data
    public let pps: Data
    public let vps: Data?

    public init(codec: String, width: Int, height: Int, fps: Int, bitrate: Int, sps: Data, pps: Data, vps: Data? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.sps = sps
        self.pps = pps
        self.vps = vps
    }
}

public enum CameraControlAction: String, Codable, Equatable, Sendable {
    case zoomIn
    case zoomOut
    case stopZoom
    case resetZoom
    case requestKeyFrame
}

public enum CameraControlSpeed: String, Codable, Equatable, Sendable {
    case slow
    case medium
    case fast
}

public struct CameraControlPayload: Codable, Equatable, Sendable {
    public let action: CameraControlAction
    public let speed: CameraControlSpeed?

    public init(action: CameraControlAction, speed: CameraControlSpeed? = nil) {
        self.action = action
        self.speed = speed
    }
}

public enum CameraProtocol {
    public static let serviceType = "_iphonecam._udp"
    public static let bonjourServiceType = "_iphonecam._udp."
    public static let codecH264AVCC = "h264-avcc"
    public static let codecHEVCHVCC = "hevc-hvcc"
    public static let defaultCodec = codecHEVCHVCC
    public static let streamId: UInt32 = 1
    public static let targetWidth = 1_920
    public static let targetHeight = 1_080
    public static let targetFPS = 60
    public static let targetBitrateH264 = 12_000_000
    public static let targetBitrateHEVC = 8_000_000
    public static let targetBitrate = 8_000_000
    public static let usbMuxPort: UInt16 = 8240
}

extension CameraPacket {
    public func framedForTCP() -> Data {
        let raw = encoded()
        var framed = Data()
        framed.reserveCapacity(4 + raw.count)
        var length = UInt32(raw.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(raw)
        return framed
    }
}

public struct TCPPacketFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextPacket() -> CameraPacket? {
        while buffer.count >= 4 {
            let length = (UInt32(buffer[0]) << 24)
                | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8)
                | UInt32(buffer[3])
            let totalLength = 4 + Int(length)
            if buffer.count < totalLength {
                return nil
            }
            let packetData = buffer.subdata(in: 4..<totalLength)
            buffer.removeSubrange(0..<totalLength)
            if let packet = CameraPacket(data: packetData) {
                return packet
            }
        }
        return nil
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

extension Data {
    fileprivate mutating func appendUInt16BE(_ value: UInt16) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendUInt32BE(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendUInt64BE(_ value: UInt64) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    fileprivate func readUInt16BE(at offset: Int) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    fileprivate func readUInt32BE(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    fileprivate func readUInt64BE(at offset: Int) -> UInt64? {
        guard count >= offset + 8 else { return nil }
        var result: UInt64 = 0
        for index in offset..<(offset + 8) {
            result = (result << 8) | UInt64(self[index])
        }
        return result
    }
}
