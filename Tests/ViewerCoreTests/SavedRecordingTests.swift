import CoreGraphics
import Foundation
import XCTest
@testable import ViewerCore

final class SavedRecordingTests: XCTestCase {
    func testCatalogFiltersDeduplicatesAndSortsOnlyAllowedLocations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("recordings", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_010_000)
        let oldest = try file("old.mp4", in: directory, recordedAt: older)
        let first = try file("a.MP4", in: directory, recordedAt: newer)
        let second = try file("b.mp4", in: directory, recordedAt: newer)
        let known = try file("known.mp4", in: elsewhere, recordedAt: newer.addingTimeInterval(100))
        _ = try file("unknown.mp4", in: elsewhere, recordedAt: newer.addingTimeInterval(200))
        let hidden = try file(".hidden.mp4", in: directory, recordedAt: newer)
        _ = try file("unfinished.partial.mp4", in: directory, recordedAt: newer)
        _ = try file("unfinished.tmp.mp4", in: directory, recordedAt: newer)
        _ = try file("note.txt", in: directory, recordedAt: newer)
        let nested = directory.appendingPathComponent("nested.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try file("nested.mp4", in: nested, recordedAt: newer)
        let symlink = directory.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: known)
        let duplicate = directory.appendingPathComponent("unused/../a.MP4")
        let recordings = RecordingHistoryCatalog.list(recordedURLs: [known, hidden, first, duplicate,
            directory.appendingPathComponent("missing.mp4")], directory: directory)
        XCTAssertEqual(recordings.map(\.url), [known, first, second, oldest])
        XCTAssertEqual(recordings.map(\.recordedAt), [newer.addingTimeInterval(100), newer, newer, older])
        XCTAssertTrue(recordings.allSatisfy { $0.fileSize == 17 })
        XCTAssertEqual(Set(recordings.map(\.id)).count, recordings.count)
    }

    func testMissingDirectoryStillListsExplicitlySavedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try file("saved.mp4", in: root, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let recordings = RecordingHistoryCatalog.list(recordedURLs: [url],
            directory: root.appendingPathComponent("missing", isDirectory: true))
        XCTAssertEqual(recordings.map(\.url), [url])
    }

    func testReplacementUsesNewerModificationDateWhenCreationDateWasPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        let replacement = original.addingTimeInterval(3_600)
        let url = try file("replaced.mp4", in: root, recordedAt: original)
        try FileManager.default.setAttributes([.modificationDate: replacement], ofItemAtPath: url.path)
        let recordings = RecordingHistoryCatalog.list(recordedURLs: [], directory: root)
        XCTAssertEqual(recordings.first?.recordedAt, replacement)
    }

    func testThumbnailDecodesSavedMP4WithinBoundsAndReportsDuration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.mp4")
        let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 960,
            bitsPerComponent: 8, bytesPerRow: 480 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 960))
        let image = try XCTUnwrap(context.makeImage())
        let screens = [RecordingScreen(id: "main", title: "Main", image: image,
            sourceSize: CGSize(width: 480, height: 960), status: "Live", lastFrameAt: Date(), isLive: true)]
        let recorder = try CanvasRecorder(outputURL: url, configuration: .compact(for: screens))
        recorder.append(screens: screens, at: 0)
        let saved: URL = try await withCheckedThrowingContinuation { continuation in
            recorder.finish(at: 2) { continuation.resume(with: $0) }
        }
        let preview = try await RecordingPreviewLoader.load(url: saved)
        XCTAssertEqual(preview.duration, 2, accuracy: 0.1)
        XCTAssertEqual(preview.image.width, 90)
        XCTAssertEqual(preview.image.height, 180)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let sample = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            sample.draw(preview.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThan(pixel[0], 80)
        XCTAssertGreaterThan(pixel[1], 180)
        XCTAssertLessThan(pixel[2], 80)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func file(_ name: String, in directory: URL, recordedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("synthetic fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: recordedAt, .modificationDate: recordedAt],
                                              ofItemAtPath: url.path)
        return url.standardizedFileURL
    }
}
