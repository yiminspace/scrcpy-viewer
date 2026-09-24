import AVFoundation
import CoreGraphics
import CoreImage
import XCTest
@testable import ViewerCore

final class CanvasRecordingTests: XCTestCase {
    func testFinishingAtSegmentBoundaryDoesNotAddAnotherFrameDuration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = [screen("main", try image(red: 1, green: 0, blue: 0))]
        let recorder = try CanvasRecorder(outputURL: directory.appendingPathComponent("boundary.mp4"),
                                          configuration: .compact(for: frames))
        recorder.append(screens: frames, at: 0)
        recorder.append(screens: frames, at: 1.95)
        let url = try await finish(recorder, at: 2)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.001)
    }

    func testTightMP4ContainsAllDisplaysWithoutMarginsAndPreservesHeldFrames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("all-displays.mp4")
        let red = try image(red: 1, green: 0, blue: 0)
        let green = try image(red: 0, green: 1, blue: 0)
        let blue = try image(red: 0, green: 0, blue: 1, width: 160, height: 100)
        let screens = [screen("main", red), screen("second", green), screen("third", blue)]
        let configuration = CanvasRecordingConfiguration.compact(for: screens)
        let recorder = try CanvasRecorder(outputURL: output, configuration: configuration)
        recorder.append(screens: screens, at: 0)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Publish only finalized MP4s")
        recorder.append(screens: [screen("main", red), screen("second", green, live: false),
                                  screen("third", blue)], at: 1)
        try await Task.sleep(for: .milliseconds(250))
        let saved = try await finish(recorder, at: 2)
        let asset = AVURLAsset(url: saved)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(audio.isEmpty)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(size, CGSize(width: 260, height: 100))
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [0.2, 1.4] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let counts = try colors(frame)
            XCTAssertGreaterThan(counts.red, 4_800)
            XCTAssertGreaterThan(counts.green, 2_000, "Retain removed display's last frame")
            XCTAssertGreaterThan(counts.blue, 15_800)
            XCTAssertEqual(Double(counts.blue) / Double(counts.red), 3.2, accuracy: 0.08)
            let bytes = try pixels(frame)
            for x in 0..<frame.width {
                for y in [0, frame.height - 1] where time < 1 || x < 50 || x >= 100 {
                    let i = (y * frame.width + x) * 4
                    XCTAssertGreaterThan(max(bytes[i], bytes[i + 1], bytes[i + 2]), 80,
                                         "No surplus pixels at top or bottom")
                }
            }
        }
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(filenames.contains { $0.contains("partial") })
    }

    func testScreenshotTightlyJoinsAllImagesAtNativeOrSmallerSize() throws {
        let red = try image(red: 1, green: 0, blue: 0)
        let green = try image(red: 0, green: 1, blue: 0)
        let blue = try image(red: 0, green: 0, blue: 1, width: 160, height: 100)
        let screens = [screen("main", red), screen("second", green), screen("third", blue)]
        XCTAssertEqual(CanvasComposition.size(for: [screens[0]]), CGSize(width: 120, height: 240))
        XCTAssertEqual(CanvasComposition.size(for: screens), CGSize(width: 260, height: 100))
        let bounded = CanvasComposition.size(for: screens, maximumHeight: 60, maximumWidth: 100)
        XCTAssertLessThanOrEqual(bounded.width, 100)
        XCTAssertLessThanOrEqual(bounded.height, 60)
        XCTAssertEqual(Int(bounded.width) % 2, 0)
        XCTAssertEqual(Int(bounded.height) % 2, 0)
        let screenshot = try CanvasComposition.image(screens: screens)
        let counts = try colors(screenshot)
        XCTAssertEqual(counts.red, 5_000)
        XCTAssertEqual(counts.green, 5_000)
        XCTAssertEqual(counts.blue, 16_000)
        XCTAssertEqual(counts.red + counts.green + counts.blue, screenshot.width * screenshot.height,
                       "No black gap, title bar, border or surplus canvas pixel")
    }

    func testEmptyAndCancelledRecordingsDoNotReplaceExistingDestination() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.mp4")
        let existing = Data("synthetic existing destination".utf8)
        try existing.write(to: output)
        let empty = try CanvasRecorder(outputURL: output)
        empty.append(screens: [RecordingScreen(id: "empty", title: "Empty", image: nil,
            sourceSize: .zero, status: "Waiting", lastFrameAt: nil, isLive: true)], at: 0)
        do { _ = try await finish(empty, at: 1); XCTFail("An empty recording must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: output), existing) }
        let cancelled = try CanvasRecorder(outputURL: output)
        cancelled.append(screens: [screen("main", try image(red: 1, green: 0, blue: 0))], at: 0)
        cancelled.cancel()
        do { _ = try await finish(cancelled, at: 1); XCTFail("Cancelled recording must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: output), existing) }
        let replacement = try CanvasRecorder(outputURL: output)
        replacement.append(screens: [screen("main", try image(red: 0, green: 1, blue: 0))], at: 0)
        _ = try await finish(replacement, at: 1)
        XCTAssertNotEqual(try Data(contentsOf: output), existing)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(filenames.contains { $0.contains("partial") })
    }

    func testRemovedDisplayOverlaysStatusAndDateWithoutEnlargingCanvas() throws {
        let synthetic = try image(red: 1, green: 0, blue: 0)
        let live = try CanvasComposition.image(screens: [screen("main", synthetic)])
        let removed = try CanvasComposition.image(screens: [screen("main", synthetic, live: false)])
        XCTAssertEqual(live.width, removed.width)
        XCTAssertEqual(live.height, removed.height)
        let liveBytes = try pixels(live), removedBytes = try pixels(removed)
        var changedRows = Set<Int>()
        for y in 0..<live.height {
            let row = (y * live.width * 4)..<((y + 1) * live.width * 4)
            if liveBytes[row] != removedBytes[row] { changedRows.insert(y) }
        }
        XCTAssertGreaterThan(changedRows.count, 5, "Retained frame needs a visible dated overlay")
        XCTAssertLessThan(changedRows.count, 50, "Status must stay inside a small image overlay")
    }

    func testInvalidSettingsAreRejectedBeforeCreatingOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("invalid.mp4")
        for configuration in [CanvasRecordingConfiguration(width: 1279),
                              CanvasRecordingConfiguration(framesPerSecond: 0),
                              CanvasRecordingConfiguration(bitRate: 0)] {
            XCTAssertThrowsError(try CanvasRecorder(outputURL: output, configuration: configuration))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func finish(_ recorder: CanvasRecorder, at elapsed: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            recorder.finish(at: elapsed) { continuation.resume(with: $0) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func screen(_ id: String, _ image: CGImage, live: Bool = true) -> RecordingScreen {
        RecordingScreen(id: id, title: "Display \(id)", image: image,
            sourceSize: CGSize(width: image.width, height: image.height), status: live ? "Live" : "Removed",
            lastFrameAt: Date(timeIntervalSince1970: 1_700_000_000), isLive: live)
    }

    private func image(red: CGFloat, green: CGFloat, blue: CGFloat,
                       width: Int = 120, height: Int = 240) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func colors(_ image: CGImage) throws -> (red: Int, green: Int, blue: Int) {
        let bytes = try pixels(image)
        var red = 0, green = 0, blue = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if r > 180 && g < 80 && b < 80 { red += 1 }
            if g > 180 && r < 80 && b < 80 { green += 1 }
            if b > 180 && r < 80 && g < 80 { blue += 1 }
        }
        return (red, green, blue)
    }
}
