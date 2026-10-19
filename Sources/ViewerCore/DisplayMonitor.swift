import Foundation

/// One serial discovery worker; slow adb calls never overlap polling ticks.
public final class DisplayMonitor {
    private let dependencies: ViewerDependencies
    private let onUpdate: (DiscoverySnapshot) -> Void
    private let queue = DispatchQueue(label: "scrcpy-viewer.discovery", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var requestedSerial: String?
    private var running = false
    private var reconnectPolicy = WirelessReconnectPolicy()
    private var reconnectControl = WirelessReconnectControl()
    private var discoveryPolicy = WirelessDiscoveryPolicy()
    private var candidateReconnectPolicy = WirelessReconnectPolicy()
    private var pendingService: WirelessService?
    private var lastDiscoveryAt: TimeInterval?
    private var identityAttemptedFor: String?
    private var identityVerificationError: String?
    private var replacementSerial: String?
    private let preferences: UserDefaults
    private var identities: [String: WirelessDeviceIdentity]
    private var verifiedOnline: [String: WirelessDeviceIdentity] = [:]
    private var verifiedTransportIDs: [String: String] = [:]
    private var connectionMode: DeviceConnectionMode = .automatic
    private var identityMismatches = Set<String>()
    private static let identitiesKey = "wirelessDeviceIdentities.v1"

    public init(dependencies: ViewerDependencies, preferences: UserDefaults = .standard, onUpdate: @escaping (DiscoverySnapshot) -> Void) {
        self.dependencies = dependencies; self.onUpdate = onUpdate
        self.preferences = preferences
        identities = preferences.data(forKey: Self.identitiesKey).flatMap {
            try? JSONDecoder().decode([String: WirelessDeviceIdentity].self, from: $0)
        } ?? [:]
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
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedSerial = serial
            self.reconnectControl.resume()
            self.replacementSerial = nil
            self.identityAttemptedFor = nil
            self.identityVerificationError = nil
            self.pendingService = nil
            self.candidateReconnectPolicy.reset()
            self.discoveryPolicy.reset()
            self.lastDiscoveryAt = nil
            self.poll()
        }
    }

    public func setConnectionMode(_ mode: DeviceConnectionMode) {
        queue.async { [weak self] in
            self?.connectionMode = mode
            self?.reconnectControl.resume()
            self?.poll()
        }
    }

    public func refresh() {
        queue.async { [weak self] in
            self?.reconnectControl.resume()
            self?.reconnectPolicy.reset()
            self?.discoveryPolicy.reset()
            self?.candidateReconnectPolicy.reset()
            self?.lastDiscoveryAt = nil
            self?.identityAttemptedFor = nil
            self?.identityVerificationError = nil
            self?.verifiedOnline.removeAll()
            self?.poll()
        }
    }

    public func pauseWirelessReconnect() {
        queue.async { [weak self] in
            self?.reconnectControl.pause()
            self?.poll()
        }
    }

    private var wirelessOfflineHint: String {
        switch reconnectControl.status {
        case .automatic: return "无线设备未连接，正在自动重连。请确认手机与电脑网络互通，且无线 adb 已开启。"
        case .paused: return "自动重连已停止。点击继续重连可再次尝试。"
        case .timedOut: return "连续 10 分钟未连接，已停止自动重连。点击继续重连可再次尝试。"
        }
    }

    private func poll() {
        guard running else { return }
        do {
            let text = try CommandRunner.checked(executable: dependencies.adbURL, arguments: ["devices", "-l"], timeout: 5)
            var devices = identify(DeviceParser.parse(text))
            // Retain the selected phone across disappearance so it cannot fall
            // through to a different connected phone, and its alternate can be selected.
            if let requestedSerial, !devices.contains(where: { $0.serial == requestedSerial }) {
                devices.append(AndroidDevice(serial: requestedSerial, model: identities[requestedSerial]?.serialNumber ?? requestedSerial,
                    connectionState: "offline", physicalSerial: identities[requestedSerial]?.serialNumber))
            }
            if let requestedSerial, let known = identities[requestedSerial] {
                // Keep one remembered offline alternate visible without filling
                // the picker with expired wireless ports from earlier sessions.
                for (endpoint, identity) in identities.sorted(by: { $0.key < $1.key }) where identity.serialNumber == known.serialNumber {
                    let alternate = AndroidDevice(serial: endpoint, model: known.serialNumber, connectionState: "offline",
                                                  physicalSerial: known.serialNumber)
                    if !devices.contains(where: { $0.physicalSerial == known.serialNumber && $0.isWireless == alternate.isWireless }) {
                        devices.append(alternate)
                    }
                }
            }
            let selected: AndroidDevice?
            if let requestedSerial, let current = devices.first(where: { $0.serial == requestedSerial }) {
                let samePhone = devices.filter { $0.physicalID == current.physicalID }
                selected = DeviceConnectionPolicy.select(from: samePhone, current: requestedSerial, mode: connectionMode)
            } else {
                let first = devices.first(where: \.isConnected) ?? devices.first
                selected = first.flatMap { first in
                    DeviceConnectionPolicy.select(from: devices.filter { $0.physicalID == first.physicalID }, current: nil, mode: connectionMode)
                }
            }
            if requestedSerial != nil {
                _ = reconnectControl.allowsAttempt(connected: selected?.isConnected == true,
                    now: ProcessInfo.processInfo.systemUptime)
            }
            guard let device = selected else {
                let wireless = requestedSerial.map(WirelessReconnectPolicy.isNetworkSerial) == true
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: requestedSerial,
                    error: connectionMode == .automatic ? (wireless ? wirelessOfflineHint : nil) : "所选连接方式不可用，正在等待连接。",
                    replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status, transportAvailable: false))
                reconnectWirelessDevice(devices: devices)
                return
            }
            // Keep the first chosen device across unplug/replug; never silently
            // switch to another person's phone when the current one disappears.
            if let previous = requestedSerial, previous != device.serial {
                replacementSerial = previous
                identityAttemptedFor = nil
            }
            requestedSerial = device.serial
            guard device.isConnected else {
                let hint = device.connectionState == "unauthorized" ? "请在手机上允许这台电脑进行 adb 调试。" :
                    (WirelessReconnectPolicy.isNetworkSerial(device.serial) ? wirelessOfflineHint : "设备离线，请检查 USB 连接。")
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: device.serial, error: hint, replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status))
                reconnectWirelessDevice(devices: devices)
                return
            }
            reconnectWirelessDevice(devices: devices)
            if let error = rememberIdentity(for: device) {
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: device.serial,
                    error: error, replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status))
                return
            }
            do {
                let dump = try CommandRunner.checked(executable: dependencies.adbURL, arguments: ["-s", device.serial, "shell", "dumpsys", "display"], timeout: 5)
                let displays = DisplayParser.parse(dump, serial: device.serial).map { $0.identified(as: device.physicalID) }
                onUpdate(DiscoverySnapshot(devices: devices, displays: displays, selectedSerial: device.serial, error: displays.isEmpty ? "暂时读不到设备屏幕，正在重试。" : nil, replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status))
            } catch {
                onUpdate(DiscoverySnapshot(devices: devices, displays: [], selectedSerial: device.serial, error: error.localizedDescription, replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status))
            }
        } catch {
            onUpdate(DiscoverySnapshot(devices: [], displays: [], selectedSerial: requestedSerial, error: error.localizedDescription, replacingSerial: replacementSerial, reconnectStatus: reconnectControl.status))
        }
    }

    private func identify(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        var changed = false
        let online = Set(devices.filter(\.isConnected).map(\.serial))
        verifiedOnline = verifiedOnline.filter { online.contains($0.key) }
        for device in devices where verifiedTransportIDs[device.serial] != device.transportID {
            verifiedOnline.removeValue(forKey: device.serial)
        }
        identityMismatches = identityMismatches.intersection(online)
        for device in devices where device.isConnected && verifiedOnline[device.serial] == nil {
            guard let hardware = try? CommandRunner.checked(executable: dependencies.adbURL,
                arguments: ["-s", device.serial, "shell", "getprop", "ro.serialno"], timeout: 2)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !["unknown", "null"].contains(hardware.lowercased()),
                let identity = WirelessDeviceIdentity(serialNumber: hardware) else { continue }
            // A reused wireless address must not inherit the old phone's identity.
            if device.serial == requestedSerial, let known = identities[device.serial], known.serialNumber != hardware {
                identityMismatches.insert(device.serial)
                continue
            }
            identityMismatches.remove(device.serial)
            let remembered = identities[device.serial].flatMap { $0.serialNumber == hardware ? $0 : nil } ?? identity
            verifiedOnline[device.serial] = remembered
            verifiedTransportIDs[device.serial] = device.transportID
            changed = changed || identities[device.serial] != remembered
            identities[device.serial] = remembered
        }
        if changed { saveIdentities() }
        return devices.map { device in
            if identityMismatches.contains(device.serial) {
                return AndroidDevice(serial: device.serial, model: device.model, connectionState: "identity-mismatch",
                                     physicalSerial: identities[device.serial]?.serialNumber, transportID: device.transportID)
            }
            let identity = device.isConnected ? verifiedOnline[device.serial] : identities[device.serial]
            return AndroidDevice(serial: device.serial, model: device.model, connectionState: device.connectionState,
                                 physicalSerial: identity?.serialNumber, transportID: device.transportID)
        }
    }

    private func reconnectWirelessDevice(devices: [AndroidDevice]) {
        guard connectionMode != .usb, reconnectControl.status == .automatic else { return }
        if let requestedSerial, !devices.contains(where: { $0.serial == requestedSerial && $0.isConnected }) {
            identityAttemptedFor = nil
            identityVerificationError = nil
        }
        let previousEndpoint = requestedSerial
        discoverWirelessDevice(devices: devices)
        guard requestedSerial == previousEndpoint else { return }
        guard let target = reconnectPolicy.target(serial: requestedSerial, devices: devices,
            now: ProcessInfo.processInfo.systemUptime) else { return }
        // Stay on the discovery queue, bound each attempt, and let the next devices
        // poll confirm connectivity. Command output alone does not mean a live stream.
        _ = try? CommandRunner.run(executable: dependencies.adbURL, arguments: ["connect", target], timeout: 2)
        reconnectPolicy.attemptFinished(now: ProcessInfo.processInfo.systemUptime)
    }

    private func rememberIdentity(for device: AndroidDevice) -> String? {
        guard device.isConnected, WirelessReconnectPolicy.isNetworkSerial(device.serial),
              identityAttemptedFor != device.serial else { return identityVerificationError }
        identityAttemptedFor = device.serial
        identityVerificationError = identities[device.serial] == nil ? nil : "无法核对无线设备身份，请重试。"
        guard let serialNumber = try? CommandRunner.checked(executable: dependencies.adbURL,
            arguments: ["-s", device.serial, "shell", "getprop", "ro.serialno"], timeout: 2)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return identityVerificationError }
        if let known = identities[device.serial], known.serialNumber != serialNumber {
            identityVerificationError = "无线地址对应的设备与记录不符，已停止自动恢复。"
            return identityVerificationError
        }
        let guid = (try? CommandRunner.checked(executable: dependencies.adbURL,
            arguments: ["-s", device.serial, "shell", "getprop", "persist.adb.wifi.guid"], timeout: 2))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let identity = WirelessDeviceIdentity(serialNumber: serialNumber, wifiGUID: guid) else { return identityVerificationError }
        identities[device.serial] = identity
        identityVerificationError = nil
        saveIdentities()
        return nil
    }

    private func saveIdentities() {
        if let data = try? JSONEncoder().encode(identities) {
            preferences.set(data, forKey: Self.identitiesKey)
        }
    }

    private func discoverWirelessDevice(devices: [AndroidDevice]) {
        guard connectionMode != .usb, let endpoint = requestedSerial,
              (connectionMode == .wireless && !WirelessReconnectPolicy.isNetworkSerial(endpoint)) ||
                !devices.contains(where: { $0.serial == endpoint && $0.connectionState != "offline" }),
              let identity = identities[endpoint] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastDiscoveryAt.map({ now - $0 >= 5 }) ?? true else { return }
        lastDiscoveryAt = now
        guard let text = try? CommandRunner.checked(executable: dependencies.adbURL,
            arguments: ["mdns", "services"], timeout: 2) else { return }
        let services = WirelessService.parse(text)
        if let appeared = discoveryPolicy.candidate(services: services, identity: identity) {
            // Reset only on a changed announcement, never on every cached discovery response.
            reconnectPolicy.reset()
            candidateReconnectPolicy.reset()
            pendingService = appeared
        }
        guard let candidate = pendingService else { return }
        let matching = WirelessDiscoveryPolicy.matching(services: services, identity: identity)
        guard matching.count == 1, matching.contains(candidate) else {
            pendingService = nil
            return
        }
        guard candidate.endpoint != endpoint else { pendingService = nil; return }
        guard candidateReconnectPolicy.target(serial: candidate.endpoint, devices: [], now: now) != nil else { return }
        _ = try? CommandRunner.run(executable: dependencies.adbURL,
            arguments: ["connect", candidate.endpoint], timeout: 2)
        candidateReconnectPolicy.attemptFinished(now: ProcessInfo.processInfo.systemUptime)
        // Do not select or stream from an announcement until authenticated shell access
        // confirms the remembered identity. Never disconnect unrelated transports.
        guard let serialNumber = try? CommandRunner.checked(executable: dependencies.adbURL,
            arguments: ["-s", candidate.endpoint, "shell", "getprop", "ro.serialno"], timeout: 2)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard serialNumber == identity.serialNumber else {
            // A wrong device is not a transient network error. Wait for a changed
            // announcement or explicit refresh before considering it again.
            pendingService = nil
            return
        }
        identities[candidate.endpoint] = identity
        saveIdentities()
        replacementSerial = endpoint
        requestedSerial = candidate.endpoint
        identityAttemptedFor = candidate.endpoint
        identityVerificationError = nil
        pendingService = nil
    }

    deinit { timer?.cancel() }
}
