import AVFoundation
import Foundation

final class H264SampleBuilder {
    private let formatDescription: CMVideoFormatDescription

    init(format: FormatPayload) throws {
        var description: CMVideoFormatDescription?
        let status = format.sps.withUnsafeBytes { spsBytes in
            format.pps.withUnsafeBytes { ppsBytes in
                let parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let parameterSetSizes = [format.sps.count, format.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw H264SampleBuilderError.invalidFormat(status)
        }
        self.formatDescription = description
    }

    func makeSampleBuffer(from frame: EncodedVideoFrame) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else {
            throw H264SampleBuilderError.blockBuffer(blockStatus)
        }

        let replaceStatus = frame.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.data.count
            )
        }
        guard replaceStatus == noErr else {
            throw H264SampleBuilderError.blockBuffer(replaceStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.ptsNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.data.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw H264SampleBuilderError.sampleBuffer(sampleStatus)
        }
        markForImmediateDisplay(sampleBuffer)
        return sampleBuffer
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else {
            return
        }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

enum H264SampleBuilderError: LocalizedError {
    case invalidFormat(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let status):
            return "Invalid H.264 format (\(status))."
        case .blockBuffer(let status):
            return "Could not create H.264 block buffer (\(status))."
        case .sampleBuffer(let status):
            return "Could not create H.264 sample buffer (\(status))."
        }
    }
}
