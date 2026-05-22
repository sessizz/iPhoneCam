import AVFoundation
import Foundation
import VideoToolbox

struct H264Format: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let sps: Data
    let pps: Data

    var payload: FormatPayload {
        FormatPayload(
            codec: CameraProtocol.codecH264AVCC,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            sps: sps,
            pps: pps
        )
    }
}

struct EncodedH264Sample {
    let frameId: UInt64
    let ptsNanos: UInt64
    let isKeyFrame: Bool
    let data: Data
    let format: H264Format?
}

final class H264Encoder {
    var onFormat: ((H264Format) -> Void)?
    var onSample: ((EncodedH264Sample) -> Void)?

    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int
    private var compressionSession: VTCompressionSession?
    private var frameId: UInt64 = 0
    private var currentFormat: H264Format?

    init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        createSession()
    }

    deinit {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let compressionSession else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameId &+= 1
        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: Int(frameId)),
            infoFlagsOut: &flags
        )
    }

    private func createSession() {
        let callback: VTCompressionOutputCallback = { refcon, frameRefcon, status, _, sampleBuffer in
            guard
                status == noErr,
                let refcon,
                let sampleBuffer,
                CMSampleBufferDataIsReady(sampleBuffer)
            else {
                return
            }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
            let frameId = UInt64(UInt(bitPattern: frameRefcon))
            encoder.handleEncodedSample(sampleBuffer, frameId: frameId)
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return
        }
        compressionSession = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer, frameId: UInt64) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else {
            return
        }

        let data = Data(bytes: dataPointer, count: length)
        let extractedFormat = extractFormat(from: sampleBuffer)
        var changedFormat: H264Format?
        if let extractedFormat, extractedFormat != currentFormat {
            currentFormat = extractedFormat
            changedFormat = extractedFormat
            onFormat?(extractedFormat)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNanos = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value))
        let sample = EncodedH264Sample(
            frameId: frameId,
            ptsNanos: ptsNanos,
            isKeyFrame: isKeyFrame(sampleBuffer),
            data: data,
            format: changedFormat
        )
        onSample?(sample)
    }

    private func extractFormat(from sampleBuffer: CMSampleBuffer) -> H264Format? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        ) == noErr, let spsPointer else {
            return nil
        }

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        ) == noErr, let ppsPointer else {
            return nil
        }

        return H264Format(
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0,
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary?.self)
        else {
            return true
        }
        let notSync = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        return notSync == nil
    }
}
