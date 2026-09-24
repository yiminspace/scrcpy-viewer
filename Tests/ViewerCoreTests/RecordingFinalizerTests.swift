import AVFoundation
import CoreGraphics
import XCTest
@testable import ViewerCore

final class RecordingFinalizerTests: XCTestCase {
    func testDifferentLayoutsBecomeOneVideoWithOnlyRightSideSpaceBeforeDisplayAppears() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await part(in: directory, name: "first", colors: [(1, 0, 0)],
                                   screenWidth: 120, screenHeight: 240, duration: 2)
        let second = try await part(in: directory, name: "second", colors: [(0, 0, 1), (0, 1, 0)],
                                    screenWidth: 160, screenHeight: 320, duration: 1.5)
        let output = directory.appendingPathComponent("complete.mp4")
        let saved = try await RecordingFinalizer.publish(parts: [first, second], to: output)
        XCTAssertEqual(saved, output)
        let asset = AVURLAsset(url: saved)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let size = try await video.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let frameRate = try await video.load(.nominalFrameRate)
        let descriptions = try await video.load(.formatDescriptions)
        XCTAssertEqual(videos.count, 1)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(size, CGSize(width: 240, height: 240))
        XCTAssertEqual(duration.seconds, 3.5, accuracy: 0.001)
        XCTAssertGreaterThan(frameRate, 0)
        XCTAssertTrue(frameRate <= 12.1, "Static held frames may use fewer samples than the 12 fps target")
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), kCMVideoCodecType_H264)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Check both sides of the actual part boundary, not just each file's first frame.
        for frameIndex in [1, 23, 24, 40] {
            let image = try await generator.image(at: CMTime(value: Int64(frameIndex), timescale: 12)).image
            let bytes = try pixels(image)
            for y in [0, image.height / 2, image.height - 1] {
                for x in [0, 59, 117, 122, 180, image.width - 1] {
                    let pixel = (y * image.width + x) * 4
                    let rgb = (Int(bytes[pixel]), Int(bytes[pixel + 1]), Int(bytes[pixel + 2]))
                    if frameIndex < 24 {
                        if x < 120 { assertColor(rgb, red: true) }
                        else { XCTAssertLessThan(max(rgb.0, rgb.1, rgb.2), 35) }
                    } else if x < 120 {
                        assertColor(rgb, blue: true)
                    } else {
                        assertColor(rgb, green: true)
                    }
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") })
    }

    func testEarlierWiderLayoutDeterminesCanvasEvenWhenLastPartIsNarrower() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wide = try await part(in: directory, name: "wide", colors: [(0, 1, 0), (0, 0, 1)],
                                  screenWidth: 120, screenHeight: 240, duration: 1)
        let narrow = try await part(in: directory, name: "narrow", colors: [(1, 0, 0)],
                                    screenWidth: 120, screenHeight: 240, duration: 1)
        let output = try await RecordingFinalizer.publish(parts: [wide, narrow],
            to: directory.appendingPathComponent("complete.mp4"))
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 240, height: 240))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 18, timescale: 12)).image
        let bytes = try pixels(frame)
        let right = (120 * frame.width + 180) * 4
        XCTAssertLessThan(max(bytes[right], bytes[right + 1], bytes[right + 2]), 35)
    }

    func testSinglePartIsPublishedWithoutReencodingOrRemovingSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await part(in: directory, name: "source", colors: [(1, 0, 0)],
                                    screenWidth: 120, screenHeight: 240, duration: 1.25)
        let output = directory.appendingPathComponent("existing.mp4")
        try Data("previous destination".utf8).write(to: output)
        let original = try Data(contentsOf: source)
        _ = try await RecordingFinalizer.publish(parts: [source], to: output)
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") })
    }

    func testInvalidPartDoesNotReplaceDestinationOrRemoveEarlierParts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await part(in: directory, name: "source", colors: [(1, 0, 0)],
                                    screenWidth: 120, screenHeight: 240, duration: 1)
        let sourceData = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("existing.mp4")
        let existing = Data("previous destination".utf8)
        try existing.write(to: output)
        let broken = directory.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: broken)
        do {
            _ = try await RecordingFinalizer.publish(parts: [source, broken], to: output)
            XCTFail("An invalid part must not publish a partial recording")
        } catch {
            XCTAssertEqual(try Data(contentsOf: output), existing)
            XCTAssertEqual(try Data(contentsOf: source), sourceData)
            XCTAssertEqual(try Data(contentsOf: broken), Data("not a video".utf8))
        }
        do {
            _ = try await RecordingFinalizer.publish(parts: [], to: output)
            XCTFail("An empty session must fail")
        } catch { XCTAssertEqual(try Data(contentsOf: output), existing) }
    }

    func testCancellationDoesNotReplaceDestinationOrDeleteParts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await part(in: directory, name: "source", colors: [(1, 0, 0)],
                                    screenWidth: 120, screenHeight: 240, duration: 1)
        let output = directory.appendingPathComponent("existing.mp4")
        let existing = Data("previous destination".utf8)
        try existing.write(to: output)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RecordingFinalizer.publish(parts: [source, source], to: output)
        }
        do { _ = try await task.value; XCTFail("Cancelled finalization must fail") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUndecodableSinglePartPreservesDestinationAndCleansTemporaryOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await part(in: directory, name: "source", colors: [(1, 0, 0)],
                                    screenWidth: 120, screenHeight: 240, duration: 1)
        var damaged = try Data(contentsOf: source)
        var offset = 0
        var replacedMedia = false
        while offset + 8 <= damaged.count {
            var size = damaged[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            var headerSize = 8
            if size == 1, offset + 16 <= damaged.count {
                size = damaged[(offset + 8)..<(offset + 16)].reduce(0) { ($0 << 8) | Int($1) }
                headerSize = 16
            } else if size == 0 { size = damaged.count - offset }
            guard size >= headerSize, offset + size <= damaged.count else { break }
            if String(data: damaged[(offset + 4)..<(offset + 8)], encoding: .ascii) == "mdat" {
                damaged.replaceSubrange((offset + headerSize)..<(offset + size),
                    with: repeatElement(UInt8(0), count: size - headerSize))
                replacedMedia = true
                break
            }
            offset += size
        }
        XCTAssertTrue(replacedMedia)
        try damaged.write(to: source)
        let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "The fixture preserves video metadata but damages encoded samples")
        let output = directory.appendingPathComponent("existing.mp4")
        let existing = Data("previous destination".utf8)
        try existing.write(to: output)
        do {
            _ = try await RecordingFinalizer.publish(parts: [source], to: output)
            XCTFail("Undecodable video must not replace a good recording")
        } catch {
            XCTAssertEqual(try Data(contentsOf: output), existing)
            XCTAssertEqual(try Data(contentsOf: source), damaged)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") })
        }
    }

    private func part(in directory: URL, name: String, colors: [(CGFloat, CGFloat, CGFloat)],
                      screenWidth: Int, screenHeight: Int, duration: TimeInterval) async throws -> URL {
        let screens = try colors.enumerated().map { index, color in
            let context = try XCTUnwrap(CGContext(data: nil, width: screenWidth, height: screenHeight,
                bitsPerComponent: 8, bytesPerRow: screenWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
            return RecordingScreen(id: "\(index)", title: "Synthetic display", image: try XCTUnwrap(context.makeImage()),
                sourceSize: CGSize(width: screenWidth, height: screenHeight), status: "Live", lastFrameAt: nil, isLive: true)
        }
        let recorder = try CanvasRecorder(outputURL: directory.appendingPathComponent("\(name).mp4"),
                                          configuration: .compact(for: screens))
        recorder.append(screens: screens, at: 0)
        return try await withCheckedThrowingContinuation { continuation in
            recorder.finish(at: duration) { continuation.resume(with: $0) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-finalizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func assertColor(_ rgb: (Int, Int, Int), red: Bool = false, green: Bool = false, blue: Bool = false) {
        XCTAssertGreaterThan(red ? rgb.0 : green ? rgb.1 : rgb.2, 180)
        XCTAssertLessThan(red ? rgb.1 : rgb.0, 80)
        XCTAssertLessThan(blue ? rgb.1 : rgb.2, 80)
    }
}
