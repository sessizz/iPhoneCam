#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace iphonecam {

enum class PacketKind : uint8_t {
    Hello = 1,
    Format = 2,
    FrameFragment = 3,
    Control = 4,
    Audio = 5,
};

constexpr uint32_t kPacketMagic = 0x4950434d;
constexpr uint8_t kPacketVersion = 1;
constexpr size_t kPacketHeaderLength = 36;
constexpr uint16_t kPacketFlagKeyFrame = 1 << 0;
constexpr const char *kBonjourServiceType = "_iphonecam._udp";

struct CameraPacket {
    PacketKind kind = PacketKind::FrameFragment;
    uint16_t flags = 0;
    uint32_t streamId = 0;
    uint64_t frameId = 0;
    uint64_t ptsNanos = 0;
    uint16_t packetIndex = 0;
    uint16_t packetCount = 1;
    std::vector<uint8_t> payload;
};

struct HelloPayload {
    std::string deviceName;
    std::string codec;
    int width = 0;
    int height = 0;
    int fps = 0;
    int bitrate = 0;
};

constexpr const char *kCodecH264AVCC = "h264-avcc";
constexpr const char *kCodecHEVCHVCC = "hevc-hvcc";

struct FormatPayload {
    std::string codec;
    int width = 0;
    int height = 0;
    int fps = 0;
    int bitrate = 0;
    std::vector<uint8_t> sps;
    std::vector<uint8_t> pps;
    std::vector<uint8_t> vps;
};

struct EncodedVideoFrame {
    uint64_t frameId = 0;
    uint64_t ptsNanos = 0;
    bool isKeyFrame = false;
    std::vector<uint8_t> data;
};

enum class ControlAction {
    ZoomIn,
    ZoomOut,
    StopZoom,
    ResetZoom,
    RequestKeyFrame,
};

enum class ControlSpeed {
    Slow,
    Medium,
    Fast,
};

struct ControlCommand {
    ControlAction action = ControlAction::StopZoom;
    ControlSpeed speed = ControlSpeed::Medium;
};

std::optional<CameraPacket> parsePacket(const uint8_t *data, size_t size);
std::vector<uint8_t> encodePacket(const CameraPacket &packet);
std::vector<uint8_t> encodeControlPayload(const ControlCommand &command);

std::optional<HelloPayload> parseHelloPayload(const std::vector<uint8_t> &payload);
std::optional<FormatPayload> parseFormatPayload(const std::vector<uint8_t> &payload);
std::optional<std::vector<uint8_t>> decodeBase64(const std::string &input);

} // namespace iphonecam
