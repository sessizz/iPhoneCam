import Foundation

public enum CameraPacketKind: UInt8, Sendable {
    case hello = 1
    case format = 2
    case frameFragment = 3
    case control = 4
    case audio = 5
    /// Sent by the iPhone every couple of seconds so a receiver can tell a quiet link from a dead one.
    case ping = 6
    /// Receiver to iPhone. `ptsNanos` carries the receiver's monotonic clock.
    case timeSyncRequest = 7
    /// iPhone to receiver. `ptsNanos` is the iPhone's host clock, the clock frame timestamps use; the payload
    /// echoes the request's clock as 8 big-endian bytes.
    case timeSyncResponse = 8
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
    /// Upper bound for one TCP-framed packet; anything larger means the byte stream is out of sync.
    public static let maxFramedLength = 32 * 1024 * 1024

    public let kind: CameraPacketKind
    public let flags: CameraPacketFlags
    public let streamId: UInt32
    /// For frame fragments: a send sequence that goes up by one for every encoded frame, so a gap means the
    /// receiver missed a frame (the iPhone skips frames for a receiver that falls behind) and must wait for
    /// the next keyframe.
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
        appendHeader(to: &data)
        data.append(payload)
        return data
    }

    private func appendHeader(to data: inout Data) {
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
    /// A receiver introducing itself right after it connects: how it reached the iPhone and what it is called.
    case identify
    case toggleTorch
    case switchCamera
    /// Locks focus and exposure where they are, or hands both back to auto when either is already fixed.
    case toggleFocusExposureLock
    case exposureUp
    case exposureDown
    case toggleWhiteBalanceLock
    /// Focus, exposure and white balance back to auto, exposure bias to zero.
    case resetImageControls
    /// Whether the receiver is showing this camera on air (`program`) or only somewhere else (`preview`).
    /// Sent on change and again on every new connection; the iPhone forgets it when the connection drops.
    case tally
}

public enum CameraControlSpeed: String, Codable, Equatable, Sendable {
    case slow
    case medium
    case fast
}

public struct CameraControlPayload: Codable, Equatable, Sendable {
    public let action: CameraControlAction
    public let speed: CameraControlSpeed?
    /// `identify` only: CameraProtocol.transportUSB or CameraProtocol.transportWiFi.
    public let transport: String?
    /// `identify` only: the receiver's name, e.g. "OBS on Studio-Mac".
    public let clientName: String?
    /// `tally` only.
    public let program: Bool?
    public let preview: Bool?

    public init(
        action: CameraControlAction,
        speed: CameraControlSpeed? = nil,
        transport: String? = nil,
        clientName: String? = nil,
        program: Bool? = nil,
        preview: Bool? = nil
    ) {
        self.action = action
        self.speed = speed
        self.transport = transport
        self.clientName = clientName
        self.program = program
        self.preview = preview
    }
}

public enum CameraProtocol {
    /// The iPhone advertises its stream listener under this Bonjour type, named after the camera.
    public static let phoneServiceType = "_iphonecam._tcp"
    public static let codecH264AVCC = "h264-avcc"
    public static let codecHEVCHVCC = "hevc-hvcc"
    public static let defaultCodec = codecHEVCHVCC
    public static let streamId: UInt32 = 1
    public static let targetWidth = 1_920
    public static let targetHeight = 1_080
    public static let targetFPS = 60
    public static let targetBitrate = 8_000_000
    /// The iPhone listens here; receivers dial it over Wi-Fi (the phone's IP) or through usbmuxd (USB cable).
    public static let streamPort: UInt16 = 8240
    public static let transportUSB = "usb"
    public static let transportWiFi = "wifi"

    /// The adaptive bitrate loop's starting target for a stream. Sized for 60 fps; faster streams change less
    /// between frames, so their budget grows less than linearly.
    public static func baseBitrate(codec: String, width: Int, height: Int, fps: Int) -> Int {
        let pixels = width * height
        let h264: Int
        if pixels <= 1280 * 720 {
            h264 = 6_000_000
        } else if pixels <= 1920 * 1080 {
            h264 = 12_000_000
        } else {
            h264 = 40_000_000
        }
        // HEVC reaches comparable quality with about two thirds of the bits.
        let base = codec == codecHEVCHVCC ? h264 * 2 / 3 : h264
        switch fps {
        case ...60:
            return base
        case ...120:
            return base * 3 / 2
        default:
            return base * 2
        }
    }
}

extension CameraPacket {
    public func framedForTCP() -> Data {
        var framed = framedTCPHeader()
        framed.append(payload)
        return framed
    }

    /// The length prefix and header of `framedForTCP()` without the payload, so a large frame can be sent as
    /// header + payload instead of being copied into one buffer.
    public func framedTCPHeader() -> Data {
        var header = Data()
        header.reserveCapacity(4 + Self.headerLength)
        header.appendUInt32BE(UInt32(Self.headerLength + payload.count))
        appendHeader(to: &header)
        return header
    }
}

public struct TCPPacketFramer: Sendable {
    private var buffer = Data()
    /// Set once a length prefix was out of range; the connection should be dropped and redialed.
    public private(set) var isDesynced = false

    public init() {}

    public mutating func append(_ data: Data) {
        guard !isDesynced else { return }
        buffer.append(data)
    }

    public mutating func nextPacket() -> CameraPacket? {
        while !isDesynced && buffer.count >= 4 {
            let length = (UInt32(buffer[0]) << 24)
                | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8)
                | UInt32(buffer[3])
            let totalLength = 4 + Int(length)
            guard Int(length) <= CameraPacket.maxFramedLength else {
                buffer.removeAll(keepingCapacity: false)
                isDesynced = true
                return nil
            }
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
        isDesynced = false
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
