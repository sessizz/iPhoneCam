#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace iphonecam {

struct DecodedAudioFrame {
    std::vector<float> pcmData; // Interleaved Float32 stereo (L, R, L, R...)
    uint32_t frames = 0;       // Number of audio sample frames (e.g. 1024)
    uint32_t sampleRate = 48000;
    uint32_t channels = 2;
    uint64_t ptsNanos = 0;
};

class AudioDecoder {
public:
    AudioDecoder();
    ~AudioDecoder();

    bool configure(uint32_t sampleRate, uint32_t channels, const std::vector<uint8_t> &cookie, std::string &error);
    bool decode(const uint8_t *data, size_t size, uint64_t ptsNanos, DecodedAudioFrame &outFrame, std::string &error);
    void reset();

private:
    struct Impl;
    Impl *impl_ = nullptr;
};

} // namespace iphonecam
