#pragma once

#include "protocol.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace iphonecam {

struct DecodedFrame {
    int width = 0;
    int height = 0;
    uint64_t ptsNanos = 0;
    uint32_t yStride = 0;
    uint32_t uvStride = 0;
    bool fullRange = true;
    std::vector<uint8_t> yPlane;
    std::vector<uint8_t> uvPlane;
};

class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();

    bool configure(const FormatPayload &format, std::string &error);
    bool decode(const EncodedVideoFrame &frame, DecodedFrame &decoded, std::string &error);
    void reset();

private:
    struct Impl;
    Impl *impl_ = nullptr;
};

} // namespace iphonecam
