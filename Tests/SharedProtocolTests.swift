import Foundation
import XCTest

final class SharedProtocolTests: XCTestCase {
    func testPacketRoundTripUsesBigEndianHeader() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let packet = CameraPacket(
            kind: .frameFragment,
            flags: .keyFrame,
            streamId: 0x01020304,
            frameId: 0x0102030405060708,
            ptsNanos: 0x1112131415161718,
            packetIndex: 2,
            packetCount: 4,
            payload: payload
        )

        let encoded = packet.encoded()
        XCTAssertEqual(encoded[0], 0x49)
        XCTAssertEqual(encoded[1], 0x50)
        XCTAssertEqual(encoded[2], 0x43)
        XCTAssertEqual(encoded[3], 0x4D)
        XCTAssertEqual(CameraPacket(data: encoded), packet)
    }

    func testAudioPacketRoundTrip() throws {
        let payload = Data([0x11, 0x90, 0xAA, 0xBB])
        let packet = CameraPacket(
            kind: .audio,
            streamId: 1,
            ptsNanos: 987654321,
            payload: payload
        )

        let encoded = packet.encoded()
        let parsed = try XCTUnwrap(CameraPacket(data: encoded))
        XCTAssertEqual(parsed.kind, .audio)
        XCTAssertEqual(parsed.streamId, 1)
        XCTAssertEqual(parsed.ptsNanos, 987654321)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testControlPayloadRoundTrip() throws {
        let payload = CameraControlPayload(action: .zoomIn, speed: .fast)
        let data = try JSONEncoder().encode(payload)
        let packet = CameraPacket(kind: .control, streamId: 1, payload: data)

        let parsedPacket = try XCTUnwrap(CameraPacket(data: packet.encoded()))
        let parsedPayload = try JSONDecoder().decode(CameraControlPayload.self, from: parsedPacket.payload)
        XCTAssertEqual(parsedPacket.kind, .control)
        XCTAssertEqual(parsedPayload, payload)
    }

    func testKeyFrameRequestDecodesOBSPayload() throws {
        let data = Data(#"{"action":"requestKeyFrame"}"#.utf8)
        let payload = try JSONDecoder().decode(CameraControlPayload.self, from: data)

        XCTAssertEqual(payload.action, .requestKeyFrame)
        XCTAssertNil(payload.speed)
    }

    func testBLEJoystickPayloadDecode() throws {
        let data = Data([
            BLEZoomJoystickReport.version,
            BLEZoomJoystickFlags.resetZoom.rawValue,
            0x00, 0x40,
            0x00, 0xC0,
            0x34, 0x12,
        ])

        let report = try XCTUnwrap(BLEZoomJoystickReport(data: data))
        XCTAssertTrue(report.flags.contains(.resetZoom))
        XCTAssertEqual(report.x, 16_384)
        XCTAssertEqual(report.y, -16_384)
        XCTAssertEqual(report.sequence, 0x1234)
        XCTAssertEqual(report.normalizedX, 0.50, accuracy: 0.01)
        XCTAssertEqual(report.normalizedY, -0.50, accuracy: 0.01)
    }

    func testBLEZoomMappingUsesDeadzoneAndCurve() {
        let settings = BLEZoomSettings(deadzone: 0.10, minimumSpeed: 0.20, maximumSpeed: 0.80, curveExponent: 2.0)

        XCTAssertEqual(BLEZoomMapper.intensity(forAxis: 0.08, settings: settings), 0, accuracy: 0.0001)

        let low = BLEZoomMapper.intensity(forAxis: 0.20, settings: settings)
        let high = BLEZoomMapper.intensity(forAxis: 0.90, settings: settings)
        let negative = BLEZoomMapper.intensity(forAxis: -0.90, settings: settings)

        XCTAssertGreaterThan(low, 0.20)
        XCTAssertLessThan(low, high)
        XCTAssertEqual(high, -negative, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(high, 0.80)
    }

    func testBLEZoomMappingClampsSpeedSettings() {
        let settings = BLEZoomSettings(deadzone: -1, minimumSpeed: 1.4, maximumSpeed: 0.4, curveExponent: 99)
        let intensity = BLEZoomMapper.intensity(forAxis: 1.0, settings: settings)

        XCTAssertEqual(intensity, 1.0, accuracy: 0.0001)
    }

    func testBLEZoomMappingUsesAxisSwapAndInversionSettings() {
        let report = BLEZoomJoystickReport(x: 16_384, y: -16_384, sequence: 1)
        let swapped = BLEZoomSettings(deadzone: 0.02, swapAxes: true)
        let swappedInverted = BLEZoomSettings(deadzone: 0.02, swapAxes: true, invertZoomAxis: true, invertSnapAxis: true)

        XCTAssertEqual(BLEZoomMapper.zoomAxis(from: report, settings: .defaults), -0.50, accuracy: 0.01)
        XCTAssertEqual(BLEZoomMapper.snapAxis(from: report, settings: .defaults), 0.50, accuracy: 0.01)
        XCTAssertEqual(BLEZoomMapper.zoomAxis(from: report, settings: swapped), 0.50, accuracy: 0.01)
        XCTAssertEqual(BLEZoomMapper.snapAxis(from: report, settings: swapped), -0.50, accuracy: 0.01)
        XCTAssertEqual(BLEZoomMapper.zoomAxis(from: report, settings: swappedInverted), -0.50, accuracy: 0.01)
        XCTAssertEqual(BLEZoomMapper.snapAxis(from: report, settings: swappedInverted), 0.50, accuracy: 0.01)
    }

    func testBLEZoomSnapTargetsRoundCurrentZoomDownOrUp() throws {
        let down = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: -0.95, currentZoomFactor: 2.5, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(down.direction, .down)
        XCTAssertEqual(down.targetZoomFactor, 2.0)

        let up = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: 0.95, currentZoomFactor: 3.7, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(up.direction, .up)
        XCTAssertEqual(up.targetZoomFactor, 4.0)

        let thresholdSnap = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: 0.70, currentZoomFactor: 3.7, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(thresholdSnap.targetZoomFactor, 4.0)

        let belowThreshold = BLEZoomMapper.snapTarget(forAxis: 0.69, currentZoomFactor: 3.7, minZoomFactor: 0.5, maxZoomFactor: 8)
        XCTAssertNil(belowThreshold)
    }

    func testBLEZoomSnapTargetsMoveToAdjacentIntegerWhenAlreadyWhole() throws {
        let down = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: -0.70, currentZoomFactor: 2.0, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(down.direction, .down)
        XCTAssertEqual(down.targetZoomFactor, 1.0)

        let up = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: 0.70, currentZoomFactor: 2.0, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(up.direction, .up)
        XCTAssertEqual(up.targetZoomFactor, 3.0)
    }

    func testBLEZoomSnapTargetsRespectZoomBounds() throws {
        let down = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: -0.95, currentZoomFactor: 0.7, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(down.targetZoomFactor, 0.5)

        let up = try XCTUnwrap(BLEZoomMapper.snapTarget(forAxis: 0.95, currentZoomFactor: 8.0, minZoomFactor: 0.5, maxZoomFactor: 8))
        XCTAssertEqual(up.targetZoomFactor, 8.0)
    }

    func testBLEDisplayStateEncodesOLEDFeedbackPayload() {
        let state = BLEZoomDisplayState(zoomFactor: 1.42, intensity: -0.37, connected: true, sequence: 7)
        let data = state.encoded()

        XCTAssertEqual(data.count, BLEZoomDisplayState.byteLength)
        XCTAssertEqual(data[0], BLEZoomDisplayState.version)
        XCTAssertEqual(data[1], BLEZoomDisplayFlags.connected.union(.zooming).rawValue)
        XCTAssertEqual(data[2], 142)
        XCTAssertEqual(data[3], 0)
        XCTAssertEqual(Int8(bitPattern: data[4]), -37)
        XCTAssertEqual(data[6], 7)
        XCTAssertEqual(data[7], 0)
    }

    func testReassemblerCompletesOutOfOrderFrame() {
        let reassembler = FrameReassembler(timeout: 0.12)
        let first = CameraPacket(
            kind: .frameFragment,
            flags: .keyFrame,
            streamId: 1,
            frameId: 42,
            ptsNanos: 10,
            packetIndex: 1,
            packetCount: 2,
            payload: Data([3, 4])
        )
        let second = CameraPacket(
            kind: .frameFragment,
            flags: .keyFrame,
            streamId: 1,
            frameId: 42,
            ptsNanos: 10,
            packetIndex: 0,
            packetCount: 2,
            payload: Data([1, 2])
        )

        XCTAssertNil(reassembler.accept(first, now: Date(timeIntervalSince1970: 1)))
        let frame = reassembler.accept(second, now: Date(timeIntervalSince1970: 1.02))
        XCTAssertEqual(frame?.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(frame?.isKeyFrame, true)
        XCTAssertEqual(reassembler.droppedFrameCount, 0)
    }

    func testReassemblerDropsStaleFrame() {
        let reassembler = FrameReassembler(timeout: 0.12)
        let stale = CameraPacket(
            kind: .frameFragment,
            streamId: 1,
            frameId: 7,
            ptsNanos: 10,
            packetIndex: 0,
            packetCount: 2,
            payload: Data([1])
        )
        let next = CameraPacket(
            kind: .frameFragment,
            streamId: 1,
            frameId: 8,
            ptsNanos: 20,
            packetIndex: 0,
            packetCount: 1,
            payload: Data([2])
        )

        XCTAssertNil(reassembler.accept(stale, now: Date(timeIntervalSince1970: 1)))
        XCTAssertNotNil(reassembler.accept(next, now: Date(timeIntervalSince1970: 1.2)))
        XCTAssertEqual(reassembler.droppedFrameCount, 1)
    }

    func testHEVCFormatPayloadRoundTrip() throws {
        let vps = Data([0x01, 0x02])
        let sps = Data([0x03, 0x04])
        let pps = Data([0x05, 0x06])
        let payload = FormatPayload(
            codec: CameraProtocol.codecHEVCHVCC,
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 8_000_000,
            sps: sps,
            pps: pps,
            vps: vps
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(FormatPayload.self, from: data)

        XCTAssertEqual(decoded.codec, CameraProtocol.codecHEVCHVCC)
        XCTAssertEqual(decoded.vps, vps)
        XCTAssertEqual(decoded.sps, sps)
        XCTAssertEqual(decoded.pps, pps)
        XCTAssertEqual(decoded.bitrate, 8_000_000)
    }

    func testTCPPacketFramerHandlesStreamedAndFragmentedPackets() {
        var framer = TCPPacketFramer()

        let packet1 = CameraPacket(
            kind: .frameFragment,
            flags: .keyFrame,
            streamId: 1,
            frameId: 10,
            ptsNanos: 12345,
            packetIndex: 0,
            packetCount: 1,
            payload: Data([0xAA, 0xBB, 0xCC, 0xDD])
        )
        let packet2 = CameraPacket(
            kind: .control,
            streamId: 1,
            payload: Data([0x11, 0x22])
        )

        let framed1 = packet1.framedForTCP()
        let framed2 = packet2.framedForTCP()

        let mid = framed1.count / 2
        framer.append(framed1.subdata(in: 0..<mid))
        XCTAssertNil(framer.nextPacket())

        framer.append(framed1.subdata(in: mid..<framed1.count))
        framer.append(framed2)

        let parsed1 = framer.nextPacket()
        XCTAssertEqual(parsed1, packet1)

        let parsed2 = framer.nextPacket()
        XCTAssertEqual(parsed2, packet2)

        XCTAssertNil(framer.nextPacket())
    }

    func testFramedHeaderPlusPayloadMatchesFramedPacket() {
        let packet = CameraPacket(
            kind: .frameFragment,
            flags: .keyFrame,
            streamId: 1,
            frameId: 77,
            ptsNanos: 123,
            payload: Data(repeating: 0x5A, count: 3000)
        )
        var split = packet.framedTCPHeader()
        XCTAssertEqual(split.count, 4 + CameraPacket.headerLength)
        split.append(packet.payload)
        XCTAssertEqual(split, packet.framedForTCP())
    }

    func testPingAndTimeSyncPacketsRoundTrip() throws {
        for kind in [CameraPacketKind.ping, .timeSyncRequest, .timeSyncResponse] {
            let packet = CameraPacket(kind: kind, streamId: 1, ptsNanos: 42, payload: Data([0, 0, 0, 0, 0, 0, 0, 7]))
            XCTAssertEqual(CameraPacket(data: packet.encoded()), packet)
        }
    }

    func testIdentifyDecodesOBSPayload() throws {
        let data = Data(#"{"action":"identify","transport":"usb","clientName":"OBS on \"Studio\" Mac"}"#.utf8)
        let payload = try JSONDecoder().decode(CameraControlPayload.self, from: data)

        XCTAssertEqual(payload.action, .identify)
        XCTAssertEqual(payload.transport, CameraProtocol.transportUSB)
        XCTAssertEqual(payload.clientName, #"OBS on "Studio" Mac"#)
    }

    func testTCPPacketFramerStopsOnOversizedLength() {
        var framer = TCPPacketFramer()
        framer.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00]))
        XCTAssertNil(framer.nextPacket())
        XCTAssertTrue(framer.isDesynced)

        // Bytes after a desync are not parsed as packets; only a reset (a new connection) recovers.
        framer.append(CameraPacket(kind: .ping, streamId: 1, payload: Data()).framedForTCP())
        XCTAssertNil(framer.nextPacket())
        framer.reset()
        XCTAssertFalse(framer.isDesynced)
    }

    func testBalancedBitrateBacksOffAndRecoversSlowly() {
        var policy = AdaptiveBitrate(baseBitrate: 8_000_000, quality: .balanced)
        XCTAssertEqual(policy.current, 8_000_000)

        let congested = AdaptiveBitrate.Sample(droppedFrames: 2, maxSendDelayMs: 10, allUSB: false)
        XCTAssertEqual(policy.update(congested), 6_000_000)
        let slowSends = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 250, allUSB: false)
        XCTAssertEqual(policy.update(slowSends), 4_500_000)

        let clean = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 20, allUSB: false)
        for _ in 0..<9 {
            XCTAssertNil(policy.update(clean))
        }
        XCTAssertEqual(policy.update(clean), 4_950_000)

        // Balanced never climbs past the codec target.
        for _ in 0..<200 {
            _ = policy.update(clean)
        }
        XCTAssertEqual(policy.current, 8_000_000)
    }

    func testBitrateNeverDropsBelowMinimum() {
        var policy = AdaptiveBitrate(baseBitrate: 1_200_000, quality: .balanced)
        let congested = AdaptiveBitrate.Sample(droppedFrames: 1, maxSendDelayMs: 0, allUSB: false)
        for _ in 0..<10 {
            _ = policy.update(congested)
        }
        XCTAssertEqual(policy.current, AdaptiveBitrate.minimumBitrate)
    }

    func testMaximumProbesToTransportCeiling() {
        var policy = AdaptiveBitrate(baseBitrate: 8_000_000, quality: .maximum)
        XCTAssertEqual(policy.current, 12_000_000)
        XCTAssertEqual(policy.ceiling(allUSB: true), 28_000_000)
        XCTAssertEqual(policy.ceiling(allUSB: false), 20_000_000)

        let cleanUSB = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 5, allUSB: true)
        XCTAssertNil(policy.update(cleanUSB))
        XCTAssertNil(policy.update(cleanUSB))
        XCTAssertEqual(policy.update(cleanUSB), 13_800_000)
        for _ in 0..<100 {
            _ = policy.update(cleanUSB)
        }
        XCTAssertEqual(policy.current, 28_000_000)

        // A Wi-Fi receiver joining lowers the ceiling right away.
        let cleanWiFi = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 5, allUSB: false)
        XCTAssertEqual(policy.update(cleanWiFi), 20_000_000)
    }

    func testMaximumHoldsWhileSendsQueueAndSettlesBelowBreakingLevel() {
        var policy = AdaptiveBitrate(baseBitrate: 8_000_000, quality: .maximum)
        let queueing = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 100, allUSB: true)
        for _ in 0..<10 {
            XCTAssertNil(policy.update(queueing))
        }

        let congested = AdaptiveBitrate.Sample(droppedFrames: 1, maxSendDelayMs: 0, allUSB: true)
        XCTAssertEqual(policy.update(congested), 9_000_000)
        let clean = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 5, allUSB: true)
        for _ in 0..<30 {
            _ = policy.update(clean)
        }
        // Within a minute of breaking at 12 Mbps it stays at 90% of that.
        XCTAssertEqual(policy.current, 10_800_000)
    }

    func testPressureScaleLowersCeiling() {
        var policy = AdaptiveBitrate(baseBitrate: 8_000_000, quality: .balanced)
        policy.pressureScale = 0.5
        let clean = AdaptiveBitrate.Sample(droppedFrames: 0, maxSendDelayMs: 5, allUSB: true)
        XCTAssertEqual(policy.update(clean), 4_000_000)
    }

    func testClockOffsetUsesLowestRoundTrip() throws {
        var clock = ClockOffsetEstimator()
        XCTAssertFalse(clock.isReady)
        // Phone clock runs 5 s ahead. A slow round trip whose reply came back late skews its midpoint, so the
        // 2 ms sample must win.
        clock.addSample(localSendNanos: 1_000_000_000, phoneNanos: 6_030_000_000, localReceiveNanos: 1_040_000_000)
        clock.addSample(localSendNanos: 2_000_000_000, phoneNanos: 7_001_000_000, localReceiveNanos: 2_002_000_000)
        XCTAssertEqual(clock.roundTripNanos, 2_000_000)
        XCTAssertEqual(clock.offsetNanos, 5_000_000_000)
        XCTAssertEqual(clock.localNanos(forPhoneNanos: 7_500_000_000), 2_500_000_000)

        XCTAssertEqual(ClockOffsetEstimator.echoedClock(in: Data([0, 0, 0, 0, 0x3B, 0x9A, 0xCA, 0x00])), 1_000_000_000)
        XCTAssertNil(ClockOffsetEstimator.echoedClock(in: Data([1, 2, 3])))
    }

    func testTallyAndImageControlsDecodeOBSPayloads() throws {
        let tally = try JSONDecoder().decode(
            CameraControlPayload.self,
            from: Data(#"{"action":"tally","program":true,"preview":false}"#.utf8)
        )
        XCTAssertEqual(tally.action, .tally)
        XCTAssertEqual(tally.program, true)
        XCTAssertEqual(tally.preview, false)

        let names: [String: CameraControlAction] = [
            "toggleTorch": .toggleTorch,
            "switchCamera": .switchCamera,
            "toggleFocusExposureLock": .toggleFocusExposureLock,
            "exposureUp": .exposureUp,
            "exposureDown": .exposureDown,
            "toggleWhiteBalanceLock": .toggleWhiteBalanceLock,
            "resetImageControls": .resetImageControls,
        ]
        for (name, action) in names {
            let payload = try JSONDecoder().decode(CameraControlPayload.self, from: Data(#"{"action":"\#(name)"}"#.utf8))
            XCTAssertEqual(payload.action, action)
        }
    }

    func testBaseBitrateScalesWithFormat() {
        let hevc = CameraProtocol.codecHEVCHVCC
        let h264 = CameraProtocol.codecH264AVCC
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: hevc, width: 1920, height: 1080, fps: 60), 8_000_000)
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: h264, width: 1920, height: 1080, fps: 60), 12_000_000)
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: hevc, width: 1280, height: 720, fps: 30), 4_000_000)
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: h264, width: 3840, height: 2160, fps: 60), 40_000_000)
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: hevc, width: 1920, height: 1080, fps: 120), 12_000_000)
        XCTAssertEqual(CameraProtocol.baseBitrate(codec: hevc, width: 1920, height: 1080, fps: 240), 16_000_000)
    }
}
