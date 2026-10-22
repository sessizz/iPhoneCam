#pragma once

#include "protocol.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

namespace iphonecam {

// Anything longer means the byte stream is out of sync.
constexpr size_t kMaxFramedPacketLength = 32 * 1024 * 1024;

// An encoded packet behind the 4-byte big-endian length prefix the TCP stream uses.
std::vector<uint8_t> encodeFramedPacket(const CameraPacket &packet);

// Splits the TCP byte stream back into encoded packets.
class PacketStreamFramer {
public:
    void append(const uint8_t *data, size_t size);
    // The next complete encoded packet (without its length prefix), if one is buffered.
    std::optional<std::vector<uint8_t>> next();
    // Set once a length prefix was out of range; the connection should be dropped.
    bool desynced() const { return desynced_; }
    void reset();

private:
    std::vector<uint8_t> buffer_;
    size_t readOffset_ = 0;
    bool desynced_ = false;
};

struct HostPort {
    std::string host;
    uint16_t port = 0;
};

// Accepts "192.168.1.5", "192.168.1.5:8240", "name.local" and "[fe80::1]:8240".
std::optional<HostPort> parseHostPort(const std::string &text, uint16_t defaultPort);

// The time-sync response payload: the request's clock as 8 big-endian bytes.
std::optional<uint64_t> readTimeSyncEcho(const std::vector<uint8_t> &payload);

// NTP-style clock offset between the iPhone and this machine. Each round trip bounds the error by half its
// RTT, so the estimate uses the lowest-RTT sample of the recent window.
class ClockOffsetEstimator {
public:
    void addSample(uint64_t localSendNs, uint64_t phoneNs, uint64_t localReceiveNs);
    bool ready() const { return !samples_.empty(); }
    // Phone clock minus local clock.
    int64_t offsetNs() const;
    uint64_t rttNs() const;
    // The local-clock time of a phone timestamp.
    std::optional<uint64_t> toLocal(uint64_t phoneNs) const;
    void reset() { samples_.clear(); }

private:
    struct Sample {
        int64_t offsetNs;
        uint64_t rttNs;
    };
    const Sample *best() const;

    static constexpr size_t kWindow = 16;
    std::deque<Sample> samples_;
};

} // namespace iphonecam
