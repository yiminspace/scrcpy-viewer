import AppKit
import SwiftUI
import ViewerCore

struct RecordingHistoryView: View {
    let recordings: [SavedRecording]
    let refresh: () -> Void
    let select: (SavedRecording) -> Void
    let trash: (SavedRecording) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("录屏历史").font(.system(size: 13, weight: .medium))
                        if !recordings.isEmpty {
                            Text("\(recordings.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起录屏历史" : "展开录屏历史")
                Spacer(minLength: 0)
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .help("刷新已保存的录屏")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if expanded {
                if recordings.isEmpty {
                    Text("录屏保存后会出现在这里，点击使用系统播放器播放。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.bottom, 8)
                } else {
                    LazyVStack(spacing: 3) {
                        ForEach(recordings) { recording in
                            SavedRecordingRow(recording: recording,
                                              select: { select(recording) },
                                              trash: { trash(recording) })
                        }
                    }
                }
            }
        }
    }
}

private struct SavedRecordingRow: View {
    let recording: SavedRecording
    let select: () -> Void
    let trash: () -> Void
    @State private var preview: RecordingPreview?
    @State private var previewUnavailable = false
    @State private var isHovered = false
    @State private var trashIsHovered = false
    @FocusState private var trashIsFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 8) {
                    ZStack {
                        Color.black
                        if let preview {
                            Image(decorative: preview.image, scale: 1)
                                .resizable().interpolation(.high).scaledToFit()
                        } else {
                            Image(systemName: previewUnavailable ? "film" : "video")
                                .font(.system(size: 17, weight: .light)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: 52, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.recordedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                            .font(.system(size: 11, weight: .medium))
                        Text(recording.recordedAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        Text(metadata)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("使用系统播放器播放 \(recording.url.lastPathComponent)")
            .accessibilityLabel("使用系统播放器播放录屏，\(recording.recordedAt.formatted(date: .abbreviated, time: .standard))，\(metadata)")

            Button(action: trash) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(trashIsHovered ? Color.primary : Color.secondary)
                    .frame(width: 20, height: 26)
                    .background(trashIsHovered ? Color.primary.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($trashIsFocused)
            .opacity(isHovered || trashIsFocused ? 1 : 0)
            .allowsHitTesting(isHovered || trashIsFocused)
            .onHover { trashIsHovered = $0 }
            .help("移到废纸篓")
            .accessibilityLabel("移到废纸篓")
            .accessibilityValue(recording.recordedAt.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .task(id: "\(recording.id):\(recording.recordedAt.timeIntervalSince1970):\(recording.fileSize)") {
            preview = nil
            previewUnavailable = false
            do {
                let loaded = try await RecordingPreviewLoader.load(url: recording.url)
                try Task.checkCancellation()
                preview = loaded
            } catch is CancellationError {
                return
            } catch {
                previewUnavailable = true
            }
        }
    }

    private var metadata: String {
        let fileSize = ByteCountFormatter.string(fromByteCount: recording.fileSize, countStyle: .file)
        guard let duration = preview?.duration, duration.isFinite, duration >= 0 else { return fileSize }
        let seconds = Int(duration)
        let time = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(time) · \(fileSize)"
    }
}
