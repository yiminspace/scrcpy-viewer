import AppKit
import Foundation

/// Explicit opt-in only. Normal use never writes screen content or device metadata to disk.
@MainActor
final class ViewerDiagnostics {
    let directory: URL?
    let quitAfter: TimeInterval?
    private var timer: Timer?
    private var quitTimer: Timer?
    private var inputTimer: Timer?
    private let inputFile: URL?
    private var inputOffset = 0
    private var inputBuffer = Data()
    private var consumedInputIDs = Set<String>()
    private var lastWrite = Date.distantPast
    private var lastFrames: [String: Date] = [:]
    private weak var model: ViewerModel?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let path = argument("--diagnostics-dir") ?? ProcessInfo.processInfo.environment["SCRCPY_VIEWER_DIAGNOSTICS_DIR"]
        directory = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        inputFile = directory == nil ? nil : argument("--diagnostic-input").map { URL(fileURLWithPath: $0) }
        quitAfter = argument("--quit-after").flatMap(TimeInterval.init)
    }

    func start(model: ViewerModel) {
        self.model = model
        if directory != nil {
            write(model: model, force: true)
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak model] _ in
                guard let diagnostics = self, let viewer = model else { return }
                Task { @MainActor in
                    diagnostics.write(model: viewer, force: true)
                    diagnostics.writeWindow()
                }
            }
        }
        if let quitAfter, quitAfter > 0 {
            // Initiate AppKit termination from the run loop, not inside a GCD main block.
            // terminateLater may enter a nested loop; the cleanup reply must still be able
            // to execute on the main dispatch queue while that loop is running.
            let timer = Timer(timeInterval: quitAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recordLifecycle("quit_requested")
                    NSApplication.shared.terminate(nil)
                }
            }
            quitTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if inputFile != nil {
            inputTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let diagnostics = self else { return }
                Task { @MainActor in diagnostics.processDiagnosticInput() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        quitTimer?.invalidate()
        quitTimer = nil
        inputTimer?.invalidate()
        inputTimer = nil
        model = nil
    }

    func recordLifecycle(_ event: String) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("lifecycle.jsonl")
            var data = try JSONSerialization.data(withJSONObject: [
                "event": event,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ], options: [.sortedKeys])
            data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            }
        } catch {
            fputs("ScrcpyViewer diagnostics: \(error.localizedDescription)\n", stderr)
        }
    }

    func write(model: ViewerModel, force: Bool = false) {
        guard let directory, force || Date().timeIntervalSince(lastWrite) > 1 else { return }
        lastWrite = Date()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let displays: [[String: Any]] = try model.screens.map { screen in
                let filename = "display-\(screen.display.displayID).png"
                if let frame = screen.frame, let date = screen.lastFrameAt, lastFrames[screen.id] != date {
                    try Self.writePNG(frame, to: directory.appendingPathComponent(filename))
                    lastFrames[screen.id] = date
                }
                var result: [String: Any] = [
                    "id": screen.id, "displayID": screen.display.displayID,
                    "name": screen.display.name, "owner": screen.display.owner,
                    "uniqueID": screen.display.uniqueID, "sourceState": screen.display.state,
                    "width": screen.display.width, "height": screen.display.height,
                    "presence": screen.presence.rawValue, "status": screen.status,
                    "isLive": screen.isLive, "hasFrame": screen.frame != nil,
                    "controlReady": screen.controlReady,
                    "inputFocused": model.focusedScreenID == screen.id,
                    "selected": screen.id == model.selectedScreenID,
                ]
                if let date = screen.lastFrameAt { result["lastFrameAt"] = formatter.string(from: date) }
                if screen.frame != nil { result["frameFile"] = filename }
                if let frame = screen.frame { result["frameWidth"] = frame.width; result["frameHeight"] = frame.height }
                if let error = screen.error { result["error"] = error }
                return result
            }
            var state: [String: Any] = [
                "updatedAt": formatter.string(from: Date()), "mainInputSupported": true, "secondaryReadOnly": true,
                "layout": "并排", "followNewScreen": model.followNewScreen,
                "isRecording": model.isRecording, "isFinishingRecording": model.isFinishingRecording,
                "connected": model.isConnected, "displays": displays,
                "currentDisplayIDs": model.currentScreens.map { $0.display.displayID },
                "historyDisplayIDs": model.historyScreens.map { $0.display.displayID },
                "visibleDisplayIDs": model.visibleScreens.map { $0.display.displayID },
                "devices": model.devices.map { ["serial": $0.serial, "model": $0.model, "state": $0.connectionState] },
            ]
            if let serial = model.selectedSerial { state["selectedSerial"] = serial }
            if let view = mainInputView() {
                state["inputGeometry"] = [
                    "displayID": 0, "enabled": view.inputEnabled,
                    "focused": view.window?.firstResponder === view,
                    "bounds": rectDictionary(view.bounds), "contentRect": rectDictionary(view.imageRect),
                    "frameWidth": view.frameSize.width, "frameHeight": view.frameSize.height,
                    "acceptedInputMessages": view.acceptedInputCount,
                ] as [String: Any]
            }
            if let error = model.dependencyError ?? model.discoveryError { state["error"] = error }
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            // Diagnostics are deliberately nonfatal, and never print screen data.
            fputs("ScrcpyViewer diagnostics: \(error.localizedDescription)\n", stderr)
        }
    }

    private func mainInputView() -> MainDisplayNSView? {
        func find(_ view: NSView) -> MainDisplayNSView? {
            if let input = view as? MainDisplayNSView { return input }
            return view.subviews.lazy.compactMap(find).first
        }
        for window in NSApplication.shared.windows where window.isVisible && window.canBecomeMain {
            if let content = window.contentView, let view = find(content) { return view }
        }
        return nil
    }

    private func rectDictionary(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    /// Opt-in QA driver: dispatches through the same NSView handlers as actual
    /// local input. It never calls the model or socket directly, and is not enabled
    /// merely by turning on screenshot diagnostics.
    private func processDiagnosticInput() {
        guard let inputFile, let data = try? Data(contentsOf: inputFile), data.count <= 1_048_576 else { return }
        if data.count < inputOffset { inputOffset = 0; inputBuffer.removeAll() }
        inputBuffer.append(data.suffix(from: inputOffset))
        inputOffset = data.count
        while let newline = inputBuffer.firstIndex(of: 10) {
            let line = Data(inputBuffer[..<newline])
            inputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let command = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = command["id"] as? String, !id.isEmpty else { continue }
            guard consumedInputIDs.insert(id).inserted else { continue }
            executeDiagnosticInput(command, id: id)
        }
    }

    private func executeDiagnosticInput(_ command: [String: Any], id: String) {
        let type = command["type"] as? String ?? ""
        guard (command["displayID"] as? Int ?? 0) == 0 else {
            recordInputResult(id: id, type: type, accepted: false, messages: 0, reason: "secondary_display_read_only")
            return
        }
        guard let view = mainInputView(), let window = view.window, view.inputEnabled else {
            recordInputResult(id: id, type: type, accepted: false, messages: 0, reason: "main_input_unavailable")
            return
        }
        let before = view.acceptedInputCount
        let rect = view.imageRect
        let x = command["x"] as? Double ?? 0.5
        let y = command["y"] as? Double ?? 0.5
        let point = command["space"] as? String == "view" ? CGPoint(x: x, y: y)
            : CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        let windowPoint = view.convert(point, to: nil)
        let flags = diagnosticModifiers(command["modifiers"] as? [String] ?? [])
        let mouseTypes: [String: NSEvent.EventType] = [
            "mouseDown": .leftMouseDown, "mouseUp": .leftMouseUp, "mouseDragged": .leftMouseDragged,
            "rightMouseDown": .rightMouseDown, "otherMouseDown": .otherMouseDown,
        ]
        if let eventType = mouseTypes[type], let event = NSEvent.mouseEvent(
            with: eventType, location: windowPoint, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == "mouseUp" ? 0 : 1
        ) {
            switch type {
            case "mouseDown": view.mouseDown(with: event)
            case "mouseUp": view.mouseUp(with: event)
            case "mouseDragged": view.mouseDragged(with: event)
            case "rightMouseDown": view.rightMouseDown(with: event)
            default: view.diagnosticMiddleMouseDown(pointInView: point)
            }
        } else if type == "keyDown" || type == "keyUp" {
            let characters = command["characters"] as? String ?? ""
            let code = UInt16(clamping: command["keyCode"] as? Int ?? 0)
            if let event = NSEvent.keyEvent(with: type == "keyDown" ? .keyDown : .keyUp, location: .zero,
                                           modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: command["repeat"] as? Bool ?? false, keyCode: code) {
                if type == "keyDown" { view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
        } else if type == "text" {
            view.insertText(command["text"] as? String ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if type == "scroll" {
            view.diagnosticScroll(pointInView: point, deltaX: command["dx"] as? Double ?? 0, deltaY: command["dy"] as? Double ?? 0)
        } else {
            recordInputResult(id: id, type: type, accepted: false, messages: 0, reason: "unknown_event_type")
            return
        }
        let messages = view.acceptedInputCount - before
        recordInputResult(id: id, type: type, accepted: messages > 0, messages: messages,
                          reason: messages > 0 ? "queued_by_nsview_handler" : "outside_image_unfocused_or_not_ready")
        if let model { write(model: model, force: true) }
    }

    private func diagnosticModifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "command": flags.insert(.command)
            case "control": flags.insert(.control)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            default: break
            }
        }
        return flags
    }

    private func recordInputResult(id: String, type: String, accepted: Bool, messages: Int, reason: String) {
        guard let directory else { return }
        let result: [String: Any] = [
            "id": id, "type": type, "status": accepted ? "accepted" : "ignored",
            "queuedMessages": messages, "reason": reason,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "source": "diagnostic_nsview",
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = directory.appendingPathComponent("input-results.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic); return }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
    }

    private func writeWindow() {
        guard let directory,
              let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let contentView = window.contentView else { return }
        // The root frame view includes our own title bar and toolbar. This does not
        // access screen pixels or require Screen Recording permission.
        var view = contentView
        while let parent = view.superview { view = parent }
        view.layoutSubtreeIfNeeded()
        guard
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // NSVisualEffectView's desktop backdrop is not part of the view tree. Give
        // transparent material a neutral window background in the diagnostic image.
        let color = window.backgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        context.setFillColor(color.cgColor)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let composite = context.makeImage() else { return }
        try? Self.writePNG(composite, to: directory.appendingPathComponent("window.png"))
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScrcpyViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图片。"])
        }
        try data.write(to: url, options: .atomic)
    }
}
