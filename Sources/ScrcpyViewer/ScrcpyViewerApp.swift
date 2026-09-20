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
                Button("保存当前画面…") { model.saveScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.selectedScreen?.frame == nil)
            }
        }
    }
}

private struct ViewerWindow: View {
    @ObservedObject var model: ViewerModel
    @State private var historyExpanded = false

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
                Picker("布局", selection: $model.layout) {
                    ForEach(ViewerLayout.allCases) { layout in Text(layout.rawValue).tag(layout) }
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                Toggle(isOn: $model.followNewScreen) {
                    Label("跟随新副屏", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.checkbox)
                .help("自动选择新出现或恢复的副屏；主屏正在输入时保持当前焦点")
                Button(action: model.saveScreenshot) { Image(systemName: "square.and.arrow.down") }
                    .disabled(model.selectedScreen?.frame == nil)
                    .help("保存选中屏幕的当前画面")
            }
        }
        .alert("图片未保存", isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })) {
            Button("好", role: .cancel) { model.saveError = nil }
        } message: { Text(model.saveError ?? "") }
        .onChange(of: model.selectedSerial) { _, _ in historyExpanded = false }
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
                        Text(model.isConnected ? (model.historyScreens.isEmpty ? "正在发现屏幕…" : "没有活跃屏幕") : "连接设备后，屏幕会出现在这里。")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if !model.historyScreens.isEmpty {
                        Divider().padding(.top, 10).padding(.bottom, 5)
                        DisclosureGroup(isExpanded: $historyExpanded) {
                            VStack(spacing: 5) {
                                HStack {
                                    Text("保留的最后画面").font(.caption2).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button("清除历史") {
                                        model.clearHistory()
                                        historyExpanded = false
                                    }
                                    .font(.caption2)
                                    .buttonStyle(.borderless)
                                    .help("清除本机保留的副屏记录和画面缓存")
                                }
                                .padding(.horizontal, 4).padding(.top, 9).padding(.bottom, 3)
                                ForEach(model.historyScreens) { screen in
                                    screenRow(screen, isHistory: true)
                                }
                            }
                        } label: {
                            Label("历史（\(model.historyScreens.count)）", systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
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

    private func screenRow(_ screen: DisplayPresentation, isHistory: Bool = false) -> some View {
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
                    if isHistory {
                        if let date = screen.lastFrameAt {
                            Text(date.formatted(date: .numeric, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .help("最后画面：\(date.formatted(date: .abbreviated, time: .standard))")
                        } else {
                            Text("未收到画面").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(screen.display.title)，\(screen.status)")
    }

    @ViewBuilder private var stage: some View {
        if model.visibleScreens.isEmpty {
            emptyStage
        } else if model.layout == .single, let screen = model.selectedScreen {
            DisplayPane(model: model, screen: screen, selected: true, retry: { model.retry(screen.id) })
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(stageColor)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(model.visibleScreens) { screen in
                                DisplayPane(model: model, screen: screen, selected: screen.id == model.selectedScreenID, retry: { model.retry(screen.id) })
                                    .frame(width: max(280, (geometry.size.width - 40 - CGFloat(max(0, model.visibleScreens.count - 1)) * 16) / CGFloat(max(1, model.visibleScreens.count))))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectScreen(screen.id) }
                                    .id(screen.id)
                            }
                        }
                        .padding(20)
                        .frame(height: geometry.size.height)
                    }
                    .onChange(of: model.selectedScreenID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: model.selectedScreen?.display.isMain == true ? .leading : .trailing)
                        }
                    }
                }
            }.background(stageColor)
        }
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
            Text("画面静止时仍保持连接")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
    }
}

private struct DisplayPane: View {
    @ObservedObject var model: ViewerModel
    let screen: DisplayPresentation
    let selected: Bool
    let retry: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(screen.display.title).font(.headline)
                if !screen.display.isMain {
                    Image(systemName: "eye").font(.caption).foregroundStyle(.secondary).help("副屏仅观看")
                }
                Spacer(minLength: 5)
                Circle().fill(statusColor(screen)).frame(width: 6, height: 6)
                Text(screen.status).font(.caption).foregroundStyle(.secondary)
                Button {
                    model.setInputFocus(false, for: screen.id)
                    showsDetails.toggle()
                } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("屏幕与连接详情")
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details.padding(20).frame(width: 360) }
            }
            if screen.display.isMain { mainControls }
            ZStack {
                Color.black
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
                    }.foregroundStyle(.white.opacity(0.75)).padding(20)
                }
                if screen.isRetained {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "clock")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(screen.status) · 保留最后画面").font(.caption.weight(.medium))
                                if let date = screen.lastFrameAt {
                                    Text(date.formatted(date: .abbreviated, time: .standard)).font(.caption2)
                                }
                            }
                            Spacer(minLength: 0)
                            if screen.error != nil { Button("重试", action: retry) }
                        }
                        .foregroundStyle(.white).padding(12).background(.black.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                model.focusedScreenID == screen.id ? Color.accentColor : (selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08)),
                lineWidth: model.focusedScreenID == screen.id ? 2 : 1
            ).allowsHitTesting(false))
            if let error = screen.error {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
            } else {
                Text(inputHint)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var inputHint: String {
        if !screen.display.isMain, screen.presence != .active {
            return screen.lastFrameAt == nil ? "该副屏未留下画面" : "历史画面 · 副屏已停止输出"
        }
        if !screen.isLive { return screen.lastFrameAt == nil ? "收到第一帧后显示画面" : "此画面不是当前实时状态" }
        if !screen.display.isMain { return "仅观看 · 点击和按键不会发送到副屏" }
        if !screen.controlReady { return "画面已连接，正在准备主屏控制" }
        if model.focusedScreenID == screen.id { return "键盘正在控制主屏 · ⌘A 全选 · ⌘C / V / X 复制、粘贴、剪切" }
        return "点击画面控制主屏 · 右键返回 · 中键 Home"
    }

    private var mainControls: some View {
        HStack(spacing: 13) {
            Button { model.navigateMain(screen.id, keyCode: 4) } label: { Image(systemName: "chevron.left") }
                .help("返回").disabled(!model.canControl(screen.id))
            Button { model.navigateMain(screen.id, keyCode: 3) } label: { Image(systemName: "house") }
                .help("Home").disabled(!model.canControl(screen.id))
            Button { model.navigateMain(screen.id, keyCode: 187) } label: { Image(systemName: "square.on.square") }
                .help("最近任务").disabled(!model.canControl(screen.id))
            Spacer(minLength: 0)
            if screen.presence == .sleeping {
                Button(action: model.wakeMainDisplay) {
                    Label(model.isWakingMain ? "正在唤醒" : "唤醒主屏", systemImage: "sun.max")
                }
                .disabled(!model.isConnected || model.isWakingMain)
                .help("向手机发送一次唤醒按键；不会自动解锁")
            } else {
                Label(model.focusedScreenID == screen.id ? "键盘已聚焦" : "点击后输入", systemImage: "keyboard")
                    .font(.caption2).foregroundStyle(model.focusedScreenID == screen.id ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .frame(height: 21)
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

private var stageColor: Color { Color(nsColor: .underPageBackgroundColor) }

private func statusColor(_ screen: DisplayPresentation) -> Color {
    if screen.error != nil && screen.presence == .active { return .orange }
    if screen.isLive { return Color(red: 0.14, green: 0.47, blue: 0.4) }
    if screen.presence == .active { return .blue }
    return .secondary
}
