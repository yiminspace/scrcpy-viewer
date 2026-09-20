import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let output: String
    public let status: Int32
    public init(output: String, status: Int32) { self.output = output; self.status = status }
}

public enum ViewerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// Synchronous, bounded subprocess execution. Call from a worker queue.
public enum CommandRunner {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 10) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0.1)
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        // An override may be a wrapper whose descendants inherit stdout. Waiting
        // for EOF after killing the wrapper would then ignore the timeout.
        // Read our pipe non-blockingly and bound both reading and child lifetime.
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 8 * 1024 * 1024 {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno != EAGAIN && errno != EWOULDBLOCK { break }
            if !process.isRunning { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = Darwin.poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
        }
        // A child can close stdout while continuing to run. Its lifetime is
        // bounded too, independently of the pipe.
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }

    public static func checked(executable: URL, arguments: [String], timeout: TimeInterval = 10) throws -> String {
        let result = try run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ViewerError.message(message.isEmpty ? "\(executable.lastPathComponent) 没有完成，请检查 USB 连接。" : String(message.suffix(2000)))
        }
        return result.output
    }
}
