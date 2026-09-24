import AppKit
import SwiftUI
import ViewerCore

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: ((@escaping () -> Void) -> Void)?
    weak var diagnostics: ViewerDiagnostics?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let shutdown else { return .terminateNow }
        terminationInProgress = true
        diagnostics?.recordLifecycle("termination_requested")
        shutdown { [weak self] in
            // Always defer the reply, including the no-model/no-stream path.
            DispatchQueue.main.async {
                self?.diagnostics?.recordLifecycle("termination_reply")
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct ScrcpyViewerApp: App {
    @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var delegate
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        Window("Scrcpy Viewer", id: "viewer") {
            ViewerWindow(model: model)
                .frame(minWidth: 900, minHeight: 650)
                .onAppear {
                    delegate.diagnostics = model.diagnostics
                    delegate.shutdown = { [weak model] completion in
                        guard let model else { completion(); return }
                        model.shutdown(completion: completion)
                    }
                    model.start()
                }
        }
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("保存全部屏幕截图…") { model.saveScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveScreenshot)
                Button(model.isRecording ? "停止录制" : "录制全部屏幕") {
                    if model.isRecording { model.stopRecording() } else { model.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isFinishingRecording || (!model.isRecording && !model.canStartRecording))
            }
        }
    }
}

private struct ViewerWindow: View {
    @ObservedObject var model: ViewerModel
    @State private var recordingPlaybackError: String?
    @State private var recordingDeletionError: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                if let error = model.dependencyError ?? model.discoveryError ?? model.interactionError {
                    errorBanner(error)
                    Divider()
                }
                stage
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                devicePicker
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .help("重新发现设备和屏幕，并重试连接失败的画面")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.followNewScreen) {
                    Label("跟随新副屏", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.checkbox)
                .help("自动选择新出现或恢复的副屏；主屏正在输入时保持当前焦点")
                recordingButton
                recordingSettings
                Button(action: model.saveScreenshot) {
                    Label("保存全部屏幕截图", systemImage: "camera").labelStyle(.iconOnly)
                }
                .disabled(!model.canSaveScreenshot)
                .help("将主屏和所有副屏合成一张截图保存。⌘⇧S")
            }
        }
        .alert("图片未保存", isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })) {
            Button("好", role: .cancel) { model.saveError = nil }
        } message: { Text(model.saveError ?? "") }
        .alert("录屏未保存", isPresented: Binding(get: { model.recordingError != nil }, set: { if !$0 { model.recordingError = nil } })) {
            if model.recordingRecoveryDirectory != nil {
                Button("查看已录制部分", action: model.revealUnfinishedRecording)
            }
            Button("好", role: .cancel) { model.recordingError = nil }
        } message: { Text(model.recordingError ?? "") }
        .alert("无法打开录屏", isPresented: Binding(get: { recordingPlaybackError != nil }, set: { if !$0 { recordingPlaybackError = nil } })) {
            Button("好", role: .cancel) { recordingPlaybackError = nil }
        } message: { Text(recordingPlaybackError ?? "") }
        .alert("录屏未删除", isPresented: Binding(get: { recordingDeletionError != nil }, set: { if !$0 { recordingDeletionError = nil } })) {
            Button("好", role: .cancel) { recordingDeletionError = nil }
        } message: { Text(recordingDeletionError ?? "") }
    }

    private var devicePicker: some View {
        Picker("设备", selection: Binding(get: { model.selectedSerial ?? "" }, set: { model.selectDevice($0) })) {
            if model.devices.isEmpty || model.selectedSerial == nil {
                Text(model.devices.isEmpty ? "未发现设备" : "选择设备").tag("")
            }
            if let serial = model.selectedSerial, !model.devices.contains(where: { $0.serial == serial }) {
                Text("\(serial) · 已断开").tag(serial)
            }
            ForEach(model.devices) { device in
                Text("\(device.model.isEmpty ? device.serial : device.model)\(device.isConnected ? "" : " · \(device.connectionState)")")
                    .tag(device.serial)
            }
        }
        .labelsHidden()
        .frame(minWidth: 130, maxWidth: 220)
        .help("选择通过 adb 连接的 Android 设备")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("屏幕").font(.headline)
                Spacer()
                Text("自动发现").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.currentScreens) { screen in
                        screenRow(screen)
                    }
                    if model.currentScreens.isEmpty {
                        Text(model.isConnected ? "正在发现屏幕…" : "连接设备后，屏幕会出现在这里。")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Divider().padding(.top, 10).padding(.bottom, 5)
                    RecordingHistoryView(recordings: model.recordingHistory,
                                         refresh: model.refreshRecordingHistory,
                                         select: playRecording,
                                         trash: trashRecording)
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Label("主屏可操作", systemImage: "cursorarrow").font(.caption).foregroundStyle(.secondary)
                Text("副屏仅观看，出现后自动加入。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func playRecording(_ recording: SavedRecording) {
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            recordingPlaybackError = "这段录屏已被移动或删除。录屏列表已刷新。"
            model.refreshRecordingHistory()
            return
        }
        if !NSWorkspace.shared.open(recording.url) {
            recordingPlaybackError = "无法使用系统播放器打开这段录屏，请确认已安装支持 MP4 的播放器。"
        }
    }

    private func trashRecording(_ recording: SavedRecording) {
        do {
            try model.trashRecording(recording)
        } catch {
            recordingDeletionError = error.localizedDescription
            model.refreshRecordingHistory()
        }
    }

    private func screenRow(_ screen: DisplayPresentation) -> some View {
        let selected = model.selectedScreenID == screen.id
        return Button { model.selectScreen(screen.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: screen.display.isMain ? "iphone" : "rectangle.on.rectangle")
                    .font(.system(size: 17)).frame(width: 23).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(screen.display.title).font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(screen)).frame(width: 5, height: 5)
                        Text(screen.status).font(.caption)
                    }.foregroundStyle(.secondary)
                    Text("\(screen.display.width) × \(screen.display.height) · \(screen.display.isMain ? "可操作" : "仅观看")")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(screen.display.title)，\(screen.status)")
    }

    @ViewBuilder private var stage: some View {
        if model.visibleScreens.isEmpty {
            emptyStage
        } else {
            VStack(spacing: 0) {
                stageControls
                GeometryReader { geometry in
                    let screens = model.visibleScreens
                    let availableHeight = max(1, geometry.size.height - 48)
                    let aspectSum = screens.reduce(CGFloat.zero) { $0 + displayAspectRatio($1) }
                    let availableWidth = max(1, geometry.size.width - 40)
                    // Keep a useful viewing size when many displays are present;
                    // the shared canvas then scrolls instead of shrinking every screen.
                    let fittedHeight = availableWidth / max(0.1, aspectSum)
                    let imageHeight = min(availableHeight, max(min(480, availableHeight), fittedHeight))
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(screens) { screen in
                                    DisplayPane(model: model, screen: screen, imageHeight: imageHeight,
                                                retry: { model.retry(screen.id) })
                                        .frame(width: imageHeight * displayAspectRatio(screen))
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.selectScreen(screen.id) }
                                        .id(screen.id)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
                        }
                        .onChange(of: model.selectedScreenID) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: model.selectedScreen?.display.isMain == true ? .leading : .trailing)
                            }
                        }
                    }
                }
            }
            .background(stageColor)
        }
    }

    private var stageControls: some View {
        HStack(spacing: 15) {
            if let main = model.visibleScreens.first(where: { $0.display.isMain }) {
                Text("主屏操作").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { model.navigateMain(main.id, keyCode: 4) } label: { Image(systemName: "chevron.left") }
                    .help("返回").disabled(!model.canControl(main.id))
                Button { model.navigateMain(main.id, keyCode: 3) } label: { Image(systemName: "house") }
                    .help("Home").disabled(!model.canControl(main.id))
                Button { model.navigateMain(main.id, keyCode: 187) } label: { Image(systemName: "square.on.square") }
                    .help("最近任务").disabled(!model.canControl(main.id))
                if main.presence == .sleeping {
                    Button(action: model.wakeMainDisplay) {
                        Label(model.isWakingMain ? "正在唤醒" : "唤醒主屏", systemImage: "sun.max")
                    }
                    .disabled(!model.isConnected || model.isWakingMain)
                    .help("向手机发送一次唤醒按键；不会自动解锁")
                } else {
                    Label(model.focusedScreenID == main.id ? "键盘正在控制主屏" : "点击主屏后输入", systemImage: "keyboard")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("右键返回 · 中键 Home · ⌘A 全选 · ⌘C / V / X 复制、粘贴、剪切")
                }
            }
            Spacer(minLength: 8)
            Text("副屏仅观看").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(Color(white: 0.96))
        .frame(height: 24)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .environment(\.colorScheme, .dark)
    }

    private var recordingButton: some View {
        Button {
            if model.isRecording { model.stopRecording() } else { model.startRecording() }
        } label: {
            HStack(spacing: 6) {
                if model.isFinishingRecording {
                    ProgressView().controlSize(.small)
                    Text("正在保存…")
                } else {
                    Image(systemName: model.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(model.isRecording ? Color.red : Color.primary)
                    Text(model.isRecording ? "停止录制" : "录制全部屏幕")
                    if model.isRecording {
                        Text(recordingDuration(model.recordingElapsed)).monospacedDigit()
                    }
                }
            }
        }
        .disabled(model.isFinishingRecording || (!model.isRecording && !model.canStartRecording))
        .help("将主屏和所有副屏保存为一个小体积 MP4；新增副屏也会加入，停止后自动合成。⌘⇧R 开始或停止")
    }

    private var recordingSettings: some View {
        Menu {
            Toggle("副屏开启时自动录制", isOn: $model.autoRecordSecondary)
            Text("全部副屏关闭后自动停止并保存")
                .font(.caption)
            Divider()
            Button("选择自动录屏目录…", action: model.chooseRecordingDirectory)
            Button("打开录屏目录", action: model.revealRecordingDirectory)
            Text(model.recordingDirectory.path).font(.caption)
        } label: {
            Label("录屏设置", systemImage: "gearshape").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("录屏设置：可在副屏开启时自动录制，全部副屏关闭后停止并保存")
    }

    private var emptyStage: some View {
        VStack(spacing: 14) {
            Image(systemName: model.dependencyError == nil ? "cable.connector" : "wrench.and.screwdriver")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(model.dependencyError != nil ? "需要设备连接依赖" : (model.isConnected ? "正在读取设备屏幕" : "连接 Android 设备"))
                .font(.title3.weight(.medium))
            Text(emptyHint).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 390)
            Button("重新检查", action: model.refresh)
            if model.dependencyError != nil {
                Link("安装说明", destination: URL(string: "https://github.com/yiminspace/scrcpy-viewer/blob/main/docs/install.md")!)
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(stageColor)
            .environment(\.colorScheme, .dark)
    }

    private var emptyHint: String {
        if model.dependencyError != nil { return "请安装 adb 和兼容的 scrcpy 服务端，再点击重新检查。下载包内附有依赖安装脚本，详情见安装说明。" }
        if model.selectedDevice?.connectionState == "unauthorized" { return "请在手机上允许这台 Mac 进行 USB 调试。授权后屏幕会自动出现。" }
        if model.selectedDevice?.connectionState == "offline" { return "adb 报告设备离线。请检查 USB 连接，等待设备恢复。" }
        if model.isConnected { return "主屏和系统可枚举的副屏会自动出现在左侧。" }
        return "使用 USB 连接手机，打开 USB 调试，并在手机上允许这台 Mac。"
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: model.refresh)
        }.padding(12).background(Color.orange.opacity(0.07))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(model.isConnected ? "adb 已连接" : "等待设备连接")
            if let serial = model.selectedSerial {
                Text(serial).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            if model.diagnostics.directory != nil {
                Label("诊断记录已开启", systemImage: "record.circle").foregroundStyle(.orange)
            }
            if model.autoRecordSecondary {
                Label("自动录屏", systemImage: "record.circle")
                    .help("副屏开启时自动录制，全部副屏关闭后自动保存")
            }
            if model.isRecording {
                Label("录制全部屏幕 · \(recordingDuration(model.recordingElapsed))", systemImage: "record.circle.fill")
                    .foregroundStyle(.red).monospacedDigit()
            } else if model.isFinishingRecording {
                Text("正在保存录屏…")
            } else if model.lastRecordingURL != nil {
                Button("查看录屏", action: model.revealRecording).buttonStyle(.borderless)
            } else {
                Text("画面静止时仍保持连接")
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
    }
}

private struct DisplayPane: View {
    @ObservedObject var model: ViewerModel
    let screen: DisplayPresentation
    let imageHeight: CGFloat
    let retry: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(screen.display.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Circle().fill(statusColor(screen)).frame(width: 5, height: 5)
                Text(screen.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Button {
                    model.setInputFocus(false, for: screen.id)
                    showsDetails.toggle()
                } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("屏幕与连接详情")
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details.padding(20).frame(width: 360) }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            ZStack {
                if let frame = screen.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .opacity(screen.isRetained ? 0.72 : 1)
                        .accessibilityLabel("\(screen.display.title)的\(screen.isRetained ? "最后" : "当前")画面")
                    if screen.display.isMain {
                        MainDisplayInputView(
                            frameSize: CGSize(width: frame.width, height: frame.height),
                            enabled: model.canControl(screen.id),
                            focused: model.focusedScreenID == screen.id,
                            send: { model.sendInput($0, to: screen.id) },
                            focusChanged: { model.setInputFocus($0, for: screen.id) }
                        )
                        .accessibilityLabel("主屏键鼠操作区域")
                    }
                } else {
                    VStack(spacing: 12) {
                        if screen.presence == .active && screen.error == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: screen.error == nil ? "display" : "exclamationmark.triangle")
                                .font(.title2)
                        }
                        Text(screen.status).font(.callout)
                        if screen.error != nil { Button("重试画面连接", action: retry) }
                    }.foregroundStyle(.white.opacity(0.65)).padding(20)
                }
                if screen.isRetained {
                    VStack {
                        Spacer()
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "clock").font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(screen.status) · 最后画面").font(.system(size: 11, weight: .medium))
                                if let date = screen.lastFrameAt {
                                    Text(date.formatted(date: .numeric, time: .standard))
                                        .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                                }
                            }
                            Spacer(minLength: 0)
                            if screen.error != nil { Button("重试", action: retry) }
                        }
                        .foregroundStyle(.white).padding(10).background(.black.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
        }
        .foregroundStyle(Color(white: 0.96))
        .environment(\.colorScheme, .dark)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.display.title).font(.headline)
            detail("Display ID", "\(screen.display.displayID)")
            detail("源屏状态", screen.display.state)
            detail("画面状态", screen.status)
            detail("输入", screen.display.isMain ? (screen.controlReady ? "主屏控制已就绪" : "控制未就绪") : "副屏仅观看")
            detail("分辨率", "\(screen.display.width) × \(screen.display.height)")
            detail("名称", screen.display.name)
            detail("Owner", screen.display.owner.isEmpty ? "—" : screen.display.owner)
            detail("Unique ID", screen.display.uniqueID)
            if let date = screen.lastFrameAt { detail("最后画面", date.formatted(date: .abbreviated, time: .standard)) }
            if let error = screen.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("画面不变化不会被判为断线。休眠状态来自 Android 的实际源屏状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }
}

private var stageColor: Color { .black }

private func displayAspectRatio(_ screen: DisplayPresentation) -> CGFloat {
    if let frame = screen.frame { return CGFloat(frame.width) / CGFloat(max(1, frame.height)) }
    return CGFloat(max(1, screen.display.width)) / CGFloat(max(1, screen.display.height))
}

private func recordingDuration(_ elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed))
    if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func statusColor(_ screen: DisplayPresentation) -> Color {
    if screen.error != nil && screen.presence == .active { return .orange }
    if screen.isLive { return Color(red: 0.14, green: 0.47, blue: 0.4) }
    if screen.presence == .active { return .gray }
    return .secondary
}
