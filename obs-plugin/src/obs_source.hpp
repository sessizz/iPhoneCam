#pragma once

#include "frame_reassembler.hpp"
#include "network_receiver.hpp"
#include "protocol.hpp"
#include "video_decoder.hpp"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include <dispatch/dispatch.h>

struct obs_data;
struct obs_source;
typedef struct obs_data obs_data_t;
typedef struct obs_source obs_source_t;

namespace iphonecam {

struct SourceSettings {
    std::string receiverName = "iPhoneCam OBS";
    int latencyMs = 0;
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
    void decodeFrame(const EncodedVideoFrame &frame);
    void resetDecoder();
    void outputDecodedFrame(const DecodedFrame &frame);
    void outputBlackFrame();
    void beginLatencyCatchUp();
    int maxPendingDecodeFrames() const;
    void updateFpsCounters();
    void applyLatencyMode();
    void markStatsDirty();

    obs_source_t *source_ = nullptr;
    SourceSettings settings_;
    mutable std::mutex mutex_;
    SourceStats stats_;
    std::unique_ptr<NetworkReceiver> receiver_;
    std::unique_ptr<VideoDecoder> decoder_;
    std::optional<FormatPayload> lastFormat_;
    std::mutex decoderMutex_;
    dispatch_queue_t decodeQueue_ = dispatch_queue_create("iphonecam.obs.decode", DISPATCH_QUEUE_SERIAL);
    FrameReassembler reassembler_;
    std::chrono::steady_clock::time_point lastFrameAt_;
    std::chrono::steady_clock::time_point lastStatsAt_;
    std::atomic<bool> statsDirty_ = true;
    std::atomic<int> pendingDecodeFrames_ = 0;
    std::atomic<uint64_t> decodeGeneration_ = 0;
    std::atomic<bool> droppingUntilKeyFrame_ = false;
    int receivedFramesSinceStats_ = 0;
    int displayedFramesSinceStats_ = 0;
    int invalidDatagramLogs_ = 0;
    int helloLogs_ = 0;
    int formatLogs_ = 0;
    int frameLogs_ = 0;
    int decodeErrorLogs_ = 0;
    int completedFrameLogs_ = 0;
    int waitKeyFrameLogs_ = 0;
    int lastLoggedNetworkDrops_ = 0;
    int decodeAttemptLogs_ = 0;
    int outputFrameLogs_ = 0;
    int latencyCatchUpLogs_ = 0;
    uint32_t width_ = 1920;
    uint32_t height_ = 1080;
    bool noSignalOutput_ = false;
};

} // namespace iphonecam
