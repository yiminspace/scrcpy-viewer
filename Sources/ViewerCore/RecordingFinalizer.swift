import AVFoundation
import CoreGraphics
import Foundation

/// Publishes one silent MP4 from this session's ordered, finalized CanvasRecorder parts.
/// Source parts are retained on both success and failure; their owner cleans up the session.
public enum RecordingFinalizer {
    private struct Part {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: CMTime
        let bounds: CGRect
        let transform: CGAffineTransform
    }

    public static func publish(parts: [URL], to outputURL: URL) async throws -> URL {
        guard !parts.isEmpty, outputURL.isFileURL,
              parts.allSatisfy({ $0.isFileURL && $0.standardizedFileURL != outputURL.standardizedFileURL }) else {
            throw CanvasRecordingError.encoding("没有可合并的录屏片段")
        }
        try Task.checkCancellation()
        var loaded: [Part] = []
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CanvasRecordingError.encoding("录屏片段没有视频画面")
            }
            let (duration, naturalSize, transform) = try await (
                asset.load(.duration), track.load(.naturalSize), track.load(.preferredTransform))
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
                  bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw CanvasRecordingError.encoding("录屏片段的时长或尺寸无效")
            }
            loaded.append(Part(asset: asset, track: track, duration: duration, bounds: bounds, transform: transform))
            try Task.checkCancellation()
        }

        // Keep the old destination intact until a complete replacement is ready on the same volume.
        let temporaryDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryURL = temporaryDirectory.appendingPathComponent("recording.mp4")
        if parts.count == 1 {
            let generator = AVAssetImageGenerator(asset: loaded[0].asset)
            generator.maximumSize = CGSize(width: 64, height: 64)
            _ = try await withTaskCancellationHandler {
                try await generator.image(at: .zero)
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try FileManager.default.copyItem(at: parts[0], to: temporaryURL)
        } else {
            try await combine(loaded, to: temporaryURL)
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
        return outputURL
    }

    private static func combine(_ parts: [Part], to url: URL) async throws {
        let largestRatio = parts.map { $0.bounds.width / $0.bounds.height }.max() ?? 1
        let sourceHeight = parts.map(\.bounds.height).min() ?? 720
        let height = max(2, floor(min(720, sourceHeight, 2560 / largestRatio) / 2) * 2)
        let width = max(2, min(2560, ceil(height * largestRatio / 2) * 2))
        let size = CGSize(width: width, height: height)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CanvasRecordingError.encoding("无法创建合并视频轨道")
        }
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for part in parts {
            try Task.checkCancellation()
            let range = CMTimeRange(start: cursor, duration: part.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: part.duration), of: part.track, at: cursor)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let scale = height / part.bounds.height
            let transform = part.transform
                .concatenating(CGAffineTransform(translationX: -part.bounds.minX, y: -part.bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            layer.setTransform(transform, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, part.duration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 12)
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        videoComposition.instructions = instructions
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CanvasRecordingError.encoding("无法读取录屏片段") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(width), AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(200_000, min(1_600_000, Int(width * height) * 2)),
                AVVideoExpectedSourceFrameRateKey: 12,
                AVVideoMaxKeyFrameIntervalKey: 24,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CanvasRecordingError.encoding("无法创建 H.264 视频轨道") }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true
        do {
            guard writer.startWriting(), reader.startReading() else {
                throw writer.error ?? reader.error ?? CanvasRecordingError.encoding("无法开始合并录屏")
            }
            writer.startSession(atSourceTime: .zero)
            while let sample = output.copyNextSampleBuffer() {
                let waitingSince = ProcessInfo.processInfo.systemUptime
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing else {
                        throw writer.error ?? CanvasRecordingError.encoding("合并编码器已停止")
                    }
                    guard ProcessInfo.processInfo.systemUptime - waitingSince < 30 else {
                        throw CanvasRecordingError.encoding("合并编码器长时间未响应")
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try Task.checkCancellation()
                guard input.append(sample) else {
                    throw writer.error ?? CanvasRecordingError.encoding("无法写入合并画面")
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? CanvasRecordingError.encoding("录屏片段未能完整读取")
            }
            writer.endSession(atSourceTime: cursor)
            input.markAsFinished()
            writer.finishWriting {}
            let finishingSince = ProcessInfo.processInfo.systemUptime
            while writer.status == .writing {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - finishingSince < 30 else {
                    throw CanvasRecordingError.encoding("保存合并录屏超时")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard writer.status == .completed else {
                throw writer.error ?? CanvasRecordingError.encoding("合并录屏未能完整保存")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }
}
