import Foundation

public enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    /// Starts at the codec's target and only backs off from it when the link struggles.
    case balanced
    /// Starts above the target and probes upward while the link stays clean, to a ceiling set by the transport.
    case maximum

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .maximum:
            return "Maximum"
        }
    }
}

/// Once-a-second bitrate policy for the TCP stream. Congestion shows up as frames the sender had to skip
/// (its queue to a receiver was full) or as sends that took long to be accepted (the socket buffer is filling).
public struct AdaptiveBitrate: Sendable {
    public struct Sample: Equatable, Sendable {
        public var droppedFrames: Int
        public var maxSendDelayMs: Int
        /// True when every connected receiver came in over USB, which carries far more than Wi-Fi.
        public var allUSB: Bool

        public init(droppedFrames: Int, maxSendDelayMs: Int, allUSB: Bool) {
            self.droppedFrames = droppedFrames
            self.maxSendDelayMs = maxSendDelayMs
            self.allUSB = allUSB
        }
    }

    public static let minimumBitrate = 1_000_000
    static let congestedDelayMs = 200
    static let queueingDelayMs = 60

    public let baseBitrate: Int
    public let quality: StreamQuality
    public private(set) var current: Int
    /// 1 normally; lowered while the iPhone is under thermal or power pressure.
    public var pressureScale = 1.0

    private var cleanSeconds = 0
    private var brokenLevel: Int?
    private var secondsSinceBreak = Int.max

    public init(baseBitrate: Int, quality: StreamQuality) {
        self.baseBitrate = baseBitrate
        self.quality = quality
        current = quality == .maximum ? baseBitrate * 3 / 2 : baseBitrate
    }

    public func ceiling(allUSB: Bool) -> Int {
        let scaled = max(Self.minimumBitrate, Int(Double(baseBitrate) * pressureScale))
        guard quality == .maximum else {
            return scaled
        }
        return allUSB ? scaled * 7 / 2 : scaled * 5 / 2
    }

    /// Feeds one second of sender counters; returns the new bitrate when it changes.
    public mutating func update(_ sample: Sample) -> Int? {
        if secondsSinceBreak < Int.max {
            secondsSinceBreak += 1
        }
        let ceiling = ceiling(allUSB: sample.allUSB)

        if sample.droppedFrames > 0 || sample.maxSendDelayMs > Self.congestedDelayMs {
            cleanSeconds = 0
            brokenLevel = current
            secondsSinceBreak = 0
            return apply(max(Self.minimumBitrate, min(ceiling, current * 3 / 4)))
        }
        if current > ceiling {
            cleanSeconds = 0
            return apply(ceiling)
        }
        if current == ceiling {
            return nil
        }
        if quality == .maximum && sample.maxSendDelayMs > Self.queueingDelayMs {
            // Queueing without loss: the link is close to full, and pushing now is what causes the drop.
            cleanSeconds = 0
            return nil
        }

        cleanSeconds += 1
        guard cleanSeconds >= (quality == .maximum ? 3 : 10) else {
            return nil
        }
        cleanSeconds = 0
        var next = min(ceiling, quality == .maximum ? current * 115 / 100 : current * 11 / 10)
        if quality == .maximum, let brokenLevel, secondsSinceBreak < 60 {
            // Settle just under the level that broke; a clean minute earns another try above it.
            next = min(next, brokenLevel * 9 / 10)
        }
        return next > current ? apply(next) : nil
    }

    private mutating func apply(_ bitrate: Int) -> Int? {
        guard bitrate != current else {
            return nil
        }
        current = bitrate
        return bitrate
    }
}
