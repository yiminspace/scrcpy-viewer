import Foundation

/// One serial discovery worker; slow adb calls never overlap polling ticks.
public final class DisplayMonitor {
    private let dependencies: ViewerDependencies
    private let onUpdate: (DiscoverySnapshot) -> Void
    private let queue = DispatchQueue(label: "scrcpy-viewer.discovery", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var requestedSerial: String?
    private var running = false

    public init(dependencies: ViewerDependencies, onUpdate: @escaping (DiscoverySnapshot) -> Void) {
        self.dependencies = dependencies; self.onUpdate = onUpdate
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.running = false; self?.timer?.cancel(); self?.timer = nil
        }
    }

    public func selectDevice(_ serial: String?) {
        queue.async { [weak self] in self?.requestedSerial = serial; self?.poll() }
    }

    public func refresh() { queue.async { [weak self] in self?.poll() } }

    private func poll() {
        guard running else { return }
        do {
            let text = try CommandRunner.checked(executable: dependencies.adbURL, arguments: ["devices", "-l"], timeout: 5)
            let devices = DeviceParser.parse(text)
            let selected: AndroidDevice?
            if let requestedSerial { selected = devices.first { $0.serial == requestedSerial } }
            else { selected = devices.first(where: \.isConnected) ?? devices.first }
            guard let device = selected else {
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: requestedSerial))
                return
            }
            // Keep the first chosen device across unplug/replug; never silently
            // switch to another person's phone when the current one disappears.
            if requestedSerial == nil { requestedSerial = device.serial }
            guard device.isConnected else {
                let hint = device.connectionState == "unauthorized" ? "请解锁手机，允许这台电脑进行 USB 调试。" : "设备离线，请检查 USB 连接。"
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: device.serial, error: hint))
                return
            }
            do {
                let dump = try CommandRunner.checked(executable: dependencies.adbURL, arguments: ["-s", device.serial, "shell", "dumpsys", "display"], timeout: 5)
                let displays = DisplayParser.parse(dump, serial: device.serial)
                onUpdate(DiscoverySnapshot(devices: devices, displays: displays, selectedSerial: device.serial, error: displays.isEmpty ? "暂时读不到设备屏幕，正在重试。" : nil))
            } catch {
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: device.serial, error: error.localizedDescription))
            }
        } catch {
            onUpdate(DiscoverySnapshot(devices: [], displays: [], selectedSerial: requestedSerial, error: error.localizedDescription))
        }
    }

    deinit { timer?.cancel() }
}
