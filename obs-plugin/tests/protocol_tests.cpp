#include "frame_reassembler.hpp"
#include "protocol.hpp"
#include "stream_support.hpp"

#include <algorithm>
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

void testControlPacket()
{
    ControlCommand command;
    command.action = ControlAction::ZoomOut;
    command.speed = ControlSpeed::Fast;

    CameraPacket packet;
    packet.kind = PacketKind::Control;
    packet.streamId = 1;
    packet.payload = encodeControlPayload(command);

    const std::string json(packet.payload.begin(), packet.payload.end());
    assert(json == R"({"action":"zoomOut","speed":"fast"})");

    const auto encoded = encodePacket(packet);
    auto parsed = parsePacket(encoded.data(), encoded.size());
    assert(parsed.has_value());
    assert(parsed->kind == PacketKind::Control);
}

void testResetControlPayloadOmitsSpeed()
{
    ControlCommand command;
    command.action = ControlAction::ResetZoom;
    command.speed = ControlSpeed::Slow;

    const auto payload = encodeControlPayload(command);
    const std::string json(payload.begin(), payload.end());
    assert(json == R"({"action":"resetZoom"})");
}

void testRequestKeyFrameControlPayloadOmitsSpeed()
{
    ControlCommand command;
    command.action = ControlAction::RequestKeyFrame;

    const auto payload = encodeControlPayload(command);
    const std::string json(payload.begin(), payload.end());
    assert(json == R"({"action":"requestKeyFrame"})");
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
    assert(format->vps.empty());

    const std::string hevcJson =
        R"({"codec":"hevc-hvcc","width":1920,"height":1080,"fps":60,"bitrate":8000000,"sps":"AQIDBA==","pps":"BQY=","vps":"Bwc="})";
    auto hevc = parseFormatPayload(std::vector<uint8_t>(hevcJson.begin(), hevcJson.end()));
    assert(hevc.has_value());
    assert(hevc->codec == "hevc-hvcc");
    assert(hevc->vps == std::vector<uint8_t>({7, 7}));
    assert(hevc->sps == std::vector<uint8_t>({1, 2, 3, 4}));
    assert(hevc->pps == std::vector<uint8_t>({5, 6}));
}

void testAudioPacketRoundTrip()
{
    CameraPacket packet;
    packet.kind = PacketKind::Audio;
    packet.streamId = 1;
    packet.ptsNanos = 123456789ULL;
    packet.payload = {0x11, 0x90, 0xaa, 0xbb};

    const auto encoded = encodePacket(packet);
    auto parsed = parsePacket(encoded.data(), encoded.size());
    assert(parsed.has_value());
    assert(parsed->kind == PacketKind::Audio);
    assert(parsed->streamId == 1);
    assert(parsed->ptsNanos == 123456789ULL);
    assert(parsed->payload == packet.payload);
}

void testIdentifyPayloadEscapesNames()
{
    ControlCommand command;
    command.action = ControlAction::Identify;
    command.transport = kTransportWiFi;
    command.clientName = "OBS on \"Studio\" Mac";

    const auto payload = encodeControlPayload(command);
    const std::string json(payload.begin(), payload.end());
    assert(json == R"({"action":"identify","transport":"wifi","clientName":"OBS on \"Studio\" Mac"})");
}

void testNewPacketKindsParse()
{
    for (const auto kind : {PacketKind::Ping, PacketKind::TimeSyncRequest, PacketKind::TimeSyncResponse}) {
        CameraPacket packet;
        packet.kind = kind;
        packet.streamId = 1;
        packet.ptsNanos = 42;
        const auto encoded = encodePacket(packet);
        const auto parsed = parsePacket(encoded.data(), encoded.size());
        assert(parsed.has_value());
        assert(parsed->kind == kind);
        assert(parsed->ptsNanos == 42);
    }

    CameraPacket unknown;
    auto encoded = encodePacket(unknown);
    encoded[5] = 9;
    assert(!parsePacket(encoded.data(), encoded.size()).has_value());
}

void testStreamFramerSplitsAndJoinsChunks()
{
    CameraPacket first;
    first.kind = PacketKind::Hello;
    first.streamId = 1;
    first.payload = {1, 2, 3};
    CameraPacket second;
    second.kind = PacketKind::FrameFragment;
    second.streamId = 1;
    second.frameId = 9;
    second.payload = std::vector<uint8_t>(5000, 0x7f);

    std::vector<uint8_t> stream = encodeFramedPacket(first);
    const auto secondFramed = encodeFramedPacket(second);
    stream.insert(stream.end(), secondFramed.begin(), secondFramed.end());

    PacketStreamFramer framer;
    std::vector<CameraPacket> parsed;
    // Feed in uneven chunks, as TCP delivers them.
    for (size_t offset = 0; offset < stream.size(); offset += 777) {
        const size_t size = std::min<size_t>(777, stream.size() - offset);
        framer.append(stream.data() + offset, size);
        while (auto bytes = framer.next()) {
            auto packet = parsePacket(bytes->data(), bytes->size());
            assert(packet.has_value());
            parsed.push_back(*packet);
        }
    }
    assert(parsed.size() == 2);
    assert(parsed[0].kind == PacketKind::Hello);
    assert(parsed[0].payload == first.payload);
    assert(parsed[1].frameId == 9);
    assert(parsed[1].payload == second.payload);
    assert(!framer.desynced());
}

void testStreamFramerFlagsGarbageLength()
{
    PacketStreamFramer framer;
    const uint8_t garbage[] = {0xff, 0xff, 0xff, 0xff, 0, 0};
    framer.append(garbage, sizeof(garbage));
    assert(!framer.next().has_value());
    assert(framer.desynced());
}

void testParseHostPort()
{
    auto plain = parseHostPort(" 192.168.1.5 ", kStreamPort);
    assert(plain && plain->host == "192.168.1.5" && plain->port == kStreamPort);
    auto withPort = parseHostPort("192.168.1.5:9000", kStreamPort);
    assert(withPort && withPort->host == "192.168.1.5" && withPort->port == 9000);
    auto bracketed = parseHostPort("[fe80::1]:9001", kStreamPort);
    assert(bracketed && bracketed->host == "fe80::1" && bracketed->port == 9001);
    auto bareV6 = parseHostPort("fe80::1", kStreamPort);
    assert(bareV6 && bareV6->host == "fe80::1" && bareV6->port == kStreamPort);
    auto name = parseHostPort("Alper's iPhone", kStreamPort);
    assert(name && name->host == "Alper's iPhone");
    assert(!parseHostPort("", kStreamPort));
    assert(!parseHostPort("10.0.0.1:99999", kStreamPort));
    assert(!parseHostPort("10.0.0.1:abc", kStreamPort));
}

void testClockOffsetUsesLowestRoundTrip()
{
    ClockOffsetEstimator clock;
    assert(!clock.ready());
    // Phone clock runs 5 s ahead. A slow round trip (40 ms) whose reply came back late skews its midpoint,
    // so the 2 ms sample must win.
    clock.addSample(1'000'000'000ULL, 6'000'000'000ULL + 30'000'000ULL, 1'040'000'000ULL);
    clock.addSample(2'000'000'000ULL, 7'001'000'000ULL, 2'002'000'000ULL);
    assert(clock.ready());
    assert(clock.rttNs() == 2'000'000ULL);
    assert(clock.offsetNs() == 5'000'000'000LL);
    const auto local = clock.toLocal(7'500'000'000ULL);
    assert(local && *local == 2'500'000'000ULL);

    std::vector<uint8_t> echo = {0, 0, 0, 0, 0x3b, 0x9a, 0xca, 0x00};
    assert(readTimeSyncEcho(echo) == 1'000'000'000ULL);
    echo.pop_back();
    assert(!readTimeSyncEcho(echo).has_value());
}

} // namespace

int main()
{
    testPacketRoundTrip();
    testControlPacket();
    testResetControlPayloadOmitsSpeed();
    testRequestKeyFrameControlPayloadOmitsSpeed();
    testAudioPacketRoundTrip();
    testFrameReassembly();
    testStaleDrop();
    testJsonPayloads();
    testIdentifyPayloadEscapesNames();
    testNewPacketKindsParse();
    testStreamFramerSplitsAndJoinsChunks();
    testStreamFramerFlagsGarbageLength();
    testParseHostPort();
    testClockOffsetUsesLowestRoundTrip();
    std::cout << "iphonecam OBS protocol tests passed\n";
    return 0;
}
