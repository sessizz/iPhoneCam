#include "video_decoder.hpp"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <utility>

namespace iphonecam {
namespace {

bool retainPixelBuffer(CVImageBufferRef imageBuffer, DecodedFrame &decoded)
{
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
    if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2)
        return false;

    decoded.reset();
    CFRetain(pixelBuffer);
    decoded.pixelBuffer = pixelBuffer;
    decoded.width = int(CVPixelBufferGetWidth(pixelBuffer));
    decoded.height = int(CVPixelBufferGetHeight(pixelBuffer));
    decoded.yStride = uint32_t(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0));
    decoded.uvStride = uint32_t(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1));
    decoded.fullRange = true;
    return true;
}

struct DecodeRequest {
    DecodedFrame *decoded = nullptr;
    OSStatus status = noErr;
    bool produced = false;
};

void decompressionCallback(void *, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags,
                           CVImageBufferRef imageBuffer, CMTime, CMTime)
{
    auto *request = static_cast<DecodeRequest *>(sourceFrameRefCon);
    if (!request)
        return;
    request->status = status;
    if (status == noErr && imageBuffer && request->decoded)
        request->produced = retainPixelBuffer(imageBuffer, *request->decoded);
}

std::string statusError(const char *context, OSStatus status)
{
    return std::string(context) + " failed (" + std::to_string(status) + ")";
}

} // namespace

DecodedFrame::~DecodedFrame()
{
    reset();
}

DecodedFrame::DecodedFrame(DecodedFrame &&other) noexcept
{
    *this = std::move(other);
}

DecodedFrame &DecodedFrame::operator=(DecodedFrame &&other) noexcept
{
    if (this == &other)
        return *this;

    reset();
    width = other.width;
    height = other.height;
    ptsNanos = other.ptsNanos;
    yStride = other.yStride;
    uvStride = other.uvStride;
    fullRange = other.fullRange;
    pixelBuffer = other.pixelBuffer;

    other.width = 0;
    other.height = 0;
    other.ptsNanos = 0;
    other.yStride = 0;
    other.uvStride = 0;
    other.fullRange = true;
    other.pixelBuffer = nullptr;
    return *this;
}

void DecodedFrame::reset()
{
    if (pixelBuffer) {
        CFRelease(pixelBuffer);
        pixelBuffer = nullptr;
    }
    width = 0;
    height = 0;
    ptsNanos = 0;
    yStride = 0;
    uvStride = 0;
    fullRange = true;
}

struct VideoDecoder::Impl {
    CMVideoFormatDescriptionRef formatDescription = nullptr;
    VTDecompressionSessionRef session = nullptr;
    int width = 0;
    int height = 0;

    ~Impl() { reset(); }

    void reset()
    {
        if (session) {
            VTDecompressionSessionInvalidate(session);
            CFRelease(session);
            session = nullptr;
        }
        if (formatDescription) {
            CFRelease(formatDescription);
            formatDescription = nullptr;
        }
        width = 0;
        height = 0;
    }
};

VideoDecoder::VideoDecoder() : impl_(new Impl()) {}

VideoDecoder::~VideoDecoder()
{
    delete impl_;
}

void VideoDecoder::reset()
{
    impl_->reset();
}

bool VideoDecoder::configure(const FormatPayload &format, std::string &error)
{
    impl_->reset();
    if (format.sps.empty() || format.pps.empty()) {
        error = "Missing H.264 SPS/PPS";
        return false;
    }

    const uint8_t *parameterSetPointers[] = {format.sps.data(), format.pps.data()};
    const size_t parameterSetSizes[] = {format.sps.size(), format.pps.size()};
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &impl_->formatDescription);
    if (status != noErr || !impl_->formatDescription) {
        error = statusError("CMVideoFormatDescriptionCreateFromH264ParameterSets", status);
        return false;
    }

    VTDecompressionOutputCallbackRecord callback = {};
    callback.decompressionOutputCallback = decompressionCallback;

    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };

    status = VTDecompressionSessionCreate(kCFAllocatorDefault, impl_->formatDescription, nullptr,
                                          (__bridge CFDictionaryRef)attributes, &callback, &impl_->session);
    if (status != noErr || !impl_->session) {
        error = statusError("VTDecompressionSessionCreate", status);
        impl_->reset();
        return false;
    }

    CFBooleanRef realtime = kCFBooleanTrue;
    VTSessionSetProperty(impl_->session, kVTDecompressionPropertyKey_RealTime, realtime);
    impl_->width = format.width;
    impl_->height = format.height;
    return true;
}

bool VideoDecoder::decode(const EncodedVideoFrame &frame, DecodedFrame &decoded, std::string &error)
{
    if (!impl_->session || !impl_->formatDescription) {
        error = "Decoder is not configured";
        return false;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, frame.data.size(), nullptr,
                                                         nullptr, 0, frame.data.size(), 0, &blockBuffer);
    if (status != noErr || !blockBuffer) {
        error = statusError("CMBlockBufferCreateWithMemoryBlock", status);
        return false;
    }

    status = CMBlockBufferReplaceDataBytes(frame.data.data(), blockBuffer, 0, frame.data.size());
    if (status != noErr) {
        CFRelease(blockBuffer);
        error = statusError("CMBlockBufferReplaceDataBytes", status);
        return false;
    }

    CMSampleTimingInfo timing = {};
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(int64_t(frame.ptsNanos), 1000000000);
    timing.decodeTimeStamp = kCMTimeInvalid;

    size_t sampleSize = frame.data.size();
    CMSampleBufferRef sampleBuffer = nullptr;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, impl_->formatDescription, 1, 1, &timing, 1,
                                       &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || !sampleBuffer) {
        error = statusError("CMSampleBufferCreateReady", status);
        return false;
    }

    DecodeRequest request;
    request.decoded = &decoded;
    decoded.ptsNanos = frame.ptsNanos;
    status = VTDecompressionSessionDecodeFrame(impl_->session, sampleBuffer, kVTDecodeFrame_1xRealTimePlayback, &request,
                                               nullptr);
    CFRelease(sampleBuffer);

    if (status != noErr) {
        error = statusError("VTDecompressionSessionDecodeFrame", status);
        return false;
    }
    if (request.status != noErr) {
        error = statusError("VideoToolbox decode callback", request.status);
        return false;
    }
    if (!request.produced) {
        error = "VideoToolbox did not produce a pixel buffer";
        return false;
    }
    return true;
}

} // namespace iphonecam
