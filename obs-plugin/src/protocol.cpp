#include "protocol.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>

namespace iphonecam {
namespace {

uint16_t readU16BE(const uint8_t *data)
{
    return (uint16_t(data[0]) << 8) | uint16_t(data[1]);
}

uint32_t readU32BE(const uint8_t *data)
{
    return (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) | (uint32_t(data[2]) << 8) | uint32_t(data[3]);
}

uint64_t readU64BE(const uint8_t *data)
{
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i)
        value = (value << 8) | uint64_t(data[i]);
    return value;
}

void appendU16BE(std::vector<uint8_t> &out, uint16_t value)
{
    out.push_back(uint8_t(value >> 8));
    out.push_back(uint8_t(value));
}

void appendU32BE(std::vector<uint8_t> &out, uint32_t value)
{
    out.push_back(uint8_t(value >> 24));
    out.push_back(uint8_t(value >> 16));
    out.push_back(uint8_t(value >> 8));
    out.push_back(uint8_t(value));
}

void appendU64BE(std::vector<uint8_t> &out, uint64_t value)
{
    for (int shift = 56; shift >= 0; shift -= 8)
        out.push_back(uint8_t(value >> shift));
}

std::optional<size_t> findJsonValue(const std::string &json, const char *key)
{
    const std::string needle = std::string("\"") + key + "\"";
    size_t keyPos = json.find(needle);
    if (keyPos == std::string::npos)
        return std::nullopt;
    size_t colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos)
        return std::nullopt;
    size_t value = colon + 1;
    while (value < json.size() && std::isspace(static_cast<unsigned char>(json[value])))
        ++value;
    if (value >= json.size())
        return std::nullopt;
    return value;
}

std::optional<std::string> jsonString(const std::string &json, const char *key)
{
    auto value = findJsonValue(json, key);
    if (!value || json[*value] != '"')
        return std::nullopt;

    std::string out;
    for (size_t i = *value + 1; i < json.size(); ++i) {
        const char c = json[i];
        if (c == '"')
            return out;
        if (c != '\\') {
            out.push_back(c);
            continue;
        }
        if (++i >= json.size())
            return std::nullopt;
        switch (json[i]) {
        case '"':
        case '\\':
        case '/':
            out.push_back(json[i]);
            break;
        case 'b':
            out.push_back('\b');
            break;
        case 'f':
            out.push_back('\f');
            break;
        case 'n':
            out.push_back('\n');
            break;
        case 'r':
            out.push_back('\r');
            break;
        case 't':
            out.push_back('\t');
            break;
        default:
            return std::nullopt;
        }
    }
    return std::nullopt;
}

std::optional<int> jsonInt(const std::string &json, const char *key)
{
    auto value = findJsonValue(json, key);
    if (!value)
        return std::nullopt;

    size_t end = *value;
    if (json[end] == '-')
        ++end;
    while (end < json.size() && std::isdigit(static_cast<unsigned char>(json[end])))
        ++end;
    if (end == *value)
        return std::nullopt;

    try {
        return std::stoi(json.substr(*value, end - *value));
    } catch (...) {
        return std::nullopt;
    }
}

std::string payloadString(const std::vector<uint8_t> &payload)
{
    return std::string(reinterpret_cast<const char *>(payload.data()), payload.size());
}

} // namespace

std::optional<CameraPacket> parsePacket(const uint8_t *data, size_t size)
{
    if (!data || size < kPacketHeaderLength)
        return std::nullopt;
    if (readU32BE(data) != kPacketMagic || data[4] != kPacketVersion)
        return std::nullopt;

    const auto rawKind = data[5];
    if (rawKind < uint8_t(PacketKind::Hello) || rawKind > uint8_t(PacketKind::FrameFragment))
        return std::nullopt;

    const uint32_t payloadLength = readU32BE(data + 32);
    if (size != kPacketHeaderLength + payloadLength)
        return std::nullopt;

    CameraPacket packet;
    packet.kind = PacketKind(rawKind);
    packet.flags = readU16BE(data + 6);
    packet.streamId = readU32BE(data + 8);
    packet.frameId = readU64BE(data + 12);
    packet.ptsNanos = readU64BE(data + 20);
    packet.packetIndex = readU16BE(data + 28);
    packet.packetCount = readU16BE(data + 30);
    packet.payload.assign(data + kPacketHeaderLength, data + kPacketHeaderLength + payloadLength);
    return packet;
}

std::vector<uint8_t> encodePacket(const CameraPacket &packet)
{
    std::vector<uint8_t> out;
    out.reserve(kPacketHeaderLength + packet.payload.size());
    appendU32BE(out, kPacketMagic);
    out.push_back(kPacketVersion);
    out.push_back(uint8_t(packet.kind));
    appendU16BE(out, packet.flags);
    appendU32BE(out, packet.streamId);
    appendU64BE(out, packet.frameId);
    appendU64BE(out, packet.ptsNanos);
    appendU16BE(out, packet.packetIndex);
    appendU16BE(out, packet.packetCount);
    appendU32BE(out, uint32_t(packet.payload.size()));
    out.insert(out.end(), packet.payload.begin(), packet.payload.end());
    return out;
}

std::optional<HelloPayload> parseHelloPayload(const std::vector<uint8_t> &payload)
{
    const auto json = payloadString(payload);
    HelloPayload hello;
    auto deviceName = jsonString(json, "deviceName");
    auto codec = jsonString(json, "codec");
    auto width = jsonInt(json, "width");
    auto height = jsonInt(json, "height");
    auto fps = jsonInt(json, "fps");
    auto bitrate = jsonInt(json, "bitrate");
    if (!deviceName || !codec || !width || !height || !fps || !bitrate)
        return std::nullopt;
    hello.deviceName = *deviceName;
    hello.codec = *codec;
    hello.width = *width;
    hello.height = *height;
    hello.fps = *fps;
    hello.bitrate = *bitrate;
    return hello;
}

std::optional<FormatPayload> parseFormatPayload(const std::vector<uint8_t> &payload)
{
    const auto json = payloadString(payload);
    FormatPayload format;
    auto codec = jsonString(json, "codec");
    auto width = jsonInt(json, "width");
    auto height = jsonInt(json, "height");
    auto fps = jsonInt(json, "fps");
    auto bitrate = jsonInt(json, "bitrate");
    auto sps = jsonString(json, "sps");
    auto pps = jsonString(json, "pps");
    if (!codec || !width || !height || !fps || !bitrate || !sps || !pps)
        return std::nullopt;
    auto decodedSps = decodeBase64(*sps);
    auto decodedPps = decodeBase64(*pps);
    if (!decodedSps || !decodedPps)
        return std::nullopt;
    format.codec = *codec;
    format.width = *width;
    format.height = *height;
    format.fps = *fps;
    format.bitrate = *bitrate;
    format.sps = std::move(*decodedSps);
    format.pps = std::move(*decodedPps);
    return format;
}

std::optional<std::vector<uint8_t>> decodeBase64(const std::string &input)
{
    static constexpr int8_t table[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-2,-1,-1,
        -1,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    };

    std::vector<uint8_t> out;
    int value = 0;
    int bits = -8;
    bool sawPadding = false;
    for (unsigned char c : input) {
        if (std::isspace(c))
            continue;
        if (c == '=') {
            sawPadding = true;
            continue;
        }
        if (sawPadding)
            return std::nullopt;
        const int8_t decoded = table[c];
        if (decoded < 0)
            return std::nullopt;
        value = (value << 6) | decoded;
        bits += 6;
        if (bits >= 0) {
            out.push_back(uint8_t((value >> bits) & 0xff));
            bits -= 8;
        }
    }
    return out;
}

} // namespace iphonecam
