#include "frame_reassembler.hpp"
#include "protocol.hpp"

#include <cassert>
#include <chrono>
#include <iostream>

using namespace iphonecam;

namespace {

void testPacketRoundTrip()
{
    CameraPacket packet;
    packet.kind = PacketKind::FrameFragment;
    packet.flags = kPacketFlagKeyFrame;
    packet.streamId = 0x01020304;
    packet.frameId = 0x0102030405060708ULL;
    packet.ptsNanos = 0x1112131415161718ULL;
    packet.packetIndex = 2;
    packet.packetCount = 4;
    packet.payload = {0xaa, 0xbb, 0xcc};

    auto encoded = encodePacket(packet);
    assert(encoded[0] == 0x49);
    assert(encoded[1] == 0x50);
    assert(encoded[2] == 0x43);
    assert(encoded[3] == 0x4d);

    auto parsed = parsePacket(encoded.data(), encoded.size());
    assert(parsed.has_value());
    assert(parsed->kind == packet.kind);
    assert(parsed->flags == packet.flags);
    assert(parsed->streamId == packet.streamId);
    assert(parsed->frameId == packet.frameId);
    assert(parsed->ptsNanos == packet.ptsNanos);
    assert(parsed->packetIndex == packet.packetIndex);
    assert(parsed->packetCount == packet.packetCount);
    assert(parsed->payload == packet.payload);
}

void testFrameReassembly()
{
    FrameReassembler reassembler(std::chrono::milliseconds(120));
    auto start = std::chrono::steady_clock::now();

    CameraPacket second;
    second.kind = PacketKind::FrameFragment;
    second.flags = kPacketFlagKeyFrame;
    second.streamId = 1;
    second.frameId = 42;
    second.ptsNanos = 10;
    second.packetIndex = 1;
    second.packetCount = 2;
    second.payload = {3, 4};

    CameraPacket first = second;
    first.packetIndex = 0;
    first.payload = {1, 2};

    assert(!reassembler.accept(second, start).has_value());
    auto frame = reassembler.accept(first, start + std::chrono::milliseconds(20));
    assert(frame.has_value());
    assert(frame->data == std::vector<uint8_t>({1, 2, 3, 4}));
    assert(frame->isKeyFrame);
    assert(reassembler.droppedFrameCount() == 0);
}

void testStaleDrop()
{
    FrameReassembler reassembler(std::chrono::milliseconds(120));
    auto start = std::chrono::steady_clock::now();

    CameraPacket stale;
    stale.kind = PacketKind::FrameFragment;
    stale.streamId = 1;
    stale.frameId = 7;
    stale.ptsNanos = 10;
    stale.packetIndex = 0;
    stale.packetCount = 2;
    stale.payload = {1};

    CameraPacket next;
    next.kind = PacketKind::FrameFragment;
    next.streamId = 1;
    next.frameId = 8;
    next.ptsNanos = 20;
    next.packetIndex = 0;
    next.packetCount = 1;
    next.payload = {2};

    assert(!reassembler.accept(stale, start).has_value());
    assert(reassembler.accept(next, start + std::chrono::milliseconds(200)).has_value());
    assert(reassembler.droppedFrameCount() == 1);
}

void testJsonPayloads()
{
    const std::string helloJson =
        R"({"deviceName":"Alper iPhone","codec":"h264-avcc","width":1920,"height":1080,"fps":60,"bitrate":12000000})";
    auto hello = parseHelloPayload(std::vector<uint8_t>(helloJson.begin(), helloJson.end()));
    assert(hello.has_value());
    assert(hello->deviceName == "Alper iPhone");
    assert(hello->width == 1920);
    assert(hello->bitrate == 12000000);

    const std::string formatJson =
        R"({"codec":"h264-avcc","width":1920,"height":1080,"fps":60,"bitrate":12000000,"sps":"AQIDBA==","pps":"BQY="})";
    auto format = parseFormatPayload(std::vector<uint8_t>(formatJson.begin(), formatJson.end()));
    assert(format.has_value());
    assert(format->sps == std::vector<uint8_t>({1, 2, 3, 4}));
    assert(format->pps == std::vector<uint8_t>({5, 6}));
}

} // namespace

int main()
{
    testPacketRoundTrip();
    testFrameReassembly();
    testStaleDrop();
    testJsonPayloads();
    std::cout << "iphonecam OBS protocol tests passed\n";
    return 0;
}
