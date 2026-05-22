#pragma once

#include "protocol.hpp"

#include <chrono>
#include <map>
#include <optional>
#include <vector>

namespace iphonecam {

class FrameReassembler {
public:
    explicit FrameReassembler(std::chrono::milliseconds timeout = std::chrono::milliseconds(120));

    std::optional<EncodedVideoFrame> accept(const CameraPacket &packet, std::chrono::steady_clock::time_point now);
    void reset();

    int droppedFrameCount() const { return droppedFrameCount_; }

private:
    struct PartialFrame {
        uint64_t ptsNanos = 0;
        uint16_t packetCount = 0;
        uint16_t received = 0;
        bool isKeyFrame = false;
        std::chrono::steady_clock::time_point createdAt;
        std::vector<std::vector<uint8_t>> fragments;
    };

    void dropStale(std::chrono::steady_clock::time_point now);

    std::chrono::milliseconds timeout_;
    std::map<uint64_t, PartialFrame> frames_;
    int droppedFrameCount_ = 0;
};

} // namespace iphonecam
