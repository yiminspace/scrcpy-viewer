import Foundation
import Darwin

/// Owns the second scrcpy socket. Reads and writes never block the UI or the video worker.
final class ScrcpyControlChannel {
    private let fd: Int32
    private let writer = DispatchQueue(label: "viewer.control.write")
    private let reader = DispatchQueue(label: "viewer.control.read")
    private let finished = DispatchGroup()
    private let closed = DispatchGroup()
    private let lock = NSLock()
    private var closing = false
    private var failed = false
    private var pendingMessages = 0
    private var sequence: UInt64 = 0
    // The following gesture state is confined to the writer queue.
    private var touch: ScrcpyControlProtocol.Touch?
    private var pressedKeys: [UInt32: UInt32] = [:]
    private var frameSize: (Int, Int)?
    private let onClipboard: (String) -> Void
    private let onFailure: (String) -> Void

    init(fd: Int32, onClipboard: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.fd = fd; self.onClipboard = onClipboard; self.onFailure = onFailure
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        finished.enter() // Reader lifetime.
        finished.enter() // Writer shutdown barrier.
        closed.enter()
        reader.async { self.receiveMessages(); self.finished.leave() }
        finished.notify(queue: writer) { Darwin.close(self.fd); self.closed.leave() }
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return !closing && !failed }

    func updateFrameSize(width: Int, height: Int) {
        writer.async { self.frameSize = (width, height) }
    }

    @discardableResult
    func send(_ data: Data, touch: ScrcpyControlProtocol.Touch? = nil,
              key: (ScrcpyKeyAction, UInt32, UInt32)? = nil) -> Bool {
        lock.lock()
        // Never discard a release because a slow device has filled the ordinary input queue.
        let isRelease = touch?.action == .up || touch?.action == .cancel || key?.0 == .up
        guard !closing, !failed, pendingMessages < 512 || isRelease else { lock.unlock(); return false }
        pendingMessages += 1
        // Enqueue while locked so stop's writer barrier cannot overtake an accepted message.
        writer.async {
            self.lock.lock(); self.pendingMessages -= 1; let skip = self.closing || self.failed; self.lock.unlock()
            guard !skip else { return }
            do {
                try self.write(data, deadline: Date().addingTimeInterval(2))
                if let touch {
                    if touch.action == .cancel {
                        // Up additionally clears scrcpy's internal generic-finger pointer table.
                        let up = ScrcpyControlProtocol.Touch(action: .up, x: touch.x, y: touch.y,
                            width: touch.width, height: touch.height, pressure: 0, buttons: 0, actionButton: 0)
                        if let bytes = ScrcpyControlProtocol.touch(up) {
                            try self.write(bytes, deadline: Date().addingTimeInterval(1))
                        }
                    }
                    self.touch = touch.action == .up || touch.action == .cancel ? nil : touch
                }
                if let (action, keyCode, metaState) = key {
                    if action == .down { self.pressedKeys[keyCode] = metaState }
                    else { self.pressedKeys.removeValue(forKey: keyCode) }
                }
            } catch { self.fail(error.localizedDescription) }
        }
        lock.unlock()
        return true
    }

    func setClipboard(_ text: String, paste: Bool) -> Bool {
        lock.lock(); sequence &+= 1; let next = sequence; lock.unlock()
        guard let data = ScrcpyControlProtocol.clipboard(text, paste: paste, sequence: next) else { return false }
        return send(data)
    }

    func stop(completion: @escaping () -> Void) {
        lock.lock()
        if !closing {
            closing = true
            writer.async {
                // Best effort and bounded: release inputs before closing the server's control channel.
                let deadline = Date().addingTimeInterval(0.5)
                if let touch = self.touch {
                    let size = self.frameSize ?? (touch.width, touch.height)
                    let x = min(size.0 - 1, touch.x * size.0 / touch.width)
                    let y = min(size.1 - 1, touch.y * size.1 / touch.height)
                    for action in [ScrcpyTouchAction.cancel, .up] {
                        let event = ScrcpyControlProtocol.Touch(action: action, x: x, y: y,
                            width: size.0, height: size.1, pressure: 0, buttons: 0, actionButton: 0)
                        if let bytes = ScrcpyControlProtocol.touch(event) { try? self.write(bytes, deadline: deadline) }
                    }
                }
                for (key, meta) in self.pressedKeys {
                    try? self.write(ScrcpyControlProtocol.key(action: .up, keyCode: key, repeatCount: 0, metaState: meta), deadline: deadline)
                }
                Darwin.shutdown(self.fd, SHUT_RDWR)
                self.finished.leave()
            }
        }
        lock.unlock()
        closed.notify(queue: writer, execute: completion)
    }

    private func write(_ data: Data, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            guard Date() < deadline else { throw ScrcpyProtocolError.malformed("发送控制事件超时") }
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            throw ScrcpyProtocolError.malformed("设备控制连接已关闭")
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            guard isReady else { throw CancellationError() }
            let size = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if size > 0 { offset += size; continue }
            if size < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            throw ScrcpyProtocolError.malformed("设备控制连接已关闭")
        }
        return data
    }

    private func receiveMessages() {
        do {
            while isReady {
                let type = try read(1).first!
                switch type {
                case 0:
                    let length = Int(ScrcpyControlProtocol.integer(try read(4)))
                    guard length <= ScrcpyControlProtocol.maximumMessageSize - 5 else {
                        throw ScrcpyProtocolError.malformed("设备剪贴板响应过大")
                    }
                    guard let text = String(data: try read(length), encoding: .utf8) else {
                        throw ScrcpyProtocolError.malformed("设备剪贴板响应编码无效")
                    }
                    if isReady { onClipboard(text) }
                case 1:
                    _ = try read(8) // Clipboard ACK confirms ordering, not successful paste.
                case 2:
                    _ = try read(2) // UHID ID. We do not create UHID devices, but consume this known event safely.
                    let length = Int(ScrcpyControlProtocol.integer(try read(2)))
                    _ = try read(length)
                default:
                    throw ScrcpyProtocolError.malformed("设备返回了不支持的控制事件")
                }
            }
        } catch is CancellationError { }
        catch { fail(error.localizedDescription) }
    }

    private func fail(_ reason: String) {
        lock.lock(); let report = !closing && !failed; failed = true; lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        if report { onFailure(reason) }
    }
}
