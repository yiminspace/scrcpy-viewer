import Foundation
import CoreMedia
import CoreImage
import VideoToolbox

/// One decoder belongs to one stream worker; VideoToolbox delivers frames on its own queue.
final class H264Decoder {
    private let onFrame: (CGImage) -> Void
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKeyFrame = true
    private let errorLock = NSLock()
    private var outputError: OSStatus?

    init(onFrame: @escaping (CGImage) -> Void) { self.onFrame = onFrame }
    deinit { close() }

    func decode(_ payload: Data, header: ScrcpyProtocol.PacketHeader) throws {
        errorLock.lock(); let pendingError = outputError; errorLock.unlock()
        if let pendingError { throw failure("视频解码失败", pendingError) }
        let units = try ScrcpyProtocol.nalUnits(payload)
        var nextSPS = sps, nextPPS = pps
        for unit in units {
            switch unit[unit.startIndex] & 0x1f {
            case 7: nextSPS = unit
            case 8: nextPPS = unit
            default: break
            }
        }
        if nextSPS != sps || nextPPS != pps {
            close()
            sps = nextSPS; pps = nextPPS
            if let sps, let pps { try configure(sps: sps, pps: pps) }
        }
        if header.isConfiguration { return }
        guard let session, let format else { return }
        let isKey = header.isKeyFrame || units.contains { $0[$0.startIndex] & 0x1f == 5 }
        if waitingForKeyFrame && !isKey { return }
        waitingForKeyFrame = false
        let frameUnits = units.filter { ![7, 8].contains($0[$0.startIndex] & 0x1f) }
        guard !frameUnits.isEmpty else { return }
        let data = ScrcpyProtocol.lengthPrefixed(frameUnits)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw failure("创建视频缓冲区失败", status) }
        status = data.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw failure("复制视频缓冲区失败", status) }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(header.presentationTime), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw failure("创建视频帧失败", status) }
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { throw failure("提交视频解码失败", status) }
    }

    func close() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil; format = nil; waitingForKeyFrame = true
    }

    private func configure(sps: Data, pps: Data) throws {
        var newFormat: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes, nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { throw failure("解析 H.264 参数失败", status) }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, buffer, _, _ in
            guard let context else { return }
            let decoder = Unmanaged<H264Decoder>.fromOpaque(context).takeUnretainedValue()
            if status != noErr {
                decoder.errorLock.lock(); decoder.outputError = status; decoder.errorLock.unlock()
                return
            }
            guard let buffer else { return }
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: buffer)
                if let frame = decoder.imageContext.createCGImage(image, from: image.extent) {
                    decoder.onFrame(frame)
                }
            }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var newSession: VTDecompressionSession?
        let creation = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
            formatDescription: newFormat, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &newSession)
        guard creation == noErr, let newSession else { throw failure("创建视频解码器失败", creation) }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        format = newFormat; session = newSession
    }

    private func failure(_ message: String, _ status: OSStatus) -> Error {
        ScrcpyProtocolError.malformed("\(message)（\(status)）")
    }
}
