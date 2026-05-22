import Foundation

public struct EncodedVideoFrame: Equatable, Sendable {
    public let streamId: UInt32
    public let frameId: UInt64
    public let ptsNanos: UInt64
    public let isKeyFrame: Bool
    public let data: Data

    public init(streamId: UInt32, frameId: UInt64, ptsNanos: UInt64, isKeyFrame: Bool, data: Data) {
        self.streamId = streamId
        self.frameId = frameId
        self.ptsNanos = ptsNanos
        self.isKeyFrame = isKeyFrame
        self.data = data
    }
}

public final class FrameReassembler {
    private struct PendingFrame {
        let streamId: UInt32
        let frameId: UInt64
        let ptsNanos: UInt64
        let isKeyFrame: Bool
        let startedAt: Date
        var parts: [Data?]
        var receivedCount: Int
    }

    private let timeout: TimeInterval
    private var frames: [UInt64: PendingFrame] = [:]

    public private(set) var droppedFrameCount = 0

    public init(timeout: TimeInterval = 0.12) {
        self.timeout = timeout
    }

    public func accept(_ packet: CameraPacket, now: Date = Date()) -> EncodedVideoFrame? {
        cleanupStaleFrames(now: now)

        guard packet.kind == .frameFragment else {
            return nil
        }
        guard packet.packetCount > 0, packet.packetIndex < packet.packetCount else {
            droppedFrameCount += 1
            return nil
        }

        let frameId = packet.frameId
        let partIndex = Int(packet.packetIndex)
        let partCount = Int(packet.packetCount)

        if var pending = frames[frameId] {
            guard pending.parts.count == partCount else {
                frames.removeValue(forKey: frameId)
                droppedFrameCount += 1
                return nil
            }
            if pending.parts[partIndex] == nil {
                pending.parts[partIndex] = packet.payload
                pending.receivedCount += 1
            }
            if pending.receivedCount == partCount {
                frames.removeValue(forKey: frameId)
                let data = pending.parts.reduce(into: Data()) { result, part in
                    if let part {
                        result.append(part)
                    }
                }
                return EncodedVideoFrame(
                    streamId: pending.streamId,
                    frameId: pending.frameId,
                    ptsNanos: pending.ptsNanos,
                    isKeyFrame: pending.isKeyFrame,
                    data: data
                )
            }
            frames[frameId] = pending
            return nil
        }

        var parts = Array<Data?>(repeating: nil, count: partCount)
        parts[partIndex] = packet.payload
        let pending = PendingFrame(
            streamId: packet.streamId,
            frameId: packet.frameId,
            ptsNanos: packet.ptsNanos,
            isKeyFrame: packet.flags.contains(.keyFrame),
            startedAt: now,
            parts: parts,
            receivedCount: 1
        )
        if partCount == 1 {
            return EncodedVideoFrame(
                streamId: packet.streamId,
                frameId: packet.frameId,
                ptsNanos: packet.ptsNanos,
                isKeyFrame: packet.flags.contains(.keyFrame),
                data: packet.payload
            )
        }
        frames[frameId] = pending
        return nil
    }

    public func reset() {
        frames.removeAll()
        droppedFrameCount = 0
    }

    private func cleanupStaleFrames(now: Date) {
        let staleFrameIds = frames.compactMap { frameId, pending -> UInt64? in
            now.timeIntervalSince(pending.startedAt) > timeout ? frameId : nil
        }
        for frameId in staleFrameIds {
            frames.removeValue(forKey: frameId)
            droppedFrameCount += 1
        }
    }
}
