#pragma once

#include "frame_reassembler.hpp"
#include "network_receiver.hpp"
#include "protocol.hpp"
#include "video_decoder.hpp"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>

struct obs_data;
struct obs_source;
typedef struct obs_data obs_data_t;
typedef struct obs_source obs_source_t;

namespace iphonecam {

struct SourceSettings {
    std::string receiverName = "iPhoneCam OBS";
    int latencyMs = 60;
};

struct SourceStats {
    std::string status = "Waiting for iPhone";
    std::string deviceName = "-";
    std::string format = "No stream";
    std::string udpPort = "-";
    int receivedFrames = 0;
    int displayedFrames = 0;
    int networkDroppedFrames = 0;
    int decodeDroppedFrames = 0;
    double receivedFps = 0;
    double displayedFps = 0;
    bool waitingForKeyFrame = true;
};

class IPhoneCamSource {
public:
    IPhoneCamSource(obs_data_t *settings, obs_source_t *source);
    ~IPhoneCamSource();

    void update(obs_data_t *settings);
    void restart();
    void videoTick(float seconds);
    uint32_t width() const;
    uint32_t height() const;
    SourceStats stats() const;

private:
    void startReceiver();
    void stopReceiver();
    void handleDatagram(const std::vector<uint8_t> &data);
    void handleHello(const HelloPayload &hello);
    void handleFormat(const FormatPayload &format);
    void handleFrame(const EncodedVideoFrame &frame);
    void outputDecodedFrame(const DecodedFrame &frame);
    void outputBlackFrame();
    void updateFpsCounters();

    obs_source_t *source_ = nullptr;
    SourceSettings settings_;
    mutable std::mutex mutex_;
    SourceStats stats_;
    std::unique_ptr<NetworkReceiver> receiver_;
    std::unique_ptr<VideoDecoder> decoder_;
    FrameReassembler reassembler_;
    std::chrono::steady_clock::time_point lastFrameAt_;
    std::chrono::steady_clock::time_point lastStatsAt_;
    int receivedFramesSinceStats_ = 0;
    int displayedFramesSinceStats_ = 0;
    int invalidDatagramLogs_ = 0;
    int helloLogs_ = 0;
    int formatLogs_ = 0;
    int frameLogs_ = 0;
    int decodeErrorLogs_ = 0;
    uint32_t width_ = 1920;
    uint32_t height_ = 1080;
    bool noSignalOutput_ = false;
};

} // namespace iphonecam
