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
