import AVFoundation
import AudioToolbox
import Foundation

public struct EncodedAudioSample: Sendable {
    public let ptsNanos: UInt64
    public let data: Data

    public init(ptsNanos: UInt64, data: Data) {
        self.ptsNanos = ptsNanos
        self.data = data
    }
}

public enum AudioProfile: String, CaseIterable, Identifiable, Sendable {
    case studio = "Studio / Vocal"
    case natural = "Natural Stereo"
    case wide = "Wide Dynamic"

    public var id: String { rawValue }

    public var avAudioSessionMode: AVAudioSession.Mode {
        switch self {
        case .studio:
            return .videoRecording
        case .natural:
            return .videoRecording
        case .wide:
            return .measurement
        }
    }

    public var softwareGainMultiplier: Float {
        switch self {
        case .studio:
            return 1.68 // +4.5 dB broadcast presence
        case .natural:
            return 1.00
        case .wide:
            return 1.00
        }
    }

    public var shortDescription: String {
        switch self {
        case .studio:
            return "Vocal boost & clarity with studio presence"
        case .natural:
            return "Balanced natural stereo ambience"
        case .wide:
            return "Full spectrum music & sport"
        }
    }
}

public final class AudioEncoder: @unchecked Sendable {
    public var onSample: ((EncodedAudioSample) -> Void)?
    public var onLevelUpdate: ((Float) -> Void)?
    public var isMuted: Bool = false

    private var converter: AudioConverterRef?
    private var inputFormatDescription: CMAudioFormatDescription?
    private let targetSampleRate: Float64 = 48000.0
    private let targetChannels: UInt32 = 2
    private let targetBitrate: UInt32 = 192000

    private var aacBuffer = [UInt8](repeating: 0, count: 2048)
    private var pcmBuffer = [Int16]()
    private var currentPtsNanos: UInt64 = 0
    private var hasValidPts = false
    private var activeProfile: AudioProfile = .studio
    private var smoothedMeterLevel: Float = 0.0

    public init() {
        pcmBuffer.reserveCapacity(8192)
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    public func setProfile(_ profile: AudioProfile) {
        activeProfile = profile
    }

    public func reset() {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
        inputFormatDescription = nil
        pcmBuffer.removeAll(keepingCapacity: true)
        hasValidPts = false
        smoothedMeterLevel = 0.0
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let inDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        if converter == nil || formatDesc != inputFormatDescription {
            setupConverter(inDesc: inDesc, formatDesc: formatDesc)
        }

        guard let converter else { return }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let ablSize = MemoryLayout<AudioBufferList>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let samplePtsNanos = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value))

        let drift = abs(Int64(currentPtsNanos) - Int64(samplePtsNanos))
        if !hasValidPts || pcmBuffer.isEmpty || drift > 40_000_000 {
            currentPtsNanos = samplePtsNanos
            hasValidPts = true
        }

        let gain = activeProfile.softwareGainMultiplier
        var peakSample: Float = 0.0

        let numBuffers = Int(audioBufferList.mNumberBuffers)
        if numBuffers == 1, let mData = audioBufferList.mBuffers.mData {
            let byteSize = Int(audioBufferList.mBuffers.mDataByteSize)
            if inDesc.mBitsPerChannel == 16 {
                let sampleCount = byteSize / MemoryLayout<Int16>.size
                let inPtr = mData.assumingMemoryBound(to: Int16.self)
                let channelMultiplier = (inDesc.mChannelsPerFrame == 1) ? 2 : 1
                pcmBuffer.reserveCapacity(pcmBuffer.count + sampleCount * channelMultiplier)

                for i in 0..<sampleCount {
                    let s = inPtr[i]
                    let scaled = Float(s) * gain
                    let limited = softLimit(scaled)
                    let intVal = Int16(clamping: Int(limited))
                    let absF = abs(limited) / 32768.0
                    if absF > peakSample { peakSample = absF }

                    pcmBuffer.append(intVal)
                    if inDesc.mChannelsPerFrame == 1 {
                        pcmBuffer.append(intVal)
                    }
                }
            } else if inDesc.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let sampleCount = byteSize / MemoryLayout<Float>.size
                let inPtr = mData.assumingMemoryBound(to: Float.self)
                let channelMultiplier = (inDesc.mChannelsPerFrame == 1) ? 2 : 1
                pcmBuffer.reserveCapacity(pcmBuffer.count + sampleCount * channelMultiplier)

                for i in 0..<sampleCount {
                    let f = inPtr[i] * 32768.0 * gain
                    let limited = softLimit(f)
                    let intVal = Int16(clamping: Int(limited))
                    let absF = abs(limited) / 32768.0
                    if absF > peakSample { peakSample = absF }

                    pcmBuffer.append(intVal)
                    if inDesc.mChannelsPerFrame == 1 {
                        pcmBuffer.append(intVal)
                    }
                }
            }
        }

        updateVUMeter(peak: peakSample)

        let samplesPerPacket = 2048

        if pcmBuffer.count > 16384 {
            pcmBuffer.removeFirst(pcmBuffer.count - 8192)
            currentPtsNanos = samplePtsNanos
        }

        while pcmBuffer.count >= samplesPerPacket {
            var ioOutputPackets: UInt32 = 1
            var outBufferList = AudioBufferList()
            outBufferList.mNumberBuffers = 1
            outBufferList.mBuffers.mNumberChannels = targetChannels
            outBufferList.mBuffers.mDataByteSize = UInt32(aacBuffer.count)

            let packetPts = currentPtsNanos
            var bytesConsumed = 0

            let success: Bool = aacBuffer.withUnsafeMutableBytes { outBytes in
                outBufferList.mBuffers.mData = outBytes.baseAddress

                var context = InputContext(
                    dataPointer: pcmBuffer.withUnsafeBufferPointer { $0.baseAddress! },
                    bytesRemaining: UInt32(pcmBuffer.count * MemoryLayout<Int16>.size),
                    bytesPerFrame: targetChannels * UInt32(MemoryLayout<Int16>.size)
                )

                var packetDesc = AudioStreamPacketDescription()
                let convStatus = AudioConverterFillComplexBuffer(
                    converter,
                    audioEncoderDataProc,
                    &context,
                    &ioOutputPackets,
                    &outBufferList,
                    &packetDesc
                )

                bytesConsumed = (pcmBuffer.count * MemoryLayout<Int16>.size) - Int(context.bytesRemaining)

                if (convStatus == noErr || convStatus == 1) && ioOutputPackets > 0 {
                    let aacSize = Int(outBufferList.mBuffers.mDataByteSize)
                    if aacSize > 0, let baseAddress = outBytes.baseAddress {
                        let aacData = Data(bytes: baseAddress, count: aacSize)
                        if !isMuted {
                            onSample?(EncodedAudioSample(ptsNanos: packetPts, data: aacData))
                        }
                        return true
                    }
                }
                return false
            }

            let samplesConsumed = bytesConsumed / MemoryLayout<Int16>.size
            if samplesConsumed > 0 {
                pcmBuffer.removeFirst(min(samplesConsumed, pcmBuffer.count))
            } else {
                break
            }

            if success {
                currentPtsNanos += 21_333_333
            } else {
                break
            }
        }

        if pcmBuffer.isEmpty {
            hasValidPts = false
        }
    }

    private func softLimit(_ val: Float) -> Float {
        let threshold: Float = 28000.0
        let maxVal: Float = 32767.0
        if val > threshold {
            let over = val - threshold
            let room = maxVal - threshold
            return threshold + room * tanh(over / room)
        } else if val < -threshold {
            let over = -val - threshold
            let room = maxVal - threshold
            return -(threshold + room * tanh(over / room))
        }
        return val
    }

    private func updateVUMeter(peak: Float) {
        let clampedPeak = max(peak, 0.00001)
        let dB = 20.0 * log10(clampedPeak)
        let minDB: Float = -50.0
        let rawNormalized = max(0.0, min(1.0, (dB - minDB) / (-minDB)))

        if rawNormalized >= smoothedMeterLevel {
            smoothedMeterLevel = rawNormalized
        } else {
            smoothedMeterLevel = max(rawNormalized, smoothedMeterLevel * 0.88)
        }

        let level = smoothedMeterLevel
        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(level)
        }
    }

    private func setupConverter(inDesc: AudioStreamBasicDescription, formatDesc: CMAudioFormatDescription) {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }

        var inDescCopy = AudioStreamBasicDescription()
        inDescCopy.mFormatID = kAudioFormatLinearPCM
        inDescCopy.mSampleRate = targetSampleRate
        inDescCopy.mChannelsPerFrame = targetChannels
        inDescCopy.mBitsPerChannel = 16
        inDescCopy.mBytesPerFrame = targetChannels * 2
        inDescCopy.mBytesPerPacket = inDescCopy.mBytesPerFrame
        inDescCopy.mFramesPerPacket = 1
        inDescCopy.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

        var outDesc = AudioStreamBasicDescription()
        outDesc.mFormatID = kAudioFormatMPEG4AAC
        outDesc.mSampleRate = targetSampleRate
        outDesc.mChannelsPerFrame = targetChannels
        outDesc.mFramesPerPacket = 1024

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inDescCopy, &outDesc, &newConverter)
        guard status == noErr, let newConverter else {
            return
        }

        var bitrate = targetBitrate
        AudioConverterSetProperty(newConverter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)

        self.converter = newConverter
        self.inputFormatDescription = formatDesc
    }
}

private struct InputContext {
    var dataPointer: UnsafePointer<Int16>
    var bytesRemaining: UInt32
    let bytesPerFrame: UInt32
}

private func audioEncoderDataProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }
    let ctx = inUserData.assumingMemoryBound(to: InputContext.self)
    if ctx.pointee.bytesRemaining == 0 {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    let bytesNeeded = ioNumberDataPackets.pointee * ctx.pointee.bytesPerFrame
    let bytesToProvide = min(bytesNeeded, ctx.pointee.bytesRemaining)
    let framesToProvide = bytesToProvide / ctx.pointee.bytesPerFrame

    ioNumberDataPackets.pointee = framesToProvide

    ioData.pointee.mBuffers.mDataByteSize = bytesToProvide
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.pointee.dataPointer)

    let samplesAdvanced = Int(bytesToProvide) / MemoryLayout<Int16>.size
    ctx.pointee.dataPointer = ctx.pointee.dataPointer.advanced(by: samplesAdvanced)
    ctx.pointee.bytesRemaining -= bytesToProvide

    return noErr
}
