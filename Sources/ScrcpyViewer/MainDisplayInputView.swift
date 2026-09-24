import AppKit
import SwiftUI
import ViewerCore

enum MainDisplayInput {
    case touch(ScrcpyTouchAction, x: Int, y: Int, width: Int, height: Int)
    case scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Float, vertical: Float)
    case key(ScrcpyKeyAction, code: UInt32, repeatCount: UInt32, meta: UInt32)
    case pressKey(UInt32, meta: UInt32)
    case text(String)
    case paste(String)
    case copy
    case cut

    var diagnosticName: String {
        switch self {
        case .touch(let action, _, _, _, _): return "touch_\(action.rawValue)"
        case .scroll: return "scroll"
        case .key(let action, _, _, _): return "key_\(action.rawValue)"
        case .pressKey: return "key_press"
        case .text: return "text_commit"
        case .paste: return "paste"
        case .copy: return "copy"
        case .cut: return "cut"
        }
    }
}

struct MainDisplayInputView: NSViewRepresentable {
    let frameSize: CGSize
    let enabled: Bool
    let focused: Bool
    let send: (MainDisplayInput) -> Bool
    let focusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MainDisplayNSView {
        let view = MainDisplayNSView()
        view.focusRingType = .none
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MainDisplayNSView, context: Context) {
        view.send = { [weak view] input in
            let queued = send(input)
            if queued { view?.acceptedInputCount += 1 }
            return queued
        }
        view.focusChanged = focusChanged
        view.configure(frameSize: frameSize, enabled: enabled, focused: focused)
    }

    static func dismantleNSView(_ view: MainDisplayNSView, coordinator: ()) {
        view.cancelInput()
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
}

/// Transparent event layer over the aspect-fit main-display image. It never exists for a secondary display.
final class MainDisplayNSView: NSView, NSTextInputClient {
    var send: (MainDisplayInput) -> Bool = { _ in false }
    var focusChanged: (Bool) -> Void = { _ in }
    private(set) var frameSize = CGSize.zero
    private(set) var inputEnabled = false
    fileprivate(set) var acceptedInputCount = 0
    private var touchPoint: CGPoint?
    private var touchFrameSize = CGSize.zero
    private var heldKeys: [UInt16: (code: UInt32, meta: UInt32, repeats: UInt32)] = [:]
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var candidatePoint = CGPoint.zero
    private var resignObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { inputEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { inputEnabled }

    var imageRect: CGRect {
        InputGeometry.contentRect(viewSize: bounds.size, frameSize: frameSize) ?? .zero
    }

    func configure(frameSize: CGSize, enabled: Bool, focused: Bool) {
        if self.frameSize != frameSize {
            // A rotation changes the protocol coordinate space. End the old gesture
            // using the new dimensions; no subsequent drag may reuse the old geometry.
            if let point = touchPoint, touchFrameSize.width > 0, touchFrameSize.height > 0 {
                touchPoint = CGPoint(x: point.x / touchFrameSize.width * frameSize.width,
                                     y: point.y / touchFrameSize.height * frameSize.height)
                touchFrameSize = frameSize
            }
            cancelInput()
            self.frameSize = frameSize
        }
        if inputEnabled && !enabled { cancelInput() }
        inputEnabled = enabled
        if (!enabled || !focused), window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { cancelInput(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cancelInput()
            if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
        }
    }

    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard inputEnabled, imageRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func becomeFirstResponder() -> Bool {
        guard inputEnabled else { return false }
        focusChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelInput()
        focusChanged(false)
        return true
    }

    private func pixelPoint(for event: NSEvent) -> CGPoint? {
        pixelPoint(at: convert(event.locationInWindow, from: nil))
    }

    private func pixelPoint(at point: CGPoint) -> CGPoint? {
        guard inputEnabled else { return nil }
        // NSView points already account for Retina. Only scale once to decoded pixels.
        guard let mapped = InputGeometry.map(point: point, viewSize: bounds.size,
                                             frameWidth: Int(frameSize.width), frameHeight: Int(frameSize.height)) else { return nil }
        return CGPoint(x: mapped.x, y: mapped.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = pixelPoint(for: event) else { return }
        window?.makeFirstResponder(self)
        candidatePoint = convert(event.locationInWindow, from: nil)
        cancelTouch()
        touchFrameSize = frameSize
        if sendTouch(.down, point: point, size: frameSize) { touchPoint = point }
    }

    override func mouseDragged(with event: NSEvent) {
        guard touchPoint != nil, let point = pixelPoint(for: event) else { return }
        if sendTouch(.move, point: point, size: touchFrameSize) { touchPoint = point }
    }

    override func mouseUp(with event: NSEvent) {
        guard let previous = touchPoint else { return }
        // An up outside the image still releases the last in-bounds touch.
        _ = sendTouch(.up, point: pixelPoint(for: event) ?? previous, size: touchFrameSize)
        touchPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard pixelPoint(for: event) != nil else { return }
        window?.makeFirstResponder(self)
        _ = send(.pressKey(4, meta: 0))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        middleMouseDown(at: convert(event.locationInWindow, from: nil))
    }

    private func middleMouseDown(at point: CGPoint) {
        guard pixelPoint(at: point) != nil else { return }
        window?.makeFirstResponder(self)
        _ = send(.pressKey(3, meta: 0))
    }

    // NSEvent.mouseEvent(.otherMouseDown) does not retain buttonNumber=2 on all
    // macOS versions. QA enters the same validated middle-button handler here.
    func diagnosticMiddleMouseDown(pointInView: CGPoint) {
        middleMouseDown(at: pointInView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = pixelPoint(for: event) else { return }
        scroll(at: point, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
               precise: event.hasPreciseScrollingDeltas)
    }

    private func scroll(at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        let divisor: CGFloat = precise ? 40 : 3
        let horizontal = Float(max(-1, min(1, deltaX / divisor)))
        let vertical = Float(max(-1, min(1, deltaY / divisor)))
        _ = send(.scroll(x: Int(point.x), y: Int(point.y), width: Int(frameSize.width), height: Int(frameSize.height),
                         horizontal: horizontal, vertical: vertical))
    }

    // Used only by the explicit diagnostic input driver. Native wheel events use
    // the same point validation, delta conversion and send path above.
    func diagnosticScroll(pointInView: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        guard inputEnabled,
              let point = InputGeometry.map(point: pointInView, viewSize: bounds.size,
                                             frameWidth: Int(frameSize.width), frameHeight: Int(frameSize.height)) else { return }
        scroll(at: CGPoint(x: point.x, y: point.y), deltaX: deltaX, deltaY: deltaY, precise: false)
    }

    private func sendTouch(_ action: ScrcpyTouchAction, point: CGPoint, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return send(.touch(action, x: max(0, min(Int(size.width) - 1, Int(point.x))),
                           y: max(0, min(Int(size.height) - 1, Int(point.y))),
                           width: Int(size.width), height: Int(size.height)))
    }

    private func cancelTouch() {
        if let point = touchPoint { _ = sendTouch(.cancel, point: point, size: touchFrameSize) }
        touchPoint = nil
    }

    func cancelInput() {
        cancelTouch()
        for key in heldKeys.values { _ = send(.key(.up, code: key.code, repeatCount: 0, meta: key.meta)) }
        heldKeys.removeAll()
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        inputContext?.discardMarkedText()
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if handleCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "a": _ = send(.pressKey(29, meta: 0x1000))
        case "c": _ = send(.copy)
        case "x": _ = send(.cut)
        case "v": pasteFromMac()
        default: return false // Cmd+Q/W/H/M and the app's screenshot shortcut remain native.
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard inputEnabled, window?.firstResponder === self else { return }
        if handleCommand(event) { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if !hasMarkedText(), let code = physicalKey(event) {
            let repeats = event.isARepeat ? (heldKeys[event.keyCode]?.repeats ?? 0) + 1 : 0
            let meta = androidMeta(event.modifierFlags)
            if send(.key(.down, code: code, repeatCount: repeats, meta: meta)) {
                heldKeys[event.keyCode] = (code: code, meta: meta, repeats: repeats)
            }
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard let key = heldKeys.removeValue(forKey: event.keyCode) else { return }
        _ = send(.key(.up, code: key.code, repeatCount: 0, meta: androidMeta(event.modifierFlags)))
    }

    private func physicalKey(_ event: NSEvent) -> UInt32? {
        let special: [UInt16: UInt32] = [36: 66, 76: 66, 48: 61, 51: 67, 117: 112, 53: 4,
                                         123: 21, 124: 22, 125: 20, 126: 19,
                                         115: 122, 119: 123, 116: 92, 121: 93]
        if let code = special[event.keyCode] { return code }
        if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            if (97...122).contains(scalar.value) { return scalar.value - 97 + 29 }
            if (48...57).contains(scalar.value) { return scalar.value - 48 + 7 }
        }
        return nil
    }

    private func androidMeta(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.shift) { meta |= 0x1 }
        if flags.contains(.option) { meta |= 0x2 }
        if flags.contains(.control) { meta |= 0x1000 }
        if flags.contains(.capsLock) { meta |= 0x100000 }
        return meta
    }

    @objc func copy(_ sender: Any?) { if inputEnabled { _ = send(.copy) } }
    @objc func cut(_ sender: Any?) { if inputEnabled { _ = send(.cut) } }
    @objc func paste(_ sender: Any?) { if inputEnabled { pasteFromMac() } }
    override func selectAll(_ sender: Any?) { if inputEnabled { _ = send(.pressKey(29, meta: 0x1000)) } }

    private func pasteFromMac() {
        if let text = NSPasteboard.general.string(forType: .string) { _ = send(.paste(text)) }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard inputEnabled, window?.firstResponder === self else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
        if !text.isEmpty { _ = send(.text(text)) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard inputEnabled, window?.firstResponder === self else { return }
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        markedSelection = selectedRange
        needsDisplay = true
    }

    func unmarkText() { markedText = NSAttributedString(string: ""); needsDisplay = true }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { markedSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor, .backgroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= markedText.length else { return nil }
        actualRange?.pointee = range
        return markedText.attributedSubstring(from: range)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let point = candidatePoint == .zero ? CGPoint(x: imageRect.midX, y: imageRect.midY) : candidatePoint
        let rect = convert(NSRect(x: point.x, y: point.y, width: 1, height: 22), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    override func doCommand(by selector: Selector) {
        guard inputEnabled else { return }
        let keys: [String: UInt32] = ["deleteBackward:": 67, "deleteForward:": 112, "insertNewline:": 66,
                                      "insertTab:": 61, "insertBacktab:": 61, "moveLeft:": 21,
                                      "moveRight:": 22, "moveUp:": 19, "moveDown:": 20, "cancelOperation:": 4]
        let name = NSStringFromSelector(selector)
        if let code = keys[name] { _ = send(.pressKey(code, meta: name == "insertBacktab:" ? 1 : 0)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hasMarkedText() else { return }
        let text = NSAttributedString(string: markedText.string, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let size = text.size()
        let box = NSRect(x: imageRect.midX - min(size.width + 24, imageRect.width - 12) / 2,
                         y: imageRect.maxY - 40, width: min(size.width + 24, imageRect.width - 12), height: 30)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(in: box.insetBy(dx: 12, dy: 6))
    }
}
