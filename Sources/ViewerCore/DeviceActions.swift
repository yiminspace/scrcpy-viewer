import Foundation

/// Explicit user actions for a device whose sleeping main screen has no capture session.
public enum DeviceActions {
    /// Call only after the user presses Wake, on a background queue. Never invoked by discovery.
    public static func wakeMainDisplay(dependencies: ViewerDependencies, serial: String) throws {
        guard !serial.isEmpty else {
            throw ScrcpyProtocolError.malformed("未选择设备")
        }
        let result = try CommandRunner.run(executable: dependencies.adbURL,
            arguments: ["-s", serial, "shell", "input", "keyevent", "224"], timeout: 10)
        guard result.status == 0 else {
            throw ScrcpyProtocolError.malformed("唤醒主屏失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))")
        }
    }
}
