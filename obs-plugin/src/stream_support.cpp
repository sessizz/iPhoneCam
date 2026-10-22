#include "stream_support.hpp"

#include <algorithm>
#include <cstdlib>

namespace iphonecam {

std::vector<uint8_t> encodeFramedPacket(const CameraPacket &packet)
{
    const auto encoded = encodePacket(packet);
    const auto length = uint32_t(encoded.size());
    std::vector<uint8_t> framed;
    framed.reserve(4 + encoded.size());
    framed.push_back(uint8_t(length >> 24));
    framed.push_back(uint8_t(length >> 16));
    framed.push_back(uint8_t(length >> 8));
    framed.push_back(uint8_t(length));
    framed.insert(framed.end(), encoded.begin(), encoded.end());
    return framed;
}

void PacketStreamFramer::append(const uint8_t *data, size_t size)
{
    if (desynced_ || !data || size == 0)
        return;
    // Reclaim consumed bytes once they dominate, so a long stream does not grow the buffer forever and
    // compaction costs one move per many packets instead of one per packet.
    if (readOffset_ > 0 && readOffset_ >= buffer_.size() / 2) {
        buffer_.erase(buffer_.begin(), buffer_.begin() + std::ptrdiff_t(readOffset_));
        readOffset_ = 0;
    }
    buffer_.insert(buffer_.end(), data, data + size);
}

std::optional<std::vector<uint8_t>> PacketStreamFramer::next()
{
    if (desynced_)
        return std::nullopt;
    const size_t available = buffer_.size() - readOffset_;
    if (available < 4)
        return std::nullopt;

    const uint8_t *head = buffer_.data() + readOffset_;
    const size_t length = (size_t(head[0]) << 24) | (size_t(head[1]) << 16) | (size_t(head[2]) << 8) | size_t(head[3]);
    if (length < kPacketHeaderLength || length > kMaxFramedPacketLength) {
        desynced_ = true;
        return std::nullopt;
    }
    if (available < 4 + length)
        return std::nullopt;

    std::vector<uint8_t> packet(head + 4, head + 4 + length);
    readOffset_ += 4 + length;
    if (readOffset_ == buffer_.size()) {
        buffer_.clear();
        readOffset_ = 0;
    }
    return packet;
}

void PacketStreamFramer::reset()
{
    buffer_.clear();
    readOffset_ = 0;
    desynced_ = false;
}

std::optional<HostPort> parseHostPort(const std::string &text, uint16_t defaultPort)
{
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string::npos)
        return std::nullopt;
    const auto last = text.find_last_not_of(" \t");
    const std::string trimmed = text.substr(first, last - first + 1);

    std::string host = trimmed;
    std::string portText;
    if (trimmed.front() == '[') {
        const auto close = trimmed.find(']');
        if (close == std::string::npos)
            return std::nullopt;
        host = trimmed.substr(1, close - 1);
        if (close + 1 < trimmed.size()) {
            if (trimmed[close + 1] != ':')
                return std::nullopt;
            portText = trimmed.substr(close + 2);
        }
    } else if (std::count(trimmed.begin(), trimmed.end(), ':') == 1) {
        const auto colon = trimmed.find(':');
        host = trimmed.substr(0, colon);
        portText = trimmed.substr(colon + 1);
    }
    // More than one colon without brackets is a bare IPv6 address.

    if (host.empty())
        return std::nullopt;
    uint16_t port = defaultPort;
    if (!portText.empty()) {
        char *end = nullptr;
        const long value = std::strtol(portText.c_str(), &end, 10);
        if (!end || *end != '\0' || value <= 0 || value > 65535)
            return std::nullopt;
        port = uint16_t(value);
    }
    return HostPort{host, port};
}

std::optional<uint64_t> readTimeSyncEcho(const std::vector<uint8_t> &payload)
{
    if (payload.size() != 8)
        return std::nullopt;
    uint64_t value = 0;
    for (const uint8_t byte : payload)
        value = (value << 8) | byte;
    return value;
}

void ClockOffsetEstimator::addSample(uint64_t localSendNs, uint64_t phoneNs, uint64_t localReceiveNs)
{
    if (localReceiveNs < localSendNs)
        return;
    const uint64_t rtt = localReceiveNs - localSendNs;
    const uint64_t midpoint = localSendNs + rtt / 2;
    samples_.push_back({int64_t(phoneNs) - int64_t(midpoint), rtt});
    if (samples_.size() > kWindow)
        samples_.pop_front();
}

const ClockOffsetEstimator::Sample *ClockOffsetEstimator::best() const
{
    if (samples_.empty())
        return nullptr;
    return &*std::min_element(samples_.begin(), samples_.end(),
                              [](const Sample &a, const Sample &b) { return a.rttNs < b.rttNs; });
}

int64_t ClockOffsetEstimator::offsetNs() const
{
    const auto *sample = best();
    return sample ? sample->offsetNs : 0;
}

uint64_t ClockOffsetEstimator::rttNs() const
{
    const auto *sample = best();
    return sample ? sample->rttNs : 0;
}

std::optional<uint64_t> ClockOffsetEstimator::toLocal(uint64_t phoneNs) const
{
    const auto *sample = best();
    if (!sample)
        return std::nullopt;
    const int64_t local = int64_t(phoneNs) - sample->offsetNs;
    if (local < 0)
        return std::nullopt;
    return uint64_t(local);
}

} // namespace iphonecam
