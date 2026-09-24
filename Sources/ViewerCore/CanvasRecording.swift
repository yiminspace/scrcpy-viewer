import AVFoundation
import CoreGraphics
import Foundation

public struct RecordingScreen {
    public let id: String
    public let title: String
    public let image: CGImage?
    public let sourceSize: CGSize
    public let status: String
    public let lastFrameAt: Date?
    public let isLive: Bool

    public init(id: String, title: String, image: CGImage?, sourceSize: CGSize,
                status: String, lastFrameAt: Date?, isLive: Bool) {
        self.id = id
        self.title = title
        self.image = image
        self.sourceSize = sourceSize
        self.status = status
        self.lastFrameAt = lastFrameAt
        self.isLive = isLive
    }
}

public struct CanvasRecordingConfiguration {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let bitRate: Int

    public static let compact = CanvasRecordingConfiguration()

    public static func compact(for screens: [RecordingScreen]) -> CanvasRecordingConfiguration {
        let size = CanvasComposition.size(for: screens)
        let bitRate = max(200_000, min(1_600_000, Int(size.width * size.height) * 2))
        return CanvasRecordingConfiguration(width: Int(size.width), height: Int(size.height), bitRate: bitRate)
    }

    public init(width: Int = 1280, height: Int = 720, framesPerSecond: Int = 12,
                bitRate: Int = 1_600_000) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitRate = bitRate
    }
}

public enum CanvasRecordingError: LocalizedError {
    case invalidConfiguration
    case noFrames
    case cancelled
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "录屏参数无效"
        case .noFrames: return "尚未收到可录制的画面"
        case .cancelled: return "录屏已取消"
        case .encoding(let message): return "保存录屏失败：\(message)"
        }
    }
}

/// Composes decoded display frames into a silent MP4 without capturing the Mac desktop.
/// Appends are nonblocking: keep the initial snapshot and replace older pending work with the latest.
/// Callbacks run on this recorder's serial queue, outside its state lock.
public final class CanvasRecorder {
    private struct Snapshot {
        let screens: [RecordingScreen]
        let elapsed: TimeInterval
    }

    public let outputURL: URL
    public let configuration: CanvasRecordingConfiguration
    private let temporaryDirectory: URL
    private let temporaryURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let onFailure: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "scrcpy-viewer.canvas-recording", qos: .utility)
    private let lock = NSLock()
    // Access these state fields only under lock.
    private var pending: Snapshot?
    private var firstPending: Snapshot?
    private var receivedFirstSnapshot = false
    private var accepting = true
    private var drainScheduled = false
    private var finishElapsed: TimeInterval?
    private var finishRequestedAt: TimeInterval?
    private var completions: [(Result<URL, Error>) -> Void] = []
    private var terminalResult: Result<URL, Error>?
    // Access the remaining encoding fields only on queue.
    private var latest: Snapshot?
    private var lastFrameIndex: Int64 = -1
    private var encodedImage = false
    private var isFinishing = false
    private var finished = false

    public init(outputURL: URL, configuration: CanvasRecordingConfiguration = .compact,
                onFailure: ((Error) -> Void)? = nil) throws {
        guard outputURL.isFileURL, configuration.width >= 64, configuration.width <= 8192,
              configuration.height >= 64, configuration.height <= 8192,
              configuration.width.isMultiple(of: 2), configuration.height.isMultiple(of: 2),
              (1...60).contains(configuration.framesPerSecond), configuration.bitRate > 0 else {
            throw CanvasRecordingError.invalidConfiguration
        }
        self.outputURL = outputURL
        self.configuration = configuration
        self.onFailure = onFailure
        temporaryDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        temporaryURL = temporaryDirectory.appendingPathComponent("recording.mp4")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        do { writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4) }
        catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.bitRate,
                AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw CanvasRecordingError.encoding("无法创建 H.264 视频轨道")
        }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true
        guard writer.startWriting() else {
            let error = writer.error ?? CanvasRecordingError.encoding("无法开始写入文件")
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if !finished {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// Supply elapsed monotonic time from the recording start, including while source frames are static.
    public func append(screens: [RecordingScreen], at elapsed: TimeInterval) {
        guard valid(elapsed) else { return }
        lock.lock()
        guard accepting, pending.map({ elapsed >= $0.elapsed }) ?? true else {
            lock.unlock()
            return
        }
        let snapshot = Snapshot(screens: screens, elapsed: elapsed)
        if receivedFirstSnapshot { pending = snapshot }
        else {
            firstPending = snapshot
            receivedFirstSnapshot = true
        }
        scheduleDrainLocked()
        lock.unlock()
    }

    /// The elapsed stop time preserves the final held image even when no new device frame arrived.
    public func finish(at elapsed: TimeInterval, completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            queue.async { completion(terminalResult) }
            return
        }
        completions.append(completion)
        accepting = false
        if finishRequestedAt == nil { finishRequestedAt = ProcessInfo.processInfo.systemUptime }
        let requested = valid(elapsed) ? elapsed : 0
        finishElapsed = max(finishElapsed ?? 0, requested)
        scheduleDrainLocked()
        lock.unlock()
    }

    /// Prefer finish(at:completion:) when the caller has a recording clock.
    public func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        finish(at: 0, completion: completion)
    }

    /// Discards this recording, including its temporary file. Existing destination files are preserved.
    public func cancel() {
        lock.lock()
        accepting = false
        pending = nil
        firstPending = nil
        lock.unlock()
        queue.async { self.fail(CanvasRecordingError.cancelled, notify: false) }
    }

    private func valid(_ elapsed: TimeInterval) -> Bool {
        elapsed.isFinite && elapsed >= 0 && elapsed < Double(Int64.max / 120)
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.async { self.drain() }
    }

    private func drain() {
        guard !finished, !isFinishing else { return }
        guard writer.status == .writing else {
            fail(writer.error ?? CanvasRecordingError.encoding("编码器已停止"))
            return
        }
        guard input.isReadyForMoreMediaData else {
            lock.lock()
            let requestedAt = finishRequestedAt
            lock.unlock()
            if let requestedAt, ProcessInfo.processInfo.systemUptime - requestedAt > 10 {
                fail(CanvasRecordingError.encoding("编码器长时间未响应"))
                return
            }
            // Keep at most one retry; do not queue incoming decoded frames.
            queue.asyncAfter(deadline: .now() + 0.02) { self.drain() }
            return
        }
        lock.lock()
        let next: Snapshot?
        if let firstPending {
            next = firstPending
            self.firstPending = nil
        } else {
            next = pending
            pending = nil
        }
        lock.unlock()
        do {
            if let next, next.elapsed >= (latest?.elapsed ?? 0) {
                latest = next
                let index = Int64(floor(next.elapsed * Double(configuration.framesPerSecond)))
                if index > lastFrameIndex { try write(next, frameIndex: index) }
            }
            lock.lock()
            let hasPending = firstPending != nil || pending != nil
            let stopAt = finishElapsed
            if !hasPending && stopAt == nil { drainScheduled = false }
            lock.unlock()
            if hasPending {
                queue.async { self.drain() }
            } else if let stopAt {
                try beginFinish(at: stopAt)
            }
        } catch {
            fail(error)
        }
    }

    private func write(_ snapshot: Snapshot, frameIndex: Int64) throws {
        guard let pool = adaptor.pixelBufferPool else {
            throw CanvasRecordingError.encoding("无法创建视频帧缓冲区")
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw CanvasRecordingError.encoding("无法分配视频帧缓冲区") }
        try CanvasRecordingRenderer.render(snapshot.screens, into: buffer)
        let timestamp = CMTime(value: frameIndex, timescale: Int32(configuration.framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: timestamp) else {
            throw writer.error ?? CanvasRecordingError.encoding("无法写入视频帧")
        }
        encodedImage = encodedImage || snapshot.screens.contains { $0.image != nil }
        lastFrameIndex = frameIndex
    }

    private func beginFinish(at elapsed: TimeInterval) throws {
        guard let latest, encodedImage || latest.screens.contains(where: { $0.image != nil }) else {
            throw CanvasRecordingError.noFrames
        }
        let fps = Double(configuration.framesPerSecond)
        // End at the requested wall-clock boundary, even inside the final frame.
        // Adding a full frame here would repeat time across consecutive parts.
        let minimumDuration = encodedImage
            ? max(1 / fps, Double(lastFrameIndex) / fps + 1 / 60_000)
            : Double(lastFrameIndex + 2) / fps
        let duration = max(elapsed, minimumDuration)
        let finalIndex = Int64(ceil(duration * fps)) - 1
        if finalIndex > lastFrameIndex {
            guard input.isReadyForMoreMediaData else {
                queue.asyncAfter(deadline: .now() + 0.02) { self.drain() }
                return
            }
            try write(latest, frameIndex: finalIndex)
        }
        isFinishing = true
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        input.markAsFinished()
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.isFinishing, !self.finished else { return }
            self.fail(CanvasRecordingError.encoding("保存录屏超时"))
        }
        writer.finishWriting { [self] in
            queue.async {
                guard !self.finished else { return }
                guard self.writer.status == .completed else {
                    self.fail(self.writer.error ?? CanvasRecordingError.encoding("视频未完整保存"))
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: self.outputURL.path) {
                        _ = try FileManager.default.replaceItemAt(self.outputURL, withItemAt: self.temporaryURL)
                    } else {
                        try FileManager.default.moveItem(at: self.temporaryURL, to: self.outputURL)
                    }
                    try? FileManager.default.removeItem(at: self.temporaryDirectory)
                    self.complete(.success(self.outputURL))
                } catch { self.fail(error) }
            }
        }
    }

    private func fail(_ error: Error, notify: Bool = true) {
        guard !finished else { return }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: temporaryDirectory)
        complete(.failure(error))
        if notify { onFailure?(error) }
    }

    private func complete(_ result: Result<URL, Error>) {
        finished = true
        latest = nil
        lock.lock()
        terminalResult = result
        accepting = false
        pending = nil
        firstPending = nil
        let callbacks = completions
        completions = []
        lock.unlock()
        callbacks.forEach { $0(result) }
    }
}

enum CanvasRecordingRenderer {
    static func render(_ screens: [RecordingScreen], into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width,
            height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw CanvasRecordingError.encoding("无法合成录屏画面")
        }
        CanvasComposition.draw(screens, in: context, size: CGSize(width: width, height: height))
    }
}
