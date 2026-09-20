import AppKit
import Combine
import UniformTypeIdentifiers
import ViewerCore

enum ViewerLayout: String, CaseIterable, Identifiable {
    case single = "单屏"
    case sideBySide = "并排"
    var id: String { rawValue }
}

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
    @Published var layout: ViewerLayout = .sideBySide
    @Published var followNewScreen = true
    @Published private(set) var discoveryError: String?
    @Published private(set) var dependencyError: String?
    @Published private(set) var dependencies: ViewerDependencies?
    @Published var saveError: String?
    @Published private(set) var focusedScreenID: String?
    @Published private(set) var interactionError: String?
    @Published private(set) var isWakingMain = false

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

    func start() {
        guard !started else { return }
        started = true
        configureMonitor()
        diagnostics.start(model: self)
    }

    func shutdown(completion: @escaping () -> Void) {
        shutdownCompletions.append(completion)
        guard !isShuttingDown else { completeShutdownIfReady(); return }
        isShuttingDown = true
        diagnostics.recordLifecycle("shutdown_started")
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
        guard let screen = selectedScreen, let frame = screen.frame else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "display-\(screen.display.displayID)-\(Int((screen.lastFrameAt ?? Date()).timeIntervalSince1970)).png"
        panel.title = "保存当前画面"
        panel.message = screen.isRetained ? "保存的是此屏最后收到的画面。" : "将当前收到的画面保存为 PNG。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ViewerDiagnostics.writePNG(frame, to: url)
        } catch {
            saveError = error.localizedDescription
        }
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
        guard isShuttingDown, streams.isEmpty, retiringStreams.isEmpty else { return }
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
