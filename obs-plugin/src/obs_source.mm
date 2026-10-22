#include "obs_source.hpp"

#import <CoreVideo/CoreVideo.h>

#include <obs-module.h>
#include <util/platform.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <vector>

namespace iphonecam {
namespace {

constexpr const char *kSettingConnectionMode = "connection_mode";
constexpr const char *kSettingHost = "host";
constexpr const char *kSettingTargetDevice = "target_device";
constexpr const char *kSettingLatency = "latency_ms";
constexpr const char *kSettingAudioEnabled = "audio_enabled";
constexpr const char *kSettingAudioOffset = "audio_offset_ms";
constexpr uint64_t kOneSecondNanos = 1000000000ULL;
constexpr auto kKeyFrameRequestInterval = std::chrono::milliseconds(250);
constexpr auto kTimeSyncInterval = std::chrono::seconds(1);
constexpr const char *kModeUsb = "usb";
constexpr const char *kModeWiFi = "wifi";

const char *packetKindName(PacketKind kind)
{
    switch (kind) {
    case PacketKind::Hello:
        return "hello";
    case PacketKind::Format:
        return "format";
    case PacketKind::FrameFragment:
        return "frame";
    case PacketKind::Control:
        return "control";
    case PacketKind::Audio:
        return "audio";
    case PacketKind::Ping:
        return "ping";
    case PacketKind::TimeSyncRequest:
        return "timesync-request";
    case PacketKind::TimeSyncResponse:
        return "timesync-response";
    }
    return "unknown";
}

std::string formatMilliseconds(double value)
{
    if (value < 0)
        return "measuring...";
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.0f ms", value);
    return buffer;
}

std::string formatStats(const SourceStats &stats)
{
    char buffer[1024];
    std::snprintf(buffer, sizeof(buffer),
                  "Status: %s\n"
                  "Target: %s\n"
                  "Device: %s\n"
                  "Format: %s\n"
                  "Connection: %s\n"
                  "Latency (capture to decode): %s\n"
                  "Clock round trip: %s\n"
                  "Received FPS: %.1f\n"
                  "Displayed FPS: %.1f\n"
                  "Received Frames: %d\n"
                  "Displayed Frames: %d\n"
                  "Network Dropped: %d\n"
                  "Decode Dropped: %d\n"
                  "Keyframe Requests: %d\n"
                  "Waiting For Keyframe: %s\n"
                  "No Signal: black after 1s",
                  stats.status.c_str(), stats.targetDevice.c_str(), stats.deviceName.c_str(),
                  stats.format.c_str(), stats.connection.c_str(), formatMilliseconds(stats.latencyMs).c_str(),
                  formatMilliseconds(stats.clockRttMs).c_str(),
                  stats.receivedFps, stats.displayedFps, stats.receivedFrames, stats.displayedFrames,
                  stats.networkDroppedFrames, stats.decodeDroppedFrames, stats.keyFrameRequests,
                  stats.waitingForKeyFrame ? "yes" : "no");
    return buffer;
}

SourceSettings readSettings(obs_data_t *settings)
{
    SourceSettings result;
    const char *mode = obs_data_get_string(settings, kSettingConnectionMode);
    result.mode = (mode && std::strcmp(mode, kModeWiFi) == 0) ? ConnectionMode::WiFi : ConnectionMode::Usb;
    const char *host = obs_data_get_string(settings, kSettingHost);
    if (host && *host)
        result.host = host;
    const char *targetDevice = obs_data_get_string(settings, kSettingTargetDevice);
    if (targetDevice && *targetDevice)
        result.targetDevice = targetDevice;
    const long long latency = obs_data_get_int(settings, kSettingLatency);
    if (latency == 0 || latency == 60 || latency == 120)
        result.latencyMs = int(latency);
    result.audioEnabled = obs_data_get_bool(settings, kSettingAudioEnabled);
    result.audioOffsetMs = int(obs_data_get_int(settings, kSettingAudioOffset));
    return result;
}

void zoomInSlowHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomIn, ControlSpeed::Slow, pressed);
}

void zoomInMediumHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomIn, ControlSpeed::Medium, pressed);
}

void zoomInFastHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomIn, ControlSpeed::Fast, pressed);
}

void zoomOutSlowHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomOut, ControlSpeed::Slow, pressed);
}

void zoomOutMediumHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomOut, ControlSpeed::Medium, pressed);
}

void zoomOutFastHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleZoomHotkey(ControlAction::ZoomOut, ControlSpeed::Fast, pressed);
}

void resetZoomHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleResetZoomHotkey(pressed);
}

template <ControlAction Action> void actionHotkey(void *data, obs_hotkey_id, obs_hotkey_t *, bool pressed)
{
    static_cast<IPhoneCamSource *>(data)->handleActionHotkey(Action, pressed);
}

} // namespace

IPhoneCamSource::IPhoneCamSource(obs_data_t *settings, obs_source_t *source)
    : source_(source),
      settings_(readSettings(settings)),
      receiver_(std::make_unique<NetworkReceiver>()),
      decoder_(std::make_unique<VideoDecoder>()),
      audioDecoder_(std::make_unique<AudioDecoder>()),
      reassembler_(std::chrono::milliseconds(120)),
      lastFrameAt_(std::chrono::steady_clock::now()),
      lastStatsAt_(std::chrono::steady_clock::now())
{
    applyLatencyMode();
    receiver_->setStatusCallback([this](const std::string &status, const std::string &connection, bool connected) {
        handleConnectionStatus(status, connection, connected);
    });
    receiver_->setPacketCallback([this](const std::vector<uint8_t> &data) { handlePacket(data); });
    registerHotkeys();
    startReceiver();
}

IPhoneCamSource::~IPhoneCamSource()
{
    unregisterHotkeys();
    stopReceiver();
    decodeGeneration_.fetch_add(1);
    dispatch_sync(decodeQueue_, ^{
      decoder_->reset();
      pendingDecodeFrames_ = 0;
    });
    obs_source_output_video(source_, nullptr);
}

void IPhoneCamSource::update(obs_data_t *settings)
{
    const auto next = readSettings(settings);
    const bool restartNeeded =
        next.mode != settings_.mode || next.host != settings_.host || next.targetDevice != settings_.targetDevice;
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
    sendTimeSyncRequest();
    // Catches every way the source can go on or off air; only changes are sent.
    updateTally(false);
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
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (settings_.mode == ConnectionMode::WiFi)
            stats_.targetDevice = settings_.host.empty() ? "Wi-Fi (no address)" : "Wi-Fi: " + settings_.host;
        else
            stats_.targetDevice = settings_.targetDevice.empty() ? "USB (first iPhone)" : "USB: " + settings_.targetDevice;
    }
    ReceiverConfig config;
    config.mode = settings_.mode;
    config.host = settings_.host;
    config.targetDevice = settings_.targetDevice;
    receiver_->start(config);
}

void IPhoneCamSource::handleConnectionStatus(const std::string &status, const std::string &connection, bool connected)
{
    const bool changed = connected_.exchange(connected) != connected;
    if (changed) {
        // A new link may reach a different iPhone (or the same one after a restart): measure afresh.
        std::lock_guard<std::mutex> lock(clockMutex_);
        clock_.reset();
        latencyAverageMs_ = -1;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.status = status;
        stats_.connection = connection.empty() ? "-" : connection;
        stats_.connected = connected;
        if (changed) {
            stats_.latencyMs = -1;
            stats_.clockRttMs = -1;
        }
    }
    markStatsDirty();
    if (changed && connected) {
        // The iPhone forgets the tally with every connection.
        updateTally(true);
    }
}

void IPhoneCamSource::sendTimeSyncRequest()
{
    if (!connected_.load())
        return;
    const auto now = std::chrono::steady_clock::now();
    if (now - lastTimeSyncAt_ < kTimeSyncInterval)
        return;
    lastTimeSyncAt_ = now;

    CameraPacket packet;
    packet.kind = PacketKind::TimeSyncRequest;
    packet.streamId = 1;
    packet.ptsNanos = os_gettime_ns();
    receiver_->sendPacket(packet);
}

void IPhoneCamSource::handleTimeSyncResponse(const CameraPacket &packet)
{
    const uint64_t receivedAt = os_gettime_ns();
    const auto sentAt = readTimeSyncEcho(packet.payload);
    if (!sentAt)
        return;
    double rttMs = -1;
    {
        std::lock_guard<std::mutex> lock(clockMutex_);
        clock_.addSample(*sentAt, packet.ptsNanos, receivedAt);
        if (clock_.ready())
            rttMs = double(clock_.rttNs()) / 1e6;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.clockRttMs = rttMs;
    }
    markStatsDirty();
}

void IPhoneCamSource::noteFrameLatency(uint64_t ptsNanos)
{
    const uint64_t now = os_gettime_ns();
    double average = -1;
    {
        std::lock_guard<std::mutex> lock(clockMutex_);
        const auto capturedAt = clock_.toLocal(ptsNanos);
        if (!capturedAt || *capturedAt > now)
            return;
        const double latencyMs = double(now - *capturedAt) / 1e6;
        latencyAverageMs_ = latencyAverageMs_ < 0 ? latencyMs : latencyAverageMs_ * 0.9 + latencyMs * 0.1;
        average = latencyAverageMs_;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.latencyMs = average;
}

void IPhoneCamSource::stopReceiver()
{
    if (receiver_)
        receiver_->stop();
}

void IPhoneCamSource::registerHotkeys()
{
    struct HotkeyDefinition {
        const char *name;
        const char *description;
        obs_hotkey_func callback;
    };

    const HotkeyDefinition definitions[] = {
        {"iphonecam.zoom_in_slow", "iPhoneCam: Zoom In Slow", zoomInSlowHotkey},
        {"iphonecam.zoom_in_medium", "iPhoneCam: Zoom In Medium", zoomInMediumHotkey},
        {"iphonecam.zoom_in_fast", "iPhoneCam: Zoom In Fast", zoomInFastHotkey},
        {"iphonecam.zoom_out_slow", "iPhoneCam: Zoom Out Slow", zoomOutSlowHotkey},
        {"iphonecam.zoom_out_medium", "iPhoneCam: Zoom Out Medium", zoomOutMediumHotkey},
        {"iphonecam.zoom_out_fast", "iPhoneCam: Zoom Out Fast", zoomOutFastHotkey},
        {"iphonecam.reset_zoom", "iPhoneCam: Reset Zoom", resetZoomHotkey},
        {"iphonecam.toggle_torch", "iPhoneCam: Toggle Flashlight", actionHotkey<ControlAction::ToggleTorch>},
        {"iphonecam.switch_camera", "iPhoneCam: Switch Front/Back Camera", actionHotkey<ControlAction::SwitchCamera>},
        {"iphonecam.focus_exposure_lock", "iPhoneCam: Lock/Unlock Focus and Exposure",
         actionHotkey<ControlAction::ToggleFocusExposureLock>},
        {"iphonecam.exposure_up", "iPhoneCam: Exposure +", actionHotkey<ControlAction::ExposureUp>},
        {"iphonecam.exposure_down", "iPhoneCam: Exposure -", actionHotkey<ControlAction::ExposureDown>},
        {"iphonecam.white_balance_lock", "iPhoneCam: Lock/Unlock White Balance",
         actionHotkey<ControlAction::ToggleWhiteBalanceLock>},
        {"iphonecam.reset_image", "iPhoneCam: Focus, Exposure and White Balance to Auto",
         actionHotkey<ControlAction::ResetImageControls>},
    };

    for (const auto &definition : definitions) {
        const auto id = obs_hotkey_register_source(source_, definition.name, definition.description,
                                                   definition.callback, this);
        if (id != OBS_INVALID_HOTKEY_ID)
            hotkeyIds_.push_back(id);
    }
}

void IPhoneCamSource::unregisterHotkeys()
{
    for (const auto id : hotkeyIds_) {
        if (id != OBS_INVALID_HOTKEY_ID)
            obs_hotkey_unregister(id);
    }
    hotkeyIds_.clear();
}

void IPhoneCamSource::handleZoomHotkey(ControlAction action, ControlSpeed speed, bool pressed)
{
    ControlCommand command;
    command.action = pressed ? action : ControlAction::StopZoom;
    command.speed = speed;
    sendControlCommand(command);
}

void IPhoneCamSource::handleResetZoomHotkey(bool pressed)
{
    if (!pressed)
        return;

    ControlCommand command;
    command.action = ControlAction::ResetZoom;
    sendControlCommand(command);
}

void IPhoneCamSource::handleActionHotkey(ControlAction action, bool pressed)
{
    if (!pressed)
        return;
    ControlCommand command;
    command.action = action;
    sendControlCommand(command);
}

void IPhoneCamSource::updateTally(bool force)
{
    const bool program = obs_source_active(source_);
    const bool preview = !program && obs_source_showing(source_);
    {
        std::lock_guard<std::mutex> lock(tallyMutex_);
        if (!force && tallySent_ && program == tallyProgram_ && preview == tallyPreview_)
            return;
        tallySent_ = true;
        tallyProgram_ = program;
        tallyPreview_ = preview;
    }
    if (!connected_.load())
        return;
    ControlCommand command;
    command.action = ControlAction::Tally;
    command.program = program;
    command.preview = preview;
    sendControlCommand(command);
}

void IPhoneCamSource::sendControlCommand(const ControlCommand &command)
{
    if (receiver_)
        receiver_->sendControlCommand(command);
}

void IPhoneCamSource::requestKeyFrame()
{
    const auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (now - lastKeyFrameRequestAt_ < kKeyFrameRequestInterval)
            return;
        lastKeyFrameRequestAt_ = now;
        stats_.keyFrameRequests += 1;
        if (keyFrameRequestLogs_ < 10) {
            blog(LOG_INFO, "[iPhoneCam] Requesting keyframe from iPhone");
            keyFrameRequestLogs_ += 1;
        }
    }
    markStatsDirty();

    ControlCommand command;
    command.action = ControlAction::RequestKeyFrame;
    sendControlCommand(command);
}

void IPhoneCamSource::handlePacket(const std::vector<uint8_t> &data)
{
    auto packet = parsePacket(data.data(), data.size());
    if (!packet) {
        if (invalidDatagramLogs_ < 10) {
            blog(LOG_WARNING, "[iPhoneCam] Dropped invalid packet (%zu bytes)", data.size());
            invalidDatagramLogs_ += 1;
        }
        return;
    }

    const bool routine = packet->kind == PacketKind::FrameFragment || packet->kind == PacketKind::Audio ||
                         packet->kind == PacketKind::Ping || packet->kind == PacketKind::TimeSyncResponse;
    if (!routine || (packet->kind == PacketKind::FrameFragment && frameLogs_ < 5)) {
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
    case PacketKind::Control:
        break;
    case PacketKind::Audio:
        handleAudio(*packet);
        break;
    case PacketKind::TimeSyncResponse:
        handleTimeSyncResponse(*packet);
        break;
    case PacketKind::Ping:
    case PacketKind::TimeSyncRequest:
        break;
    }
}

void IPhoneCamSource::handleHello(const HelloPayload &hello)
{
    registerDiscoveredDevice(hello.deviceName);
    if (settings_.mode == ConnectionMode::Usb && !settings_.targetDevice.empty() &&
        hello.deviceName != settings_.targetDevice) {
        blog(LOG_INFO, "[iPhoneCam] Ignoring stream from '%s' because target is '%s'", hello.deviceName.c_str(),
             settings_.targetDevice.c_str());
        return;
    }
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
        if (!frame.isKeyFrame) {
            requestKeyFrame();
            return;
        }
        droppingUntilKeyFrame_ = false;
    }

    // frameId is the iPhone's per-connection send sequence, so a non-keyframe only decodes cleanly when it
    // directly follows the last frame queued for decode. Anything else means a frame was lost or dropped.
    const bool continuesChain = frame.frameId == lastQueuedFrameId_ + 1;
    bool needsKeyFrame = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!frame.isKeyFrame && !continuesChain && !stats_.waitingForKeyFrame) {
            if (frameGapLogs_ < 10) {
                blog(LOG_WARNING, "[iPhoneCam] Frame %llu does not follow frame %llu, waiting for keyframe",
                     static_cast<unsigned long long>(frame.frameId),
                     static_cast<unsigned long long>(lastQueuedFrameId_));
                frameGapLogs_ += 1;
            }
            stats_.waitingForKeyFrame = true;
        }
        if (stats_.waitingForKeyFrame && !frame.isKeyFrame) {
            if (waitKeyFrameLogs_ < 10) {
                blog(LOG_INFO, "[iPhoneCam] Completed non-keyframe %llu while waiting for keyframe",
                     static_cast<unsigned long long>(frame.frameId));
                waitKeyFrameLogs_ += 1;
            }
            needsKeyFrame = true;
        } else {
            stats_.waitingForKeyFrame = false;
            stats_.receivedFrames += 1;
            receivedFramesSinceStats_ += 1;
        }
    }
    if (needsKeyFrame) {
        markStatsDirty();
        requestKeyFrame();
        return;
    }
    lastQueuedFrameId_ = frame.frameId;

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
            requestKeyFrame();
            return;
        }
    }

    outputDecodedFrame(decoded);
    noteFrameLatency(frame.ptsNanos);
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
    {
        std::lock_guard<std::mutex> lock(timebaseMutex_);
        videoBaseObsTime_ = 0;
        videoBaseCameraPts_ = 0;
        lastVideoPts_ = 0;
        audioBaseObsTime_ = 0;
        audioBaseCameraPts_ = 0;
        lastAudioPts_ = 0;
    }
    dispatch_sync(decodeQueue_, ^{});
    std::lock_guard<std::mutex> decoderLock(decoderMutex_);
    decoder_->reset();
    pendingDecodeFrames_ = 0;
    lastQueuedFrameId_ = 0;
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
    requestKeyFrame();

    dispatch_async(decodeQueue_, ^{
      if (generation != decodeGeneration_.load())
          return;

      std::optional<FormatPayload> format;
      {
          std::lock_guard<std::mutex> lock(mutex_);
          format = lastFormat_;
      }
      std::string error;
      if (format) {
          std::lock_guard<std::mutex> decoderLock(decoderMutex_);
          decoder_->configure(*format, error);
      }
    });
    audioDecoder_->reset();
}

uint64_t IPhoneCamSource::getVideoObsTimestamp(uint64_t ptsNanos, int64_t offsetNs)
{
    std::lock_guard<std::mutex> lock(timebaseMutex_);
    const uint64_t nowObs = os_gettime_ns();

    const bool isFirst = (videoBaseObsTime_ == 0);
    const bool isRewind = (lastVideoPts_ > 0 && ptsNanos < lastVideoPts_);
    const bool isHugeGap = (lastVideoPts_ > 0 && (ptsNanos - lastVideoPts_) > 1000000000ULL);

    if (isFirst || isRewind || isHugeGap) {
        videoBaseObsTime_ = nowObs;
        videoBaseCameraPts_ = ptsNanos;
    }
    lastVideoPts_ = ptsNanos;

    const int64_t ptsOffset = int64_t(ptsNanos) - int64_t(videoBaseCameraPts_);
    int64_t computed = int64_t(videoBaseObsTime_) + ptsOffset + offsetNs;

    // Prevent frames from falling drastically behind or ahead of real-time (>500ms)
    if (computed < int64_t(nowObs) - 500000000LL || computed > int64_t(nowObs) + 500000000LL) {
        videoBaseObsTime_ = nowObs;
        videoBaseCameraPts_ = ptsNanos;
        computed = int64_t(nowObs) + offsetNs;
    }

    return uint64_t(std::max<int64_t>(0, computed));
}

uint64_t IPhoneCamSource::getAudioObsTimestamp(uint64_t ptsNanos, int64_t offsetNs)
{
    std::lock_guard<std::mutex> lock(timebaseMutex_);
    const uint64_t nowObs = os_gettime_ns();

    // If video has established a reference epoch, anchor audio to it for lip sync
    if (videoBaseObsTime_ > 0 && videoBaseCameraPts_ > 0) {
        const int64_t ptsOffset = int64_t(ptsNanos) - int64_t(videoBaseCameraPts_);
        const int64_t computed = int64_t(videoBaseObsTime_) + ptsOffset + offsetNs;
        lastAudioPts_ = ptsNanos;
        return uint64_t(std::max<int64_t>(0, computed));
    }

    const bool isFirst = (audioBaseObsTime_ == 0);
    const bool isRewind = (lastAudioPts_ > 0 && ptsNanos < lastAudioPts_);
    const bool isHugeGap = (lastAudioPts_ > 0 && (ptsNanos - lastAudioPts_) > 1000000000ULL);

    if (isFirst || isRewind || isHugeGap) {
        audioBaseObsTime_ = nowObs;
        audioBaseCameraPts_ = ptsNanos;
    }
    lastAudioPts_ = ptsNanos;

    const int64_t ptsOffset = int64_t(ptsNanos) - int64_t(audioBaseCameraPts_);
    const int64_t computed = int64_t(audioBaseObsTime_) + ptsOffset + offsetNs;
    return uint64_t(std::max<int64_t>(0, computed));
}

void IPhoneCamSource::handleAudio(const CameraPacket &packet)
{
    if (!settings_.audioEnabled)
        return;

    DecodedAudioFrame audioFrame;
    std::string error;
    if (!audioDecoder_->decode(packet.payload.data(), packet.payload.size(), packet.ptsNanos, audioFrame, error)) {
        if (audioErrorLogs_ < 10) {
            blog(LOG_WARNING, "[iPhoneCam] Audio decode failed (%zu bytes): %s", packet.payload.size(), error.c_str());
            audioErrorLogs_ += 1;
        }
        return;
    }

    outputDecodedAudio(audioFrame);
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

    const int64_t latencyNs = int64_t(settings_.latencyMs) * 1000000LL;
    obsFrame.timestamp = getVideoObsTimestamp(frame.ptsNanos, latencyNs);

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

void IPhoneCamSource::outputDecodedAudio(const DecodedAudioFrame &frame)
{
    if (frame.frames == 0 || frame.pcmData.empty())
        return;

    const int64_t totalOffsetNs = (int64_t(settings_.latencyMs) + int64_t(settings_.audioOffsetMs)) * 1000000LL;
    const uint64_t audioTimestamp = getAudioObsTimestamp(frame.ptsNanos, totalOffsetNs);

    obs_source_audio obsAudio = {};
    obsAudio.data[0] = reinterpret_cast<const uint8_t *>(frame.pcmData.data());
    obsAudio.frames = frame.frames;
    obsAudio.speakers = SPEAKERS_STEREO;
    obsAudio.format = AUDIO_FORMAT_FLOAT;
    obsAudio.samples_per_sec = frame.sampleRate;
    obsAudio.timestamp = audioTimestamp;

    obs_source_output_audio(source_, &obsAudio);
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
    obs_data_set_default_string(settings, "connection_mode", "usb");
    obs_data_set_default_string(settings, "host", "");
    obs_data_set_default_string(settings, "target_device", "");
    obs_data_set_default_int(settings, "latency_ms", 0);
    obs_data_set_default_bool(settings, "audio_enabled", true);
    obs_data_set_default_int(settings, "audio_offset_ms", 0);
}

static bool iphonecam_restart_clicked(obs_properties_t *, obs_property_t *, void *data)
{
    if (data)
        static_cast<IPhoneCamSource *>(data)->restart();
    return true;
}

static void iphonecam_fill_device_lists(obs_properties_t *props)
{
    if (obs_property_t *deviceList = obs_properties_get(props, "target_device")) {
        obs_property_list_clear(deviceList);
        obs_property_list_add_string(deviceList, "First iPhone on USB", "");
        for (const auto &dev : iphonecam::getDiscoveredDevices())
            obs_property_list_add_string(deviceList, dev.c_str(), dev.c_str());
    }
    // Picking a discovered name dials it by name, so the source keeps working when the iPhone's IP changes.
    if (obs_property_t *hostList = obs_properties_get(props, "host")) {
        obs_property_list_clear(hostList);
        for (const auto &name : iphonecam::getDiscoveredPhoneNames())
            obs_property_list_add_string(hostList, name.c_str(), name.c_str());
    }
}

static bool iphonecam_refresh_devices_clicked(obs_properties_t *props, obs_property_t *, void *)
{
    iphonecam_fill_device_lists(props);
    return true;
}

static bool iphonecam_connection_mode_changed(obs_properties_t *props, obs_property_t *, obs_data_t *settings)
{
    const char *mode = obs_data_get_string(settings, "connection_mode");
    const bool wifi = mode && std::strcmp(mode, "wifi") == 0;
    obs_property_set_visible(obs_properties_get(props, "host"), wifi);
    obs_property_set_visible(obs_properties_get(props, "wifi_help"), wifi);
    obs_property_set_visible(obs_properties_get(props, "target_device"), !wifi);
    obs_property_set_visible(obs_properties_get(props, "usb_help"), !wifi);
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

    obs_property_t *mode = obs_properties_add_list(props, "connection_mode", "Connection", OBS_COMBO_TYPE_LIST,
                                                   OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(mode, "USB cable", "usb");
    obs_property_list_add_string(mode, "Wi-Fi (IP address or name)", "wifi");
    obs_property_set_modified_callback(mode, iphonecam_connection_mode_changed);

    obs_properties_add_list(props, "host", "iPhone", OBS_COMBO_TYPE_EDITABLE, OBS_COMBO_FORMAT_STRING);
    obs_properties_add_text(props, "wifi_help",
                            "Type the IP address the iPhoneCam app shows, or pick the iPhone by name. "
                            "The phone must be on the same network as this Mac.",
                            OBS_TEXT_INFO);

    obs_properties_add_list(props, "target_device", "Target iPhone", OBS_COMBO_TYPE_EDITABLE,
                            OBS_COMBO_FORMAT_STRING);
    obs_properties_add_text(props, "usb_help",
                            "Connect the iPhone with a cable and open iPhoneCam. Pin a camera name to keep "
                            "several iPhones on fixed sources.",
                            OBS_TEXT_INFO);

    iphonecam_fill_device_lists(props);
    obs_properties_add_button(props, "refresh_devices", "Refresh iPhones", iphonecam_refresh_devices_clicked);

    obs_property_t *latency = obs_properties_add_list(props, "latency_ms", "Latency", OBS_COMBO_TYPE_LIST,
                                                      OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(latency, "Low 0 ms", 0);
    obs_property_list_add_int(latency, "Balanced 60 ms", 60);
    obs_property_list_add_int(latency, "Smooth 120 ms", 120);

    obs_properties_add_bool(props, "audio_enabled", "Enable Audio (Stereo)");
    obs_properties_add_int_slider(props, "audio_offset_ms", "Audio Sync Offset (ms)", -500, 500, 10);

    obs_properties_add_button(props, "restart_receiver", "Reconnect", iphonecam_restart_clicked);
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

// Program/preview changes reach the iPhone at once instead of on the next tick.
static void iphonecam_tally_changed(void *data)
{
    static_cast<IPhoneCamSource *>(data)->updateTally(false);
}

obs_source_info iphonecam_source_info = [] {
    obs_source_info info = {};
    info.id = "iphonecam_source";
    info.type = OBS_SOURCE_TYPE_INPUT;
    info.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO;
    info.get_name = iphonecam_get_name;
    info.create = iphonecam_create;
    info.destroy = iphonecam_destroy;
    info.get_width = iphonecam_get_width;
    info.get_height = iphonecam_get_height;
    info.get_defaults = iphonecam_defaults;
    info.get_properties = iphonecam_properties;
    info.update = iphonecam_update;
    info.video_tick = iphonecam_tick;
    info.activate = iphonecam_tally_changed;
    info.deactivate = iphonecam_tally_changed;
    info.show = iphonecam_tally_changed;
    info.hide = iphonecam_tally_changed;
    info.icon_type = OBS_ICON_TYPE_CAMERA;
    return info;
}();
