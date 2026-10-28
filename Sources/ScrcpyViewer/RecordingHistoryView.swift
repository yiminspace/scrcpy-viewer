import AppKit
import SwiftUI
import ViewerCore

struct RecordingHistoryView: View, Equatable {
    let recordings: [SavedRecording]
    let refresh: () -> Void
    let select: (SavedRecording) -> Void
    let trash: (SavedRecording) -> Void
    @State private var expanded = true
    @State private var recordingToTrash: SavedRecording?

    // Live screen frames invalidate the parent many times per second. History
    // actions belong to the same window; only catalog changes affect this view.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recordings == rhs.recordings
    }

    private var recordingDays: [(date: Date, recordings: [SavedRecording])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.recordedAt) }
        return grouped.keys.sorted(by: >).map { (date: $0, recordings: grouped[$0] ?? []) }
    }

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
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(recordingDays, id: \.date) { day in
                            Section {
                                ForEach(day.recordings) { recording in
                                    SavedRecordingRow(recording: recording,
                                                      select: { select(recording) },
                                                      trash: { recordingToTrash = recording })
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(day.date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                    Divider()
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 9)
                                .padding(.bottom, 3)
                            }
                        }
                    }
                }
            }
        }
        .alert("将这段录屏移到废纸篓？", isPresented: Binding(
            get: { recordingToTrash != nil },
            set: { if !$0 { recordingToTrash = nil } }
        ), presenting: recordingToTrash) { recording in
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("移到废纸篓", role: .destructive) {
                trash(recording)
            }
        } message: { recording in
            Text("录制时间：\(recording.recordedAt.formatted(date: .abbreviated, time: .standard))\n\(recording.url.lastPathComponent)\n\n移除后可在访达的废纸篓中恢复。")
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
                        Text(recording.recordedAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
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
            .help("将录屏移到废纸篓…")
            .accessibilityLabel("将录屏移到废纸篓…")
            .accessibilityValue(recording.recordedAt.formatted(date: .abbreviated, time: .standard))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        // Lazy stacks can retain row state after it leaves the viewport. Keep
        // offscreen images only in the bounded shared cache.
        .onDisappear { preview = nil }
        .task(id: "\(recording.id):\(recording.recordedAt.timeIntervalSince1970):\(recording.fileSize)") {
            preview = nil
            previewUnavailable = false
            do {
                let loaded = try await RecordingPreviewCache.shared.load(recording)
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
