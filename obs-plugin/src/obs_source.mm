#include "obs_source.hpp"

#import <CoreVideo/CoreVideo.h>

#include <obs-module.h>
#include <util/platform.h>

#include <algorithm>
#include <cstdio>
#include <vector>

namespace iphonecam {
namespace {

constexpr const char *kSettingReceiverName = "receiver_name";
constexpr const char *kSettingLatency = "latency_ms";
constexpr uint64_t kOneSecondNanos = 1000000000ULL;

const char *packetKindName(PacketKind kind)
{
    switch (kind) {
    case PacketKind::Hello:
        return "hello";
    case PacketKind::Format:
        return "format";
    case PacketKind::FrameFragment:
        return "frame";
    }
    return "unknown";
}

std::string formatStats(const SourceStats &stats)
{
    char buffer[768];
    std::snprintf(buffer, sizeof(buffer),
                  "Status: %s\n"
                  "Device: %s\n"
                  "Format: %s\n"
                  "UDP Port: %s\n"
                  "Received FPS: %.1f\n"
                  "Displayed FPS: %.1f\n"
                  "Received Frames: %d\n"
                  "Displayed Frames: %d\n"
                  "Network Dropped: %d\n"
                  "Decode Dropped: %d\n"
                  "Waiting For Keyframe: %s\n"
                  "No Signal: black after 1s",
                  stats.status.c_str(), stats.deviceName.c_str(), stats.format.c_str(), stats.udpPort.c_str(),
                  stats.receivedFps, stats.displayedFps, stats.receivedFrames, stats.displayedFrames,
                  stats.networkDroppedFrames, stats.decodeDroppedFrames, stats.waitingForKeyFrame ? "yes" : "no");
    return buffer;
}

SourceSettings readSettings(obs_data_t *settings)
{
    SourceSettings result;
    const char *receiverName = obs_data_get_string(settings, kSettingReceiverName);
    if (receiverName && *receiverName)
        result.receiverName = receiverName;
    const long long latency = obs_data_get_int(settings, kSettingLatency);
    if (latency == 0 || latency == 60 || latency == 120)
        result.latencyMs = int(latency);
    return result;
}

} // namespace

IPhoneCamSource::IPhoneCamSource(obs_data_t *settings, obs_source_t *source)
    : source_(source),
      settings_(readSettings(settings)),
      receiver_(std::make_unique<NetworkReceiver>()),
      decoder_(std::make_unique<VideoDecoder>()),
      reassembler_(std::chrono::milliseconds(120)),
      lastFrameAt_(std::chrono::steady_clock::now()),
      lastStatsAt_(std::chrono::steady_clock::now())
{
    applyLatencyMode();
    receiver_->setStatusCallback([this](const std::string &status, uint16_t port) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.status = status;
            stats_.udpPort = port == 0 ? "-" : std::to_string(port);
        }
        markStatsDirty();
    });
    receiver_->setPacketCallback([this](const std::vector<uint8_t> &data) { handleDatagram(data); });
    startReceiver();
}

IPhoneCamSource::~IPhoneCamSource()
{
    stopReceiver();
    dispatch_sync(decodeQueue_, ^{
      decoder_->reset();
      pendingDecodeFrames_ = 0;
    });
    obs_source_output_video(source_, nullptr);
}

void IPhoneCamSource::update(obs_data_t *settings)
{
    const auto next = readSettings(settings);
    const bool restartNeeded = next.receiverName != settings_.receiverName;
    const bool latencyChanged = next.latencyMs != settings_.latencyMs;
    settings_ = next;
    if (latencyChanged)
        applyLatencyMode();
    if (restartNeeded)
        restart();
}

void IPhoneCamSource::restart()
{
    stopReceiver();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_ = SourceStats{};
        stats_.status = "Restarting receiver";
        reassembler_.reset();
        lastFormat_.reset();
        noSignalOutput_ = false;
    }
    markStatsDirty();
    resetDecoder();
    startReceiver();
}

void IPhoneCamSource::videoTick(float)
{
    updateFpsCounters();
    const auto now = std::chrono::steady_clock::now();
    if (now - lastFrameAt_ > std::chrono::seconds(1) && !noSignalOutput_) {
        outputBlackFrame();
        noSignalOutput_ = true;
    }
}

uint32_t IPhoneCamSource::width() const
{
    return width_;
}

uint32_t IPhoneCamSource::height() const
{
    return height_;
}

SourceStats IPhoneCamSource::stats() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

void IPhoneCamSource::startReceiver()
{
    receiver_->start(settings_.receiverName);
}

void IPhoneCamSource::stopReceiver()
{
    if (receiver_)
        receiver_->stop();
}

void IPhoneCamSource::handleDatagram(const std::vector<uint8_t> &data)
{
    auto packet = parsePacket(data.data(), data.size());
    if (!packet) {
        if (invalidDatagramLogs_ < 10) {
            blog(LOG_WARNING, "[iPhoneCam] Dropped invalid UDP datagram (%zu bytes)", data.size());
            invalidDatagramLogs_ += 1;
        }
        return;
    }

    if (frameLogs_ < 5 || packet->kind != PacketKind::FrameFragment) {
        blog(LOG_INFO, "[iPhoneCam] Packet kind=%s frame=%llu fragment=%u/%u payload=%zu flags=%u",
             packetKindName(packet->kind), static_cast<unsigned long long>(packet->frameId), packet->packetIndex + 1,
             packet->packetCount, packet->payload.size(), packet->flags);
        if (packet->kind == PacketKind::FrameFragment)
            frameLogs_ += 1;
    }

    switch (packet->kind) {
    case PacketKind::Hello:
        if (auto hello = parseHelloPayload(packet->payload)) {
            handleHello(*hello);
        } else if (helloLogs_ < 5) {
            blog(LOG_WARNING, "[iPhoneCam] Failed to parse hello payload (%zu bytes)", packet->payload.size());
            helloLogs_ += 1;
        }
        break;
    case PacketKind::Format:
        if (auto format = parseFormatPayload(packet->payload)) {
            handleFormat(*format);
        } else if (formatLogs_ < 5) {
            blog(LOG_WARNING, "[iPhoneCam] Failed to parse format payload (%zu bytes)", packet->payload.size());
            formatLogs_ += 1;
        }
        break;
    case PacketKind::FrameFragment: {
        auto frame = reassembler_.accept(*packet, std::chrono::steady_clock::now());
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.networkDroppedFrames = reassembler_.droppedFrameCount();
        }
        const int droppedFrames = reassembler_.droppedFrameCount();
        if (droppedFrames != lastLoggedNetworkDrops_ && droppedFrames <= 20) {
            blog(LOG_WARNING, "[iPhoneCam] Reassembler dropped stale frames: %d", droppedFrames);
            lastLoggedNetworkDrops_ = droppedFrames;
        }
        if (frame) {
            if (completedFrameLogs_ < 10) {
                blog(LOG_INFO, "[iPhoneCam] Completed frame %llu size=%zu keyframe=%s",
                     static_cast<unsigned long long>(frame->frameId), frame->data.size(),
                     frame->isKeyFrame ? "yes" : "no");
                completedFrameLogs_ += 1;
            }
            handleFrame(*frame);
        }
        break;
    }
    }
}

void IPhoneCamSource::handleHello(const HelloPayload &hello)
{
    blog(LOG_INFO, "[iPhoneCam] Hello from '%s': %dx%d @ %d FPS, %d bps", hello.deviceName.c_str(), hello.width,
         hello.height, hello.fps, hello.bitrate);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.status = "Connected: " + hello.deviceName;
        stats_.deviceName = hello.deviceName;
        stats_.format = std::to_string(hello.width) + "x" + std::to_string(hello.height) + " @ " +
                        std::to_string(hello.fps) + " FPS, " + std::to_string(hello.bitrate / 1000000) + " Mbps";
    }
    markStatsDirty();
}

void IPhoneCamSource::handleFormat(const FormatPayload &format)
{
    blog(LOG_INFO, "[iPhoneCam] Format received: %dx%d @ %d FPS, sps=%zu pps=%zu", format.width, format.height,
         format.fps, format.sps.size(), format.pps.size());
    decodeGeneration_.fetch_add(1);
    droppingUntilKeyFrame_ = false;
    width_ = uint32_t(format.width);
    height_ = uint32_t(format.height);
    reassembler_.reset();

    {
        std::lock_guard<std::mutex> lock(mutex_);
        lastFormat_ = format;
        stats_.format = std::to_string(format.width) + "x" + std::to_string(format.height) + " @ " +
                        std::to_string(format.fps) + " FPS, " + std::to_string(format.bitrate / 1000000) + " Mbps";
        stats_.waitingForKeyFrame = true;
        stats_.networkDroppedFrames = 0;
    }
    markStatsDirty();

    std::string error;
    {
        std::lock_guard<std::mutex> decoderLock(decoderMutex_);
        if (!decoder_->configure(format, error)) {
            blog(LOG_ERROR, "[iPhoneCam] Decoder configure failed: %s", error.c_str());
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stats_.status = "Format error: " + error;
                stats_.waitingForKeyFrame = true;
            }
            markStatsDirty();
        }
    }
}

void IPhoneCamSource::handleFrame(const EncodedVideoFrame &frame)
{
    if (!droppingUntilKeyFrame_.load() && pendingDecodeFrames_.load() > maxPendingDecodeFrames())
        beginLatencyCatchUp();

    if (droppingUntilKeyFrame_.load()) {
        if (!frame.isKeyFrame)
            return;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stats_.waitingForKeyFrame && !frame.isKeyFrame) {
            if (waitKeyFrameLogs_ < 10) {
                blog(LOG_INFO, "[iPhoneCam] Completed non-keyframe %llu while waiting for keyframe",
                     static_cast<unsigned long long>(frame.frameId));
                waitKeyFrameLogs_ += 1;
            }
            return;
        }
        stats_.waitingForKeyFrame = false;
        stats_.receivedFrames += 1;
        receivedFramesSinceStats_ += 1;
    }

    auto *frameCopy = new EncodedVideoFrame(frame);
    const uint64_t generation = decodeGeneration_.load();
    pendingDecodeFrames_ += 1;
    dispatch_async(decodeQueue_, ^{
      std::unique_ptr<EncodedVideoFrame> frameGuard(frameCopy);
      if (generation == decodeGeneration_.load())
          decodeFrame(*frameGuard);
      pendingDecodeFrames_ -= 1;
    });
}

void IPhoneCamSource::decodeFrame(const EncodedVideoFrame &frame)
{
    DecodedFrame decoded;
    std::string error;
    if (decodeAttemptLogs_ < 10) {
        blog(LOG_INFO, "[iPhoneCam] Decoding frame %llu size=%zu keyframe=%s",
             static_cast<unsigned long long>(frame.frameId), frame.data.size(), frame.isKeyFrame ? "yes" : "no");
        decodeAttemptLogs_ += 1;
    }
    {
        std::lock_guard<std::mutex> decoderLock(decoderMutex_);
        if (!decoder_->decode(frame, decoded, error)) {
            if (decodeErrorLogs_ < 10) {
                blog(LOG_WARNING, "[iPhoneCam] Decode dropped frame %llu: %s",
                     static_cast<unsigned long long>(frame.frameId), error.c_str());
                decodeErrorLogs_ += 1;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stats_.decodeDroppedFrames += 1;
                stats_.status = "Decode error: " + error;
                stats_.waitingForKeyFrame = true;
            }
            markStatsDirty();
            return;
        }
    }

    outputDecodedFrame(decoded);
    if (frame.isKeyFrame && droppingUntilKeyFrame_.load())
        droppingUntilKeyFrame_ = false;
    lastFrameAt_ = std::chrono::steady_clock::now();
    noSignalOutput_ = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.displayedFrames += 1;
        displayedFramesSinceStats_ += 1;
    }
}

void IPhoneCamSource::resetDecoder()
{
    decodeGeneration_.fetch_add(1);
    droppingUntilKeyFrame_ = false;
    dispatch_sync(decodeQueue_, ^{});
    std::lock_guard<std::mutex> decoderLock(decoderMutex_);
    decoder_->reset();
    pendingDecodeFrames_ = 0;
}

void IPhoneCamSource::beginLatencyCatchUp()
{
    bool expected = false;
    if (!droppingUntilKeyFrame_.compare_exchange_strong(expected, true))
        return;

    const uint64_t generation = decodeGeneration_.fetch_add(1) + 1;
    const int pending = pendingDecodeFrames_.load();
    if (latencyCatchUpLogs_ < 10) {
        blog(LOG_WARNING, "[iPhoneCam] Decode queue is behind (%d pending), dropping to next keyframe", pending);
        latencyCatchUpLogs_ += 1;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.waitingForKeyFrame = true;
        stats_.decodeDroppedFrames += pending;
    }
    markStatsDirty();

    dispatch_async(decodeQueue_, ^{
      if (generation != decodeGeneration_.load())
          return;

      std::optional<FormatPayload> format;
      {
          std::lock_guard<std::mutex> lock(mutex_);
          format = lastFormat_;
      }

      std::lock_guard<std::mutex> decoderLock(decoderMutex_);
      decoder_->reset();
      if (format) {
          std::string error;
          if (!decoder_->configure(*format, error)) {
              blog(LOG_ERROR, "[iPhoneCam] Decoder reconfigure during latency catch-up failed: %s", error.c_str());
              std::lock_guard<std::mutex> lock(mutex_);
              stats_.status = "Format error: " + error;
          }
      }
    });
}

void IPhoneCamSource::outputDecodedFrame(const DecodedFrame &frame)
{
    if (!frame.pixelBuffer)
        return;

    if (outputFrameLogs_ < 10) {
        blog(LOG_INFO, "[iPhoneCam] Output decoded frame %dx%d yStride=%u uvStride=%u", frame.width, frame.height,
             frame.yStride, frame.uvStride);
        outputFrameLogs_ += 1;
    }

    if (CVPixelBufferLockBaseAddress(frame.pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return;

    obs_source_frame obsFrame = {};
    obsFrame.data[0] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(frame.pixelBuffer, 0));
    obsFrame.data[1] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(frame.pixelBuffer, 1));
    obsFrame.linesize[0] = uint32_t(CVPixelBufferGetBytesPerRowOfPlane(frame.pixelBuffer, 0));
    obsFrame.linesize[1] = uint32_t(CVPixelBufferGetBytesPerRowOfPlane(frame.pixelBuffer, 1));
    obsFrame.width = uint32_t(CVPixelBufferGetWidth(frame.pixelBuffer));
    obsFrame.height = uint32_t(CVPixelBufferGetHeight(frame.pixelBuffer));
    obsFrame.timestamp = os_gettime_ns() + uint64_t(settings_.latencyMs) * 1000000ULL;
    obsFrame.format = VIDEO_FORMAT_NV12;
    obsFrame.full_range = frame.fullRange;
    obsFrame.trc = VIDEO_TRC_DEFAULT;
    const enum video_range_type range = frame.fullRange ? VIDEO_RANGE_FULL : VIDEO_RANGE_PARTIAL;
    if (!video_format_get_parameters_for_format(VIDEO_CS_709, range, obsFrame.format, obsFrame.color_matrix,
                                                obsFrame.color_range_min, obsFrame.color_range_max)) {
        blog(LOG_WARNING, "[iPhoneCam] Failed to set OBS color parameters for decoded frame");
    }
    obsFrame.flip = false;
    obs_source_output_video(source_, &obsFrame);

    CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

void IPhoneCamSource::outputBlackFrame()
{
    const uint32_t w = std::max<uint32_t>(width_, 2);
    const uint32_t h = std::max<uint32_t>(height_, 2);
    std::vector<uint8_t> y(size_t(w) * size_t(h), 0);
    std::vector<uint8_t> uv(size_t(w) * size_t(h / 2), 128);

    obs_source_frame obsFrame = {};
    obsFrame.data[0] = y.data();
    obsFrame.data[1] = uv.data();
    obsFrame.linesize[0] = w;
    obsFrame.linesize[1] = w;
    obsFrame.width = w;
    obsFrame.height = h;
    obsFrame.timestamp = os_gettime_ns();
    obsFrame.format = VIDEO_FORMAT_NV12;
    obsFrame.full_range = true;
    obsFrame.trc = VIDEO_TRC_DEFAULT;
    video_format_get_parameters_for_format(VIDEO_CS_709, VIDEO_RANGE_FULL, obsFrame.format, obsFrame.color_matrix,
                                           obsFrame.color_range_min, obsFrame.color_range_max);
    obs_source_output_video(source_, &obsFrame);
}

int IPhoneCamSource::maxPendingDecodeFrames() const
{
    if (settings_.latencyMs == 0)
        return 12;
    if (settings_.latencyMs == 60)
        return 24;
    return 36;
}

void IPhoneCamSource::updateFpsCounters()
{
    const auto now = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration<double>(now - lastStatsAt_).count();
    if (elapsed < 1.0)
        return;

    std::lock_guard<std::mutex> lock(mutex_);
    stats_.receivedFps = double(receivedFramesSinceStats_) / elapsed;
    stats_.displayedFps = double(displayedFramesSinceStats_) / elapsed;
    receivedFramesSinceStats_ = 0;
    displayedFramesSinceStats_ = 0;
    lastStatsAt_ = now;
    markStatsDirty();
}

void IPhoneCamSource::applyLatencyMode()
{
    obs_source_set_async_decoupled(source_, true);
    obs_source_set_async_unbuffered(source_, settings_.latencyMs == 0);
}

void IPhoneCamSource::markStatsDirty()
{
    statsDirty_ = true;
}

} // namespace iphonecam

using iphonecam::IPhoneCamSource;

static const char *iphonecam_get_name(void *)
{
    return "iPhoneCam";
}

static void *iphonecam_create(obs_data_t *settings, obs_source_t *source)
{
    return new IPhoneCamSource(settings, source);
}

static void iphonecam_destroy(void *data)
{
    delete static_cast<IPhoneCamSource *>(data);
}

static uint32_t iphonecam_get_width(void *data)
{
    return static_cast<IPhoneCamSource *>(data)->width();
}

static uint32_t iphonecam_get_height(void *data)
{
    return static_cast<IPhoneCamSource *>(data)->height();
}

static void iphonecam_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "receiver_name", "iPhoneCam OBS");
    obs_data_set_default_int(settings, "latency_ms", 0);
}

static bool iphonecam_restart_clicked(obs_properties_t *, obs_property_t *, void *data)
{
    if (data)
        static_cast<IPhoneCamSource *>(data)->restart();
    return true;
}

static bool iphonecam_refresh_stats_clicked(obs_properties_t *props, obs_property_t *, void *data)
{
    obs_property_t *statsProperty = obs_properties_get(props, "stats");
    if (!statsProperty || !data)
        return true;

    const auto stats = static_cast<IPhoneCamSource *>(data)->stats();
    obs_property_set_description(statsProperty, iphonecam::formatStats(stats).c_str());
    return true;
}

static obs_properties_t *iphonecam_properties(void *data)
{
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_text(props, "receiver_name", "Receiver name", OBS_TEXT_DEFAULT);

    obs_property_t *latency = obs_properties_add_list(props, "latency_ms", "Latency", OBS_COMBO_TYPE_LIST,
                                                      OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(latency, "Low 0 ms", 0);
    obs_property_list_add_int(latency, "Balanced 60 ms", 60);
    obs_property_list_add_int(latency, "Smooth 120 ms", 120);

    obs_properties_add_button(props, "restart_receiver", "Restart Receiver", iphonecam_restart_clicked);
    obs_properties_add_button(props, "refresh_stats", "Refresh Stats", iphonecam_refresh_stats_clicked);
    obs_properties_add_text(props, "no_signal_info", "No signal: last frame is held for 1s, then black.",
                            OBS_TEXT_INFO);

    if (data) {
        const auto stats = static_cast<IPhoneCamSource *>(data)->stats();
        obs_properties_add_text(props, "stats", iphonecam::formatStats(stats).c_str(), OBS_TEXT_INFO);
    } else {
        obs_properties_add_text(props, "stats", "Stats appear after the source starts.", OBS_TEXT_INFO);
    }

    return props;
}

static void iphonecam_update(void *data, obs_data_t *settings)
{
    static_cast<IPhoneCamSource *>(data)->update(settings);
}

static void iphonecam_tick(void *data, float seconds)
{
    static_cast<IPhoneCamSource *>(data)->videoTick(seconds);
}

obs_source_info iphonecam_source_info = [] {
    obs_source_info info = {};
    info.id = "iphonecam_source";
    info.type = OBS_SOURCE_TYPE_INPUT;
    info.output_flags = OBS_SOURCE_ASYNC_VIDEO;
    info.get_name = iphonecam_get_name;
    info.create = iphonecam_create;
    info.destroy = iphonecam_destroy;
    info.get_width = iphonecam_get_width;
    info.get_height = iphonecam_get_height;
    info.get_defaults = iphonecam_defaults;
    info.get_properties = iphonecam_properties;
    info.update = iphonecam_update;
    info.video_tick = iphonecam_tick;
    info.icon_type = OBS_ICON_TYPE_CAMERA;
    return info;
}();
