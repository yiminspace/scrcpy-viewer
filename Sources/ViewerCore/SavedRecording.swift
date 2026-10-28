import AVFoundation
import CoreGraphics
import Foundation

public struct SavedRecording: Identifiable, Equatable, Sendable {
    public let url: URL
    public let recordedAt: Date
    public let fileSize: Int64
    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, recordedAt: Date, fileSize: Int64) {
        self.url = url.standardizedFileURL
        self.recordedAt = recordedAt
        self.fileSize = fileSize
    }
}

public enum RecordingHistoryCatalog {
    /// Reads only the app's selected recording directory and files it previously saved elsewhere.
    public static func list(recordedURLs: [URL], directory: URL) -> [SavedRecording] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
                                       .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let localFiles = directory.isFileURL
            ? (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            : []
        var recordings: [String: SavedRecording] = [:]
        for candidate in recordedURLs + localFiles {
            guard candidate.isFileURL else { continue }
            let url = candidate.standardizedFileURL
            let filename = url.lastPathComponent.lowercased()
            guard url.pathExtension.lowercased() == "mp4", !filename.hasPrefix("."),
                  !filename.hasSuffix(".partial.mp4"), !filename.hasSuffix(".tmp.mp4"),
                  !filename.hasSuffix(".temp.mp4"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  values.isHidden != true else { continue }
            // Replacing an existing destination may retain its original creation date.
            let recordedAt = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
            let recording = SavedRecording(url: url, recordedAt: recordedAt,
                fileSize: Int64(max(0, values.fileSize ?? 0)))
            recordings[recording.id] = recording
        }
        return recordings.values.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            if $0.url.lastPathComponent != $1.url.lastPathComponent {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.id < $1.id
        }
    }
}

public struct RecordingPreview {
    public let image: CGImage
    public let duration: TimeInterval

    public init(image: CGImage, duration: TimeInterval) {
        self.image = image
        self.duration = duration
    }
}

public enum RecordingPreviewError: LocalizedError {
    case noVideoTrack

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "录屏中没有可播放的视频画面"
        }
    }
}

public enum RecordingPreviewLoader {
    public static func load(url: URL) async throws -> RecordingPreview {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw RecordingPreviewError.noVideoTrack
        }
        let assetDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(assetDuration)
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        let requestedTime = CMTime(seconds: min(1, duration / 3), preferredTimescale: 600)
        let generated = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await generator.image(at: requestedTime)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        return RecordingPreview(image: generated.image, duration: duration)
    }
}

/// Shares previews across lazy row lifetimes, and avoids opening many video
/// decoders at once when a large history first enters the scroll viewport.
public actor RecordingPreviewCache {
    public static let shared = RecordingPreviewCache()

    private struct Key: Hashable {
        let path: String
        let date: Date
        let size: Int64
    }

    private let capacity: Int
    private let loader: (URL) async throws -> RecordingPreview
    private var previews: [Key: RecordingPreview] = [:]
    private var recency: [Key] = []
    private var pending: [Key: Task<RecordingPreview, Error>] = [:]
    private var tail: Task<Void, Never>?

    public init(capacity: Int = 96,
                loader: @escaping (URL) async throws -> RecordingPreview = RecordingPreviewLoader.load) {
        self.capacity = max(1, capacity)
        self.loader = loader
    }

    public func load(_ recording: SavedRecording) async throws -> RecordingPreview {
        try Task.checkCancellation()
        let key = Key(path: recording.id, date: recording.recordedAt, size: recording.fileSize)
        if let preview = previews[key] {
            touch(key)
            return preview
        }
        if let task = pending[key] { return try await task.value }

        let previous = tail
        let loader = self.loader
        // A row disappearing must not cancel a decode shared by another row or
        // a subsequent appearance. The UI checks its own cancellation on return.
        let task = Task {
            await previous?.value
            return try await loader(recording.url)
        }
        pending[key] = task
        tail = Task { _ = await task.result }
        do {
            let preview = try await task.value
            pending[key] = nil
            previews[key] = preview
            touch(key)
            while recency.count > capacity {
                previews.removeValue(forKey: recency.removeFirst())
            }
            if pending.isEmpty { tail = nil }
            return preview
        } catch {
            pending[key] = nil
            if pending.isEmpty { tail = nil }
            throw error
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
