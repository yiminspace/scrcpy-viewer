import AVFoundation
import CoreGraphics
import XCTest
@testable import ViewerCore

final class H264DecoderTests: XCTestCase {
    func testRepeatedSyntheticFramesFinishBeforeNextPacketIsSubmitted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decoder-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 256,
            bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
        let screen = RecordingScreen(id: "main", title: "Synthetic", image: try XCTUnwrap(context.makeImage()),
            sourceSize: CGSize(width: 128, height: 256), status: "Live", lastFrameAt: nil, isLive: true)
        let url = directory.appendingPathComponent("source.mp4")
        let recorder = try CanvasRecorder(outputURL: url, configuration: .compact(for: [screen]))
        recorder.append(screens: [screen], at: 0)
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            recorder.finish(at: 1) { continuation.resume(with: $0) }
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        let reader = try AVAssetReader(asset: asset)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        // AVAssetReader may emit a timing marker before the first media sample.
        var encodedSample: CMSampleBuffer?
        while let candidate = output.copyNextSampleBuffer() {
            if CMSampleBufferGetDataBuffer(candidate) != nil,
               CMSampleBufferGetFormatDescription(candidate) != nil {
                encodedSample = candidate
                break
            }
        }
        let sample = try XCTUnwrap(encodedSample)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        var packet = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), noErr)
            packet.append(contentsOf: [0, 0, 0, 1])
            packet.append(UnsafeBufferPointer(start: try XCTUnwrap(pointer), count: size))
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        XCTAssertEqual(status, noErr)
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, length <= bytes.count - offset else {
                XCTFail("Invalid synthetic encoder output"); return
            }
            packet.append(contentsOf: [0, 0, 0, 1])
            packet.append(bytes[offset..<(offset + length)])
            offset += length
        }
        let countLock = NSLock()
        var decoded = 0
        let decoder = H264Decoder { image in
            XCTAssertEqual(image.width, 128)
            XCTAssertEqual(image.height, 256)
            countLock.withLock { decoded += 1 }
        }
        defer { decoder.close() }
        for index in 0..<300 {
            try autoreleasepool {
                try decoder.decode(packet, header: .init(presentationTime: UInt64(index * 16_667),
                    isConfiguration: false, isKeyFrame: true, length: packet.count))
            }
            let completed = countLock.withLock { decoded }
            XCTAssertEqual(completed, index + 1, "Decode must apply backpressure before accepting another packet")
        }
    }
}
