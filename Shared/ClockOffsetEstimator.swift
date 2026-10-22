import Foundation

/// NTP-style clock offset between the iPhone and this machine, from time-sync round trips. Each round trip bounds
/// the error by half its RTT, so the estimate uses the lowest-RTT sample of the recent window.
public struct ClockOffsetEstimator: Sendable {
    private struct Sample: Sendable {
        let offsetNanos: Int64
        let roundTripNanos: UInt64
    }

    private static let window = 16
    private var samples: [Sample] = []

    public init() {}

    public var isReady: Bool {
        !samples.isEmpty
    }

    /// Phone clock minus local clock.
    public var offsetNanos: Int64? {
        best?.offsetNanos
    }

    public var roundTripNanos: UInt64? {
        best?.roundTripNanos
    }

    private var best: Sample? {
        samples.min { $0.roundTripNanos < $1.roundTripNanos }
    }

    public mutating func addSample(localSendNanos: UInt64, phoneNanos: UInt64, localReceiveNanos: UInt64) {
        guard localReceiveNanos >= localSendNanos else {
            return
        }
        let roundTrip = localReceiveNanos - localSendNanos
        let midpoint = localSendNanos + roundTrip / 2
        samples.append(Sample(offsetNanos: Int64(bitPattern: phoneNanos) - Int64(bitPattern: midpoint), roundTripNanos: roundTrip))
        if samples.count > Self.window {
            samples.removeFirst()
        }
    }

    /// The local-clock time of a phone timestamp, such as a frame's capture time.
    public func localNanos(forPhoneNanos phoneNanos: UInt64) -> UInt64? {
        guard let offset = offsetNanos else {
            return nil
        }
        let local = Int64(bitPattern: phoneNanos) - offset
        return local >= 0 ? UInt64(local) : nil
    }

    public mutating func reset() {
        samples.removeAll()
    }

    /// The time-sync response payload: the request's clock as 8 big-endian bytes.
    public static func echoedClock(in payload: Data) -> UInt64? {
        guard payload.count == 8 else {
            return nil
        }
        return payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
