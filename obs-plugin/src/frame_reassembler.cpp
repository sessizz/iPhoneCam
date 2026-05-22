#include "frame_reassembler.hpp"

namespace iphonecam {

FrameReassembler::FrameReassembler(std::chrono::milliseconds timeout) : timeout_(timeout) {}

std::optional<EncodedVideoFrame> FrameReassembler::accept(const CameraPacket &packet,
                                                          std::chrono::steady_clock::time_point now)
{
    dropStale(now);

    if (packet.kind != PacketKind::FrameFragment || packet.packetCount == 0 ||
        packet.packetIndex >= packet.packetCount) {
        return std::nullopt;
    }

    auto &partial = frames_[packet.frameId];
    if (partial.packetCount == 0) {
        partial.ptsNanos = packet.ptsNanos;
        partial.packetCount = packet.packetCount;
        partial.isKeyFrame = (packet.flags & kPacketFlagKeyFrame) != 0;
        partial.createdAt = now;
        partial.fragments.resize(packet.packetCount);
    }

    if (partial.packetCount != packet.packetCount)
        return std::nullopt;

    auto &slot = partial.fragments[packet.packetIndex];
    if (slot.empty()) {
        slot = packet.payload;
        partial.received += 1;
    }

    if (partial.received != partial.packetCount)
        return std::nullopt;

    EncodedVideoFrame frame;
    frame.frameId = packet.frameId;
    frame.ptsNanos = partial.ptsNanos;
    frame.isKeyFrame = partial.isKeyFrame;
    size_t totalSize = 0;
    for (const auto &fragment : partial.fragments)
        totalSize += fragment.size();
    frame.data.reserve(totalSize);
    for (const auto &fragment : partial.fragments)
        frame.data.insert(frame.data.end(), fragment.begin(), fragment.end());
    frames_.erase(packet.frameId);
    return frame;
}

void FrameReassembler::reset()
{
    frames_.clear();
    droppedFrameCount_ = 0;
}

void FrameReassembler::dropStale(std::chrono::steady_clock::time_point now)
{
    for (auto it = frames_.begin(); it != frames_.end();) {
        if (now - it->second.createdAt > timeout_) {
            it = frames_.erase(it);
            droppedFrameCount_ += 1;
        } else {
            ++it;
        }
    }
}

} // namespace iphonecam
