import AppKit
import Combine
import UniformTypeIdentifiers
import ViewerCore

enum DisplayPresence: String {
    case active, sleeping, removed, disconnected
}

struct DisplayPresentation: Identifiable {
    var id: String { display.id }
    var display: AndroidDisplay
    var presence: DisplayPresence
    var frame: CGImage?
    var lastFrameAt: Date?
    var state: StreamState = .stopped
    var receivedCurrentFrame = false
    var controlReady = false

    var status: String {
        switch presence {
        case .sleeping: return "已休眠"
        case .removed: return "已移除"
        case .disconnected: return "设备已断开"
        case .active:
            if case .failed = state { return "画面连接失败" }
            if receivedCurrentFrame { return "正在显示" }
            if case .stopped = state { return "画面已停止" }
            return "等待画面"
        }
    }

    var error: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var isLive: Bool { presence == .active && receivedCurrentFrame && error == nil }
    var isRetained: Bool { frame != nil && !isLive }
    var sceneItem: DisplaySceneItem {
        DisplaySceneItem(id: id, isMain: display.isMain, isActive: presence == .active)
    }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var selectedSerial: String?
    @Published private(set) var screens: [DisplayPresentation] = []
    @Published var selectedScreenID: String?
    @Published var followNewScreen = true
    @Published private(set) var discoveryError: String?
    @Published private(set) var dependencyError: String?
    @Published private(set) var dependencies: ViewerDependencies?
    @Published var saveError: String?
    @Published private(set) var focusedScreenID: String?
    @Published private(set) var interactionError: String?
    @Published private(set) var isWakingMain = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var recordingRecoveryDirectory: URL?
    @Published private(set) var recordingHistory: [SavedRecording] = []
    @Published var recordingError: String?
    @Published var autoRecordSecondary = UserDefaults.standard.bool(forKey: "autoRecordSecondary") {
        didSet {
            UserDefaults.standard.set(autoRecordSecondary, forKey: "autoRecordSecondary")
            autoRecordingPolicy.reset()
            reconcileAutoRecording()
        }
    }
    @Published private(set) var recordingDirectory: URL = {
        if let path = UserDefaults.standard.string(forKey: "recordingDirectory") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scrcpy Viewer", isDirectory: true)
    }()

    private var recorder: CanvasRecorder?
    private var retiringRecordingParts: [UUID: CanvasRecorder] = [:]
    private var recordingTimer: Timer?
    private var recordingStartedAt: TimeInterval?
    private var recordingGeneration = UUID()
    private var recordingRoster = RecordingRoster()
    private var recordingPanelIsOpen = false
    private var recordingIsAutomatic = false
    private var autoRecordingPolicy = SecondaryAutoRecordingPolicy()
    private var recordingBaseURL: URL?
    private var recordingSessionDirectory: URL?
    private var recordingHasFailed = false
    private var recordingPublicationInProgress = false
    private var recordingPart = 1
    private var recordingPartStartedAt: TimeInterval = 0
    private var recordingLayoutKey = ""
    private var savedRecordingParts: [Int: URL] = [:]
    private var recordingHistoryGeneration = UUID()

    private var monitor: DisplayMonitor?
    private var streams: [String: ScrcpyStream] = [:]
    private var retiringStreams: [UUID: ScrcpyStream] = [:]
    private var generations: [String: UUID] = [:]
    private var pendingClipboard: [String: UUID] = [:]
    private var selectedByDevice: [String: String] = [:]
    private var scenePolicy = DisplayScenePolicy()
    private var explicitlySelectedSerial: String?
    private var monitorGeneration = UUID()
    private var started = false
    private var isShuttingDown = false
    private var shutdownCompletions: [() -> Void] = []
    let diagnostics = ViewerDiagnostics()

    var selectedScreen: DisplayPresentation? {
        screens.first { $0.id == selectedScreenID } ?? currentScreens.first
    }

    var currentScreens: [DisplayPresentation] { screens.filter { $0.display.isMain || $0.presence == .active } }
    var historyScreens: [DisplayPresentation] { screens.filter { !$0.display.isMain && $0.presence != .active } }
    var visibleScreens: [DisplayPresentation] {
        let ids = Set(scenePolicy.visibleIDs(in: screens.map(\.sceneItem)))
        return screens.filter { ids.contains($0.id) }
    }

    var selectedDevice: AndroidDevice? {
        devices.first { $0.serial == selectedSerial }
    }

    var isConnected: Bool { selectedDevice?.isConnected == true }

    var canStartRecording: Bool {
        !isShuttingDown && !isRecording && !isFinishingRecording && !recordingPanelIsOpen
            && currentScreens.contains { $0.frame != nil }
    }
    var canSaveScreenshot: Bool { visibleScreens.contains { $0.frame != nil } }

    func start() {
        guard !started else { return }
        started = true
        refreshRecordingHistory()
        configureMonitor()
        diagnostics.start(model: self)
    }

    func shutdown(completion: @escaping () -> Void) {
        shutdownCompletions.append(completion)
        guard !isShuttingDown else { completeShutdownIfReady(); return }
        isShuttingDown = true
        diagnostics.recordLifecycle("shutdown_started")
        stopRecording(suppressAutomaticRestart: false)
        monitorGeneration = UUID()
        monitor?.stop()
        monitor = nil
        stopAllStreams()
        diagnostics.write(model: self, force: true)
        diagnostics.stop()
        completeShutdownIfReady()
    }

    func refresh() {
        guard !isShuttingDown else { return }
        if monitor == nil {
            configureMonitor()
        } else {
            for screen in screens where screen.presence == .active {
                if screen.error != nil || screen.state == .stopped || streams[screen.id] == nil {
                    stopStream(screen.id)
                    startStream(for: screen.id)
                }
            }
            monitor?.refresh()
        }
    }

    func selectDevice(_ serial: String) {
        guard !isShuttingDown, !serial.isEmpty, serial != selectedSerial else { return }
        if let oldSerial = selectedSerial, let id = selectedScreenID {
            selectedByDevice[oldSerial] = id
        }
        explicitlySelectedSerial = serial
        switchDevice(serial)
        monitor?.selectDevice(serial)
    }

    func selectScreen(_ id: String) {
        guard let screen = screens.first(where: { $0.id == id }) else { return }
        scenePolicy.select(screen.sceneItem)
        setSelection(id)
        diagnostics.write(model: self, force: true)
    }

    private func setSelection(_ id: String?) {
        if scenePolicy.inspectedHistoryID != id { scenePolicy.resetSelection() }
        if let focusedScreenID, focusedScreenID != id { clearInputFocus() }
        selectedScreenID = id
        if let serial = selectedSerial { selectedByDevice[serial] = id }
    }

    func clearHistory() {
        captureRecordingFrame()
        let cleared = scenePolicy.clearHistory(screens.map(\.sceneItem))
        for id in cleared { stopStream(id) }
        screens.removeAll { cleared.contains($0.id) }
        reconcileSelection(newlyActive: [])
        diagnostics.recordLifecycle("local_history_cleared")
        diagnostics.write(model: self, force: true)
    }

    private func reconcileSelection(newlyActive: [String]) {
        let mainInputFocused = focusedScreenID.map { id in
            screens.contains { $0.id == id && $0.display.isMain && $0.presence == .active }
        } ?? false
        let id = scenePolicy.selection(afterUpdating: screens.map(\.sceneItem), previous: selectedScreenID,
            newlyActive: newlyActive, followNew: followNewScreen, mainInputFocused: mainInputFocused)
        if id != selectedScreenID { setSelection(id) }
    }

    func canControl(_ id: String) -> Bool {
        guard !isShuttingDown, let screen = screens.first(where: { $0.id == id }) else { return false }
        return screen.display.isMain && screen.isLive && screen.controlReady && streams[id]?.isControlReady == true
    }

    func setInputFocus(_ focused: Bool, for id: String) {
        if focused {
            guard canControl(id) else { return }
            selectScreen(id)
            if focusedScreenID != id { focusedScreenID = id }
        } else if focusedScreenID == id {
            clearInputFocus()
        }
    }

    private func clearInputFocus() {
        // Explicit selection/device changes revoke input immediately. Discovery
        // preserves a focused main screen instead of interrupting its input.
        focusedScreenID = nil
        if let input = NSApplication.shared.keyWindow?.firstResponder as? MainDisplayNSView {
            input.window?.makeFirstResponder(nil)
        }
    }

    @discardableResult
    func sendInput(_ input: MainDisplayInput, to id: String) -> Bool {
        guard canControl(id), let stream = streams[id] else {
            diagnostics.recordLifecycle("input_\(input.diagnosticName)_rejected")
            return false
        }
        let queued: Bool
        switch input {
        case .touch(let action, let x, let y, let width, let height):
            queued = stream.sendTouch(action: action, x: x, y: y, width: width, height: height,
                                      pressure: action == .up || action == .cancel ? 0 : 1)
        case .scroll(let x, let y, let width, let height, let horizontal, let vertical):
            queued = stream.sendScroll(x: x, y: y, width: width, height: height, horizontal: horizontal, vertical: vertical)
        case .key(let action, let code, let repeats, let meta):
            queued = stream.sendKey(action: action, keyCode: code, repeatCount: repeats, metaState: meta)
        case .pressKey(let code, let meta):
            queued = stream.pressKey(keyCode: code, metaState: meta)
        case .text(let text):
            queued = text.unicodeScalars.allSatisfy { $0.isASCII } ? stream.injectText(text) : stream.setClipboard(text, paste: true)
        case .paste(let text):
            queued = stream.setClipboard(text, paste: true)
        case .copy, .cut:
            pendingClipboard[id] = generations[id]
            if case .copy = input { queued = stream.requestClipboard(.copy) }
            else { queued = stream.requestClipboard(.cut) }
            if !queued { pendingClipboard.removeValue(forKey: id) }
        }
        diagnostics.recordLifecycle("input_\(input.diagnosticName)_\(queued ? "queued" : "rejected")")
        return queued
    }

    func navigateMain(_ id: String, keyCode: UInt32) {
        guard canControl(id) else { return }
        selectScreen(id)
        _ = sendInput(.pressKey(keyCode, meta: 0), to: id)
    }

    func wakeMainDisplay() {
        guard !isShuttingDown, !isWakingMain, isConnected, let serial = selectedSerial, let dependencies else { return }
        isWakingMain = true
        interactionError = nil
        diagnostics.recordLifecycle("explicit_wake_requested")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DeviceActions.wakeMainDisplay(dependencies: dependencies, serial: serial) }
            guard let viewer = self else { return }
            DispatchQueue.main.async {
                viewer.isWakingMain = false
                guard viewer.selectedSerial == serial else { return }
                if case .failure(let error) = result { viewer.interactionError = error.localizedDescription }
                viewer.diagnostics.recordLifecycle("explicit_wake_\(viewer.interactionError == nil ? "completed" : "failed")")
                viewer.monitor?.refresh()
            }
        }
    }

    func retry(_ id: String) {
        guard screens.first(where: { $0.id == id })?.presence == .active else { return }
        stopStream(id)
        startStream(for: id)
    }

    func saveScreenshot() {
        guard canSaveScreenshot else { return }
        let snapshot = recordingSnapshots(visibleScreens)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screens-\(Int(Date().timeIntervalSince1970)).png"
        panel.title = "保存全部屏幕截图"
        panel.message = "主屏和所有副屏紧贴排列，保存为一张 PNG。历史画面会标注时间。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let image = try CanvasComposition.image(screens: snapshot, maximumHeight: 2160, maximumWidth: 8192)
            try ViewerDiagnostics.writePNG(image, to: url)
        } catch { saveError = error.localizedDescription }
    }

    func startRecording() {
        guard canStartRecording else { return }
        clearInputFocus()
        let serial = selectedSerial
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = recordingFilename()
        panel.title = "录制全部屏幕"
        panel.message = "全部屏幕保存为一个 MP4。高度最高 720 像素，12 帧/秒，无音频；新副屏出现前的位置留空，停止后会自动合成。"
        recordingPanelIsOpen = true
        let response = panel.runModal()
        recordingPanelIsOpen = false
        guard response == .OK, let url = panel.url, canStartRecording, serial == selectedSerial else {
            // Cancelling a manual save dialog must not immediately start an automatic recording.
            autoRecordingPolicy.suppressUntilNoSecondary()
            return
        }
        beginRecording(to: url, automatic: false)
    }

    private func beginRecording(to url: URL, automatic: Bool) {
        guard canStartRecording else { return }
        recordingError = nil
        lastRecordingURL = nil
        recordingRecoveryDirectory = nil
        recordingHasFailed = false
        savedRecordingParts = [:]
        recordingElapsed = 0
        recordingPartStartedAt = 0
        recordingPart = 1
        recordingBaseURL = url
        recordingIsAutomatic = automatic
        recordingRoster = RecordingRoster()
        recordingGeneration = UUID()
        let initial = recordingRoster.update(currentIDs: currentScreens.map(\.id), screens: recordingSnapshots(screens))
        do {
            let directory = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).session", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            recordingSessionDirectory = directory
            recorder = try makeRecorder(to: recordingPartURL(in: directory, number: 1), screens: initial)
            recordingLayoutKey = layoutKey(initial)
            recordingStartedAt = ProcessInfo.processInfo.systemUptime
            isRecording = true
            captureRecordingFrame()
            let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureRecordingFrame() }
            }
            recordingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { recordingFailed(error) }
    }

    private func makeRecorder(to url: URL, screens: [RecordingScreen]) throws -> CanvasRecorder {
        let generation = recordingGeneration
        return try CanvasRecorder(outputURL: url, configuration: .compact(for: screens), onFailure: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.recordingFailed(error)
            }
        })
    }

    func stopRecording() { stopRecording(suppressAutomaticRestart: true) }

    private func stopRecording(suppressAutomaticRestart: Bool, captureLastFrame: Bool = true) {
        if suppressAutomaticRestart { autoRecordingPolicy.suppressUntilNoSecondary() }
        guard isRecording else { return }
        if captureLastFrame { captureRecordingFrame() }
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        isRecording = false
        isFinishingRecording = true
        if let recorder {
            self.recorder = nil
            finishPart(recorder, number: recordingPart, duration: recordingElapsed - recordingPartStartedAt)
        }
        completeRecordingIfReady()
    }

    private func finishPart(_ recorder: CanvasRecorder, number: Int, duration: TimeInterval) {
        let id = UUID(), generation = recordingGeneration
        retiringRecordingParts[id] = recorder
        recorder.finish(at: max(0, duration)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.recordingGeneration == generation else { return }
                self.retiringRecordingParts.removeValue(forKey: id)
                switch result {
                case .success(let url):
                    self.savedRecordingParts[number] = url
                case .failure(let error): self.recordingFailed(error)
                }
                self.completeRecordingIfReady()
            }
        }
    }

    private func completeRecordingIfReady() {
        guard isFinishingRecording, !isRecording, retiringRecordingParts.isEmpty,
              !recordingPublicationInProgress else { return }
        recordingRoster = RecordingRoster()
        guard !recordingHasFailed, let output = recordingBaseURL,
              savedRecordingParts.count == recordingPart else {
            recordingError = recordingError ?? "录屏未完整保存，已保留可恢复的画面。"
            finishRecordingPublication(nil)
            return
        }
        recordingPublicationInProgress = true
        let parts = savedRecordingParts.keys.sorted().compactMap { savedRecordingParts[$0] }
        Task { [self] in
            do {
                let url = try await RecordingFinalizer.publish(parts: parts, to: output)
                finishRecordingPublication(url)
            } catch {
                recordingError = error.localizedDescription
                finishRecordingPublication(nil)
            }
        }
    }

    private func finishRecordingPublication(_ url: URL?) {
        if let url {
            lastRecordingURL = url
            rememberRecording(url)
            if let directory = recordingSessionDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        } else {
            autoRecordingPolicy.suppressUntilNoSecondary()
            preserveUnfinishedRecording()
        }
        recordingSessionDirectory = nil
        savedRecordingParts = [:]
        recordingPublicationInProgress = false
        isFinishingRecording = false
        completeShutdownIfReady()
        reconcileAutoRecording()
    }

    private func preserveUnfinishedRecording() {
        guard let directory = recordingSessionDirectory else { return }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        // Make recovery files visible without publishing an incomplete video as a success.
        let name = (recordingBaseURL?.deletingPathExtension().lastPathComponent ?? "recording")
            + "-unfinished-" + UUID().uuidString.prefix(6)
        let visible = directory.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: directory, to: visible)
            recordingRecoveryDirectory = visible
        } catch {
            recordingRecoveryDirectory = directory
        }
        if let path = recordingRecoveryDirectory?.path {
            recordingError = (recordingError ?? "录屏未保存") + "\n已录制的部分保留在：\(path)"
        }
    }

    private func recordingFailed(_ error: Error) {
        if !recordingHasFailed { recordingError = error.localizedDescription }
        recordingHasFailed = true
        autoRecordingPolicy.suppressUntilNoSecondary()
        stopRecording(suppressAutomaticRestart: true, captureLastFrame: false)
        if !isRecording && !isFinishingRecording && recordingSessionDirectory != nil {
            isFinishingRecording = true
            completeRecordingIfReady()
        }
    }

    func revealRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealUnfinishedRecording() {
        guard let directory = recordingRecoveryDirectory else { return }
        NSWorkspace.shared.open(directory)
    }

    func chooseRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择自动录屏目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingDirectory
        recordingPanelIsOpen = true
        let response = panel.runModal()
        recordingPanelIsOpen = false
        if response == .OK, let url = panel.url {
            recordingDirectory = url
            UserDefaults.standard.set(url.path, forKey: "recordingDirectory")
            refreshRecordingHistory()
        }
        reconcileAutoRecording()
    }

    func revealRecordingDirectory() {
        do {
            try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recordingDirectory)
        } catch { recordingError = error.localizedDescription }
    }

    func refreshRecordingHistory() {
        let generation = UUID()
        recordingHistoryGeneration = generation
        let known = (UserDefaults.standard.stringArray(forKey: "recordingHistoryPaths") ?? [])
            .map { URL(fileURLWithPath: $0) }
        let directory = recordingDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = RecordingHistoryCatalog.list(recordedURLs: known, directory: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingHistoryGeneration == generation else { return }
                self.recordingHistory = entries
            }
        }
    }

    @discardableResult
    func trashRecording(_ recording: SavedRecording) throws -> URL? {
        guard recordingHistory.contains(where: { $0.id == recording.id }) else { return nil }
        var trashedURL: NSURL?
        do {
            let values = try recording.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NSError(domain: "ScrcpyViewer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "这条录屏已变更，请刷新列表后重试。"])
            }
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: &trashedURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            // An externally removed file only needs its stale history entry cleared.
        }
        let paths = (UserDefaults.standard.stringArray(forKey: "recordingHistoryPaths") ?? [])
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.path != recording.id }
        UserDefaults.standard.set(paths, forKey: "recordingHistoryPaths")
        recordingHistory.removeAll { $0.id == recording.id }
        if lastRecordingURL?.standardizedFileURL.path == recording.id { lastRecordingURL = nil }
        // A fresh generation prevents an in-flight catalog read from restoring a deleted row.
        refreshRecordingHistory()
        return trashedURL as URL?
    }

    private func rememberRecording(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: "recordingHistoryPaths") ?? []
        if !paths.contains(path) {
            paths.append(path)
            UserDefaults.standard.set(paths, forKey: "recordingHistoryPaths")
        }
        refreshRecordingHistory()
    }

    private func recordingFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "screens-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).mp4"
    }

    private func reconcileAutoRecording() {
        guard !isShuttingDown, !recordingPanelIsOpen else { return }
        let action = autoRecordingPolicy.action(enabled: autoRecordSecondary && isConnected,
            hasSecondary: screens.contains { !$0.display.isMain && $0.presence == .active },
            hasFrame: currentScreens.contains { $0.frame != nil }, recordingIsAutomatic: recordingIsAutomatic,
            isRecording: isRecording, isFinishing: isFinishingRecording)
        switch action {
        case .none: break
        case .stop: stopRecording(suppressAutomaticRestart: false)
        case .start:
            do {
                try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
                beginRecording(to: recordingDirectory.appendingPathComponent(recordingFilename()), automatic: true)
            } catch { recordingFailed(error) }
        }
    }

    private func recordingSnapshots(_ presentations: [DisplayPresentation]) -> [RecordingScreen] {
        presentations.map { screen in
            RecordingScreen(id: screen.id, title: screen.display.title, image: screen.frame,
                sourceSize: CGSize(width: max(1, screen.display.width), height: max(1, screen.display.height)),
                status: screen.status, lastFrameAt: screen.lastFrameAt, isLive: screen.isLive)
        }
    }

    private func layoutKey(_ screens: [RecordingScreen]) -> String {
        let size = CanvasComposition.size(for: screens)
        return "\(Int(size.width))x\(Int(size.height)):" + screens.map { screen in
            let width = CGFloat(screen.image?.width ?? Int(screen.sourceSize.width))
            let height = CGFloat(screen.image?.height ?? Int(screen.sourceSize.height))
            return "\(screen.id):\(Int((width / max(1, height) * 10_000).rounded()))"
        }.joined(separator: ",")
    }

    private func recordingPartURL(in directory: URL, number: Int) -> URL {
        directory.appendingPathComponent(String(format: "part-%04d.mp4", number))
    }

    private func captureRecordingFrame() {
        guard isRecording, let currentRecorder = recorder, let recordingStartedAt else { return }
        recordingElapsed = max(0, ProcessInfo.processInfo.systemUptime - recordingStartedAt)
        let included = recordingRoster.update(currentIDs: currentScreens.map(\.id), screens: recordingSnapshots(screens))
        let nextKey = layoutKey(included)
        if nextKey != recordingLayoutKey, let directory = recordingSessionDirectory {
            let nextPart = recordingPart + 1
            do {
                let next = try makeRecorder(to: recordingPartURL(in: directory, number: nextPart), screens: included)
                // Hold the previous layout through the boundary, then start the new
                // exact-aspect segment without waiting for disk finalization.
                finishPart(currentRecorder, number: recordingPart, duration: recordingElapsed - recordingPartStartedAt)
                recorder = next
                recordingPart = nextPart
                recordingPartStartedAt = recordingElapsed
                recordingLayoutKey = nextKey
            } catch { recordingFailed(error); return }
        }
        recorder?.append(screens: included, at: recordingElapsed - recordingPartStartedAt)
    }

    private func configureMonitor() {
        monitorGeneration = UUID()
        let generation = monitorGeneration
        do {
            let dependencies = try DependencyResolver.resolve()
            self.dependencies = dependencies
            dependencyError = nil
            let monitor = DisplayMonitor(dependencies: dependencies) { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self, self.monitorGeneration == generation else { return }
                    self.apply(snapshot)
                }
            }
            self.monitor = monitor
            if let serial = selectedSerial { monitor.selectDevice(serial) }
            monitor.start()
        } catch {
            dependencyError = error.localizedDescription
            diagnostics.write(model: self, force: true)
        }
    }

    private func switchDevice(_ serial: String?) {
        stopRecording(suppressAutomaticRestart: false)
        autoRecordingPolicy.reset()
        clearInputFocus()
        stopAllStreams()
        screens.removeAll()
        scenePolicy.resetSelection()
        selectedSerial = serial
        selectedScreenID = serial.flatMap { selectedByDevice[$0] }
        discoveryError = nil
        interactionError = nil
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        defer { reconcileAutoRecording() }
        devices = snapshot.devices
        // A snapshot produced before the picker change must not revive old-device streams.
        if let requested = explicitlySelectedSerial, snapshot.selectedSerial != requested { return }
        if selectedSerial != snapshot.selectedSerial { switchDevice(snapshot.selectedSerial) }
        discoveryError = snapshot.error
        guard isConnected else {
            for index in screens.indices {
                stopStream(screens[index].id)
                screens[index].presence = .disconnected
                screens[index].receivedCurrentFrame = false
            }
            reconcileSelection(newlyActive: [])
            diagnostics.write(model: self, force: true)
            return
        }

        // On a discovery error keep existing metadata: a failed query is not evidence of removal.
        guard snapshot.error == nil else {
            diagnostics.write(model: self, force: true)
            return
        }
        let displays = snapshot.displays.filter { !$0.isCaptureMirror && $0.serial == selectedSerial }
        let currentIDs = Set(displays.map(\.id))
        for index in screens.indices where !currentIDs.contains(screens[index].id) {
            stopStream(screens[index].id)
            screens[index].presence = .removed
            screens[index].receivedCurrentFrame = false
        }
        var newlyActive: [String] = []
        for display in displays.sorted(by: { $0.displayID < $1.displayID }) {
            guard scenePolicy.accept(DisplaySceneItem(id: display.id, isMain: display.isMain, isActive: display.isActive)) else { continue }
            let presence: DisplayPresence = display.isActive ? .active : .sleeping
            if let index = screens.firstIndex(where: { $0.id == display.id }) {
                let wasActive = screens[index].presence == .active
                screens[index].display = display
                screens[index].presence = presence
                if !display.isActive {
                    stopStream(display.id)
                    screens[index].receivedCurrentFrame = false
                } else if !wasActive {
                    newlyActive.append(display.id)
                    startStream(for: display.id)
                }
            } else {
                screens.append(DisplayPresentation(display: display, presence: presence))
                if display.isActive {
                    newlyActive.append(display.id)
                    startStream(for: display.id)
                }
            }
        }
        screens.sort { lhs, rhs in
            if lhs.display.isMain != rhs.display.isMain { return lhs.display.isMain }
            return lhs.display.displayID < rhs.display.displayID
        }
        // Let an active recording retain the dated last frame before dropping
        // removed secondary displays from the viewer's cache.
        captureRecordingFrame()
        screens.removeAll { !$0.display.isMain && $0.presence == .removed }
        reconcileSelection(newlyActive: newlyActive)
        diagnostics.write(model: self, force: true)
    }

    private func startStream(for id: String) {
        guard !isShuttingDown, streams[id] == nil, let dependencies,
              let index = screens.firstIndex(where: { $0.id == id }),
              screens[index].presence == .active else { return }
        let display = screens[index].display
        let generation = UUID()
        generations[id] = generation
        screens[index].state = .starting
        screens[index].receivedCurrentFrame = false
        let mailbox = FrameMailbox()
        let stream = ScrcpyStream(
            dependencies: dependencies, serial: display.serial, displayID: display.displayID,
            onFrame: { [weak self] frame in
                guard mailbox.offer(frame) else { return }
                DispatchQueue.main.async {
                    guard let latest = mailbox.take(),
                          let self, self.generations[id] == generation,
                          let index = self.screens.firstIndex(where: { $0.id == id }),
                          self.screens[index].presence == .active else { return }
                    self.screens[index].frame = latest.image
                    self.screens[index].lastFrameAt = latest.receivedAt
                    self.screens[index].receivedCurrentFrame = true
                    self.screens[index].state = .streaming
                    self.screens[index].controlReady = display.isMain && self.streams[id]?.isControlReady == true
                    self.reconcileAutoRecording()
                    self.diagnostics.write(model: self)
                }
            },
            onState: { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.generations[id] == generation,
                          let index = self.screens.firstIndex(where: { $0.id == id }) else { return }
                    self.screens[index].state = state
                    switch state {
                    case .failed, .stopped:
                        self.screens[index].receivedCurrentFrame = false
                        self.screens[index].controlReady = false
                        if self.focusedScreenID == id { self.focusedScreenID = nil }
                    case .starting: self.screens[index].controlReady = false
                    case .streaming:
                        self.screens[index].controlReady = display.isMain && self.streams[id]?.isControlReady == true
                    }
                    self.diagnostics.write(model: self, force: true)
                }
            },
            onClipboard: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, display.isMain, self.generations[id] == generation,
                          self.pendingClipboard[id] == generation else { return }
                    self.pendingClipboard.removeValue(forKey: id)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.diagnostics.recordLifecycle("clipboard_copy_received")
                }
            }
        )
        streams[id] = stream
        stream.start()
    }

    private func stopStream(_ id: String) {
        if focusedScreenID == id { clearInputFocus() }
        pendingClipboard.removeValue(forKey: id)
        generations.removeValue(forKey: id)
        if let stream = streams.removeValue(forKey: id) {
            let retirementID = UUID()
            retiringStreams[retirementID] = stream
            stream.stop { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.retiringStreams.removeValue(forKey: retirementID)
                    self.completeShutdownIfReady()
                }
            }
        }
        if let index = screens.firstIndex(where: { $0.id == id }) {
            screens[index].state = .stopped
            screens[index].receivedCurrentFrame = false
            screens[index].controlReady = false
        }
    }

    private func stopAllStreams() {
        generations.removeAll()
        for id in Array(streams.keys) { stopStream(id) }
        for index in screens.indices {
            screens[index].state = .stopped
            screens[index].receivedCurrentFrame = false
            screens[index].controlReady = false
        }
    }

    private func completeShutdownIfReady() {
        guard isShuttingDown, streams.isEmpty, retiringStreams.isEmpty,
              !isRecording, !isFinishingRecording else { return }
        let completions = shutdownCompletions
        shutdownCompletions.removeAll()
        guard !completions.isEmpty else { return }
        diagnostics.recordLifecycle("shutdown_ready")
        // NSApplication must receive terminateLater before we reply to its termination request.
        DispatchQueue.main.async { completions.forEach { $0() } }
    }
}

/// One pending decoded image per stream, even while the main thread is busy resizing or saving PNGs.
private final class FrameMailbox {
    struct Frame {
        let image: CGImage
        let receivedAt: Date
    }
    private let lock = NSLock()
    private var latest: Frame?
    private var scheduled = false

    func offer(_ image: CGImage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = Frame(image: image, receivedAt: Date())
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        let frame = latest
        latest = nil
        scheduled = false
        return frame
    }
}
