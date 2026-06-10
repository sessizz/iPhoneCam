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

    func testControlPayloadRoundTrip() throws {
        let payload = CameraControlPayload(action: .zoomIn, speed: .fast)
        let data = try JSONEncoder().encode(payload)
        let packet = CameraPacket(kind: .control, streamId: 1, payload: data)

        let parsedPacket = try XCTUnwrap(CameraPacket(data: packet.encoded()))
        let parsedPayload = try JSONDecoder().decode(CameraControlPayload.self, from: parsedPacket.payload)
        XCTAssertEqual(parsedPacket.kind, .control)
        XCTAssertEqual(parsedPayload, payload)
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
}
