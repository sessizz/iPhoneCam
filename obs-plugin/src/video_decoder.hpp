#pragma once

#include "protocol.hpp"

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <string>

namespace iphonecam {

struct DecodedFrame {
    DecodedFrame() = default;
    ~DecodedFrame();
    DecodedFrame(const DecodedFrame &) = delete;
    DecodedFrame &operator=(const DecodedFrame &) = delete;
    DecodedFrame(DecodedFrame &&other) noexcept;
    DecodedFrame &operator=(DecodedFrame &&other) noexcept;

    void reset();

    int width = 0;
    int height = 0;
    uint64_t ptsNanos = 0;
    uint32_t yStride = 0;
    uint32_t uvStride = 0;
    bool fullRange = true;
    CVPixelBufferRef pixelBuffer = nullptr;
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
