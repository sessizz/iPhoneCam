#include "audio_decoder.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <util/base.h>

namespace iphonecam {
namespace {

// Standard ESDS magic cookie for 48000 Hz, 2 channels, AAC-LC
static const uint8_t kDefaultAacCookie[] = {
    0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x00, 0x00, 0x04, 0x80, 0x80, 0x80, 0x14, 0x40, 0x14, 0x00,
    0x18, 0x00, 0x00, 0x01, 0xf4, 0x00, 0x00, 0x01, 0xf4, 0x00, 0x05, 0x80, 0x80, 0x80, 0x02, 0x11,
    0x90, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02
};

struct DecoderInputContext {
    const uint8_t *data = nullptr;
    UInt32 byteLength = 0;
    bool consumed = false;
    AudioStreamPacketDescription packetDesc = {};
};

static OSStatus audioDecoderInputProc(AudioConverterRef inAudioConverter,
                                      UInt32 *ioNumberDataPackets,
                                      AudioBufferList *ioData,
                                      AudioStreamPacketDescription **outDataPacketDescription,
                                      void *inUserData)
{
    auto *ctx = static_cast<DecoderInputContext *>(inUserData);
    if (!ctx || ctx->consumed || ctx->byteLength == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ctx->consumed = true;
    *ioNumberDataPackets = 1;

    ioData->mBuffers[0].mNumberChannels = 2;
    ioData->mBuffers[0].mDataByteSize = ctx->byteLength;
    ioData->mBuffers[0].mData = const_cast<uint8_t *>(ctx->data);

    ctx->packetDesc.mStartOffset = 0;
    ctx->packetDesc.mVariableFramesInPacket = 0;
    ctx->packetDesc.mDataByteSize = ctx->byteLength;
    if (outDataPacketDescription) {
        *outDataPacketDescription = &ctx->packetDesc;
    }
    return noErr;
}

} // namespace

struct AudioDecoder::Impl {
    AudioConverterRef converter = nullptr;
    uint32_t sampleRate = 48000;
    uint32_t channels = 2;
    bool isConfigured = false;

    ~Impl() { reset(); }

    void reset()
    {
        if (converter) {
            AudioConverterDispose(converter);
            converter = nullptr;
        }
        isConfigured = false;
    }

    bool ensureConverter(const std::vector<uint8_t> &cookie, std::string &error)
    {
        if (converter && isConfigured)
            return true;

        reset();

        AudioStreamBasicDescription aacDesc = {};
        aacDesc.mFormatID = kAudioFormatMPEG4AAC;
        aacDesc.mSampleRate = static_cast<Float64>(sampleRate);
        aacDesc.mChannelsPerFrame = channels;
        aacDesc.mFramesPerPacket = 1024;

        AudioStreamBasicDescription pcmDesc = {};
        pcmDesc.mFormatID = kAudioFormatLinearPCM;
        pcmDesc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        pcmDesc.mSampleRate = static_cast<Float64>(sampleRate);
        pcmDesc.mChannelsPerFrame = channels;
        pcmDesc.mBitsPerChannel = 32;
        pcmDesc.mBytesPerFrame = channels * sizeof(float);
        pcmDesc.mBytesPerPacket = pcmDesc.mBytesPerFrame;
        pcmDesc.mFramesPerPacket = 1;

        OSStatus status = AudioConverterNew(&aacDesc, &pcmDesc, &converter);
        if (status != noErr) {
            error = "AudioConverterNew failed: " + std::to_string(status);
            return false;
        }

        const uint8_t *cookiePtr = cookie.empty() ? kDefaultAacCookie : cookie.data();
        const size_t cookieSize = cookie.empty() ? sizeof(kDefaultAacCookie) : cookie.size();

        status = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                           static_cast<UInt32>(cookieSize), cookiePtr);
        if (status != noErr) {
            blog(LOG_WARNING, "[iPhoneCam] Failed to set decompression magic cookie (%d), will try decoding anyway",
                 static_cast<int>(status));
        }

        isConfigured = true;
        return true;
    }
};

AudioDecoder::AudioDecoder() : impl_(new Impl()) {}

AudioDecoder::~AudioDecoder()
{
    delete impl_;
}

bool AudioDecoder::configure(uint32_t sampleRate, uint32_t channels, const std::vector<uint8_t> &cookie, std::string &error)
{
    impl_->sampleRate = sampleRate;
    impl_->channels = channels;
    return impl_->ensureConverter(cookie, error);
}

bool AudioDecoder::decode(const uint8_t *data, size_t size, uint64_t ptsNanos, DecodedAudioFrame &outFrame, std::string &error)
{
    if (!data || size == 0) {
        error = "Empty audio payload";
        return false;
    }

    if (!impl_->ensureConverter({}, error)) {
        return false;
    }

    // Typical AAC frame has 1024 sample frames (stereo = 2048 float values)
    outFrame.pcmData.resize(1024 * impl_->channels);

    AudioBufferList outBufferList = {};
    outBufferList.mNumberBuffers = 1;
    outBufferList.mBuffers[0].mNumberChannels = impl_->channels;
    outBufferList.mBuffers[0].mDataByteSize = static_cast<UInt32>(outFrame.pcmData.size() * sizeof(float));
    outBufferList.mBuffers[0].mData = outFrame.pcmData.data();

    DecoderInputContext ctx = {data, static_cast<UInt32>(size), false};
    UInt32 ioOutputDataPacketFrames = 1024;

    OSStatus status = AudioConverterFillComplexBuffer(impl_->converter, audioDecoderInputProc, &ctx,
                                                      &ioOutputDataPacketFrames, &outBufferList, nullptr);
    if (status != noErr && ioOutputDataPacketFrames == 0) {
        error = "AudioConverterFillComplexBuffer failed: " + std::to_string(status);
        return false;
    }

    outFrame.frames = ioOutputDataPacketFrames;
    outFrame.sampleRate = impl_->sampleRate;
    outFrame.channels = impl_->channels;
    outFrame.ptsNanos = ptsNanos;
    outFrame.pcmData.resize(ioOutputDataPacketFrames * impl_->channels);

    return true;
}

void AudioDecoder::reset()
{
    impl_->reset();
}

} // namespace iphonecam
