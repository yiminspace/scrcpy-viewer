import Foundation
import CoreGraphics
import Darwin

/// Owns one scrcpy session. Only display 0 has a control socket. Callbacks run on a private serial queue.
public final class ScrcpyStream {
    private let dependencies: ViewerDependencies
    private let serial: String
    private let displayID: Int
    private let onFrame: (CGImage) -> Void
    private let onState: (StreamState) -> Void
    private let onClipboard: (String) -> Void
    private let worker = DispatchQueue(label: "viewer.scrcpy.worker", qos: .userInitiated)
    private let callbacks = DispatchQueue(label: "viewer.scrcpy.callbacks", qos: .userInitiated)
    private let lifecycle = DispatchGroup()
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var socketFD: Int32 = -1
    private var process: Process?
    private var controlChannel: ScrcpyControlChannel?
    private var controlFailure: String?
    private var remotePID: Int?
    private var logTail = ""
    private var logPartial = Data()
    private var firstFrame = true
    private var hasDecodedFrame = false
    private var latestFrame: CGImage?
    private var frameDeliveryScheduled = false
    private var forwardedPort: Int?
    private let scid = String(format: "%08x", UInt32.random(in: 1...0x7fffffff))
    private var remotePath: String { "/data/local/tmp/scrcpy-viewer-\(scid).jar" }

    public init(dependencies: ViewerDependencies, serial: String, displayID: Int,
                onFrame: @escaping (CGImage) -> Void, onState: @escaping (StreamState) -> Void,
                onClipboard: @escaping (String) -> Void = { _ in }) {
        self.dependencies = dependencies; self.serial = serial; self.displayID = displayID
        self.onFrame = onFrame; self.onState = onState; self.onClipboard = onClipboard
    }

    public var isControlReady: Bool { readyControlChannel != nil }

    /// Coordinates and dimensions describe the currently decoded video frame, excluding letterboxing.
    @discardableResult
    public func sendTouch(action: ScrcpyTouchAction, x: Int, y: Int, width: Int, height: Int,
                          pressure: Float = 1, buttons: UInt32 = 0, actionButton: UInt32 = 0) -> Bool {
        guard let channel = readyControlChannel else { return false }
        let event = ScrcpyControlProtocol.Touch(action: action, x: x, y: y, width: width, height: height,
            pressure: pressure, buttons: buttons, actionButton: actionButton)
        guard let data = ScrcpyControlProtocol.touch(event) else { return false }
        return channel.send(data, touch: event)
    }

    @discardableResult
    public func sendScroll(x: Int, y: Int, width: Int, height: Int,
                           horizontal: Float, vertical: Float, buttons: UInt32 = 0) -> Bool {
        guard let channel = readyControlChannel,
              let data = ScrcpyControlProtocol.scroll(x: x, y: y, width: width, height: height,
                horizontal: horizontal, vertical: vertical, buttons: buttons) else { return false }
        return channel.send(data)
    }

    @discardableResult
    public func sendKey(action: ScrcpyKeyAction, keyCode: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0) -> Bool {
        guard let channel = readyControlChannel else { return false }
        return channel.send(ScrcpyControlProtocol.key(action: action, keyCode: keyCode,
            repeatCount: repeatCount, metaState: metaState), key: (action, keyCode, metaState))
    }

    /// A down/up pair is queued atomically. Keycodes 3, 4 and 187 are Home, Back and Recents.
    @discardableResult
    public func pressKey(keyCode: UInt32, metaState: UInt32 = 0) -> Bool {
        guard let channel = readyControlChannel else { return false }
        let down = ScrcpyControlProtocol.key(action: .down, keyCode: keyCode, repeatCount: 0, metaState: metaState)
        let up = ScrcpyControlProtocol.key(action: .up, keyCode: keyCode, repeatCount: 0, metaState: metaState)
        return channel.send(down + up)
    }

    /// Android key-character injection is limited; use clipboard paste for committed Unicode/IME text.
    @discardableResult
    public func injectText(_ text: String) -> Bool {
        guard let channel = readyControlChannel, let data = ScrcpyControlProtocol.text(text) else { return false }
        return channel.send(data)
    }

    @discardableResult
    public func setClipboard(_ text: String, paste: Bool = true) -> Bool {
        readyControlChannel?.setClipboard(text, paste: paste) ?? false
    }

    @discardableResult
    public func requestClipboard(_ request: ScrcpyClipboardRequest = .copy) -> Bool {
        readyControlChannel?.send(ScrcpyControlProtocol.requestClipboard(request)) ?? false
    }

    private var readyControlChannel: ScrcpyControlChannel? {
        lock.lock(); defer { lock.unlock() }
        guard ScrcpyControlProtocol.allowsControl(displayID: displayID), !cancelled, hasDecodedFrame,
              let channel = controlChannel, channel.isReady else { return nil }
        return channel
    }

    /// A stream instance is single-use. Reconnection gets a fresh session identity.
    public func start() {
        lock.lock()
        guard !started, !cancelled else { lock.unlock(); return }
        started = true
        lifecycle.enter()
        lock.unlock()
        emit(.starting)
        worker.async { self.run() }
    }

    /// Shutdown interrupts a blocked socket read; all potentially blocking cleanup stays off the caller.
    public func stop() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let channel = controlChannel
        latestFrame = nil
        lock.unlock()
        // Release any injected gesture before a video broken pipe can make the server exit.
        if let channel { channel.stop { self.interruptVideo() } }
        else { interruptVideo() }
        callbacks.async { self.onState(.stopped) }
    }

    /// Completion runs after this session's remote server, forward and temporary files are cleaned up.
    /// It also completes for a never-started or already-finished stream, without blocking the caller.
    public func stop(completion: @escaping () -> Void) {
        stop()
        lifecycle.notify(queue: callbacks, execute: completion)
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    private func run() {
        defer {
            cleanup()
            lifecycle.leave()
        }
        do {
            guard dependencies.serverVersion == "3.3.3", displayID >= 0 else {
                throw ScrcpyProtocolError.malformed("需要 scrcpy-server 3.3.3 和有效的屏幕 ID")
            }
            try checkCancellation()
            try adb(["push", dependencies.serverURL.path, remotePath], timeout: 20)
            try checkCancellation()
            let portText = try adb(["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
            guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...65535).contains(port) else {
                throw ScrcpyProtocolError.malformed("adb 未返回有效的转发端口")
            }
            forwardedPort = port
            try checkCancellation()
            try launchServer()
            let fd = try connect(port: port)
            if ScrcpyControlProtocol.allowsControl(displayID: displayID) {
                let controlFD = try connectControl(port: port)
                let channel = ScrcpyControlChannel(fd: controlFD, onClipboard: { [weak self] text in
                    guard let self else { return }
                    self.callbacks.async { if !self.isCancelled { self.onClipboard(text) } }
                }, onFailure: { [weak self] reason in self?.controlConnectionFailed(reason) })
                lock.lock(); controlChannel = channel; lock.unlock()
                try checkCancellation()
            }
            let initialFrameDeadline = Date().addingTimeInterval(15)
            _ = try readExactly(64, from: fd, deadline: initialFrameDeadline)
            _ = try ScrcpyProtocol.videoHeader(readExactly(12, from: fd, deadline: initialFrameDeadline))
            let decoder = H264Decoder { [weak self] image in self?.receivedFrame(image) }
            defer { decoder.close() }
            while !isCancelled {
                let header = try ScrcpyProtocol.packetHeader(readExactly(12, from: fd,
                    initialFrameDeadline: initialFrameDeadline))
                let payload = try readExactly(header.length, from: fd,
                    initialFrameDeadline: initialFrameDeadline)
                try decoder.decode(payload, header: header)
            }
        } catch is CancellationError {
            // stop() already published the user-visible terminal state.
        } catch {
            if !isCancelled {
                lock.lock(); let details = controlFailure ?? error.localizedDescription; lock.unlock()
                emit(.failed(details))
            }
        }
    }

    @discardableResult
    private func adb(_ arguments: [String], timeout: TimeInterval = 10) throws -> String {
        let result = try CommandRunner.run(executable: dependencies.adbURL,
                                          arguments: ["-s", serial] + arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ScrcpyProtocolError.malformed("adb 操作失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))")
        }
        return result.output
    }

    private func launchServer() throws {
        let child = Process()
        let output = Pipe()
        child.executableURL = dependencies.adbURL
        let videoOptions = displayID == 0
            ? "max_size=0 max_fps=60 video_bit_rate=8000000"
            : "max_size=1920 max_fps=30 video_bit_rate=4000000"
        // The shell is replaced by app_process, so its reported PID identifies this exact server.
        let command = "echo $$ > \(remotePath).pid; echo SCRCPY_VIEWER_PID=$$; CLASSPATH=\(remotePath) exec app_process / " +
            "com.genymobile.scrcpy.Server 3.3.3 scid=\(scid) tunnel_forward=true " +
            "video=true audio=false control=\(ScrcpyControlProtocol.allowsControl(displayID: displayID)) video_codec=h264 display_id=\(displayID) " +
            "\(videoOptions) power_on=false clipboard_autosync=false cleanup=true"
        child.arguments = ["-s", serial, "shell", command]
        child.standardOutput = output; child.standardError = output
        child.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consumeServerLog(data)
        }
        lock.lock()
        guard !cancelled else {
            lock.unlock(); output.fileHandleForReading.readabilityHandler = nil
            throw CancellationError()
        }
        do {
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock(); output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private func consumeServerLog(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        logPartial.append(data)
        while let newline = logPartial.firstIndex(of: 10) {
            let line = String(decoding: logPartial[..<newline], as: UTF8.self)
            logPartial.removeSubrange(...newline)
            if line.hasPrefix("SCRCPY_VIEWER_PID="),
               let pid = Int(line.dropFirst("SCRCPY_VIEWER_PID=".count).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                remotePID = pid
            } else {
                logTail += line + "\n"
                if logTail.count > 8192 { logTail = String(logTail.suffix(8192)) }
            }
        }
        if logPartial.count > 8192 { logPartial = Data(logPartial.suffix(8192)) }
    }

    private func connect(port: Int) throws -> Int32 {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try checkCancellation()
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw socketError("无法创建视频连接") }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if cancelled { lock.unlock(); Darwin.close(fd); throw CancellationError() }
            socketFD = fd
            lock.unlock()
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 {
                do {
                    let dummy = try readExactly(1, from: fd, deadline: min(deadline, Date().addingTimeInterval(1)))
                    guard dummy.first == 0 else { throw ScrcpyProtocolError.malformed("scrcpy 握手无效") }
                    return fd
                } catch is CancellationError {
                    closeSocket(fd); throw CancellationError()
                } catch { /* adb forward accepts connections before its remote socket exists. */ }
            }
            closeSocket(fd)
            lock.lock(); let exited = process.map { !$0.isRunning } ?? false; let tail = logTail; lock.unlock()
            if exited {
                throw ScrcpyProtocolError.malformed("设备视频服务未能启动：\(tail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(700))")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ScrcpyProtocolError.malformed("等待设备视频连接超时")
    }

    /// Server already accepted the video socket and is waiting for this second socket.
    /// There is no dummy byte or device metadata on the control socket.
    private func connectControl(port: Int) throws -> Int32 {
        try checkCancellation()
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("无法创建设备控制连接") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { Darwin.close(fd); throw socketError("连接设备控制通道失败") }
        return fd
    }

    private func interruptVideo() {
        lock.lock()
        if socketFD >= 0 { Darwin.shutdown(socketFD, SHUT_RDWR) }
        lock.unlock()
    }

    private func controlConnectionFailed(_ reason: String) {
        lock.lock(); controlFailure = reason; lock.unlock()
        interruptVideo()
    }

    private func readExactly(_ count: Int, from fd: Int32, deadline: Date? = nil,
                             initialFrameDeadline: Date? = nil) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try checkCancellation()
            if let deadline, Date() > deadline { throw ScrcpyProtocolError.malformed("读取视频握手超时") }
            if let initialFrameDeadline, Date() > initialFrameDeadline {
                lock.lock(); let awaitingFrame = !hasDecodedFrame; lock.unlock()
                if awaitingFrame { throw ScrcpyProtocolError.malformed("等待设备首帧超时，屏幕可能已休眠") }
            }
            let size = result.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if size > 0 { offset += size; continue }
            try checkCancellation()
            if size == 0 { throw ScrcpyProtocolError.malformed("设备视频连接已关闭") }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw socketError("读取设备视频失败")
        }
        return result
    }

    private func closeSocket(_ fd: Int32) {
        lock.lock()
        if socketFD == fd { socketFD = -1 }
        _ = Darwin.close(fd)
        lock.unlock()
    }

    private func socketError(_ message: String) -> Error {
        ScrcpyProtocolError.malformed("\(message)：\(String(cString: strerror(errno)))")
    }

    private func receivedFrame(_ image: CGImage) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        hasDecodedFrame = true
        controlChannel?.updateFrameSize(width: image.width, height: image.height)
        latestFrame = image
        guard !frameDeliveryScheduled else { lock.unlock(); return }
        frameDeliveryScheduled = true
        lock.unlock()
        callbacks.async {
            self.lock.lock()
            let image = self.cancelled ? nil : self.latestFrame
            self.latestFrame = nil; self.frameDeliveryScheduled = false
            let isFirst = self.firstFrame
            if image != nil { self.firstFrame = false }
            self.lock.unlock()
            if let image {
                self.onFrame(image)
                if isFirst { self.onState(.streaming) }
            }
        }
    }

    private func emit(_ state: StreamState) {
        callbacks.async { if !self.isCancelled { self.onState(state) } }
    }

    private func cleanup() {
        lock.lock(); let channel = controlChannel; lock.unlock()
        if let channel {
            let finished = DispatchSemaphore(value: 0)
            channel.stop { finished.signal() }
            finished.wait()
        }
        lock.lock(); controlChannel = nil; let fd = socketFD; lock.unlock()
        if fd >= 0 { closeSocket(fd) }
        lock.lock(); let child = process; let knownPID = remotePID; lock.unlock()
        // The PID file also covers cancellation before the asynchronous log reader sees the marker.
        let savedPID = (try? adb(["shell", "cat", remotePath + ".pid"], timeout: 5))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = knownPID ?? savedPID.flatMap(Int.init)
        // Verify the unique classpath before signaling: Android can reuse a terminated PID.
        if let pid, pid > 1 {
            // CLASSPATH is an environment variable, not an app_process command-line argument.
            let killOwned = "if [ -r /proc/\(pid)/environ ]; then " +
                "if tr '\\000' '\\n' < /proc/\(pid)/environ | " +
                "grep -Fx 'CLASSPATH=\(remotePath)' >/dev/null; then kill \(pid) 2>/dev/null; fi; fi"
            _ = try? adb(["shell", killOwned], timeout: 5)
        }
        if let child, child.isRunning { child.terminate() }
        if let port = forwardedPort { _ = try? adb(["forward", "--remove", "tcp:\(port)"], timeout: 5) }
        _ = try? adb(["shell", "rm", "-f", remotePath, remotePath + ".pid"], timeout: 5)
        lock.lock(); process = nil; lock.unlock()
    }
}
