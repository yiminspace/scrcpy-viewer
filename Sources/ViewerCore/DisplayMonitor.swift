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
    private var wirelessADB: WirelessADBServer?
    private var wirelessADBIsReady = false
    private var wirelessADBIdentity: WirelessDeviceIdentity?
    private var privateSerials = Set<String>()
    private let makeBrowser: (DispatchQueue, @escaping (Set<WirelessADBBrowser.Service>) -> Void) -> AnyObject
    private let resolveBonjourService: (WirelessADBBrowser.Service) -> [WirelessService]
    private var browser: AnyObject?
    private var advertisedServices = Set<WirelessADBBrowser.Service>()
    private var attemptedRepair = false
    private var repairError: String?
    private var canRepairWireless = false
    private static let identitiesKey = "wirelessDeviceIdentities.v1"

    public convenience init(dependencies: ViewerDependencies, preferences: UserDefaults = .standard,
                            onUpdate: @escaping (DiscoverySnapshot) -> Void) {
        self.init(dependencies: dependencies, preferences: preferences, makeBrowser: WirelessADBBrowser.init, onUpdate: onUpdate)
    }

    init(dependencies: ViewerDependencies, preferences: UserDefaults,
         makeBrowser: @escaping (DispatchQueue, @escaping (Set<WirelessADBBrowser.Service>) -> Void) -> AnyObject,
         resolveBonjourService: @escaping (WirelessADBBrowser.Service) -> [WirelessService] = WirelessADBBrowser.resolve,
         onUpdate: @escaping (DiscoverySnapshot) -> Void) {
        self.dependencies = dependencies; self.onUpdate = onUpdate
        self.makeBrowser = makeBrowser
        self.resolveBonjourService = resolveBonjourService
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
        queue.async {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.stopBrowsing()
        }
    }

    /// The model calls this after all scrcpy streams have retired on shutdown.
    public func finishShutdown(completion: @escaping () -> Void) {
        queue.async {
            self.wirelessADB = nil
            completion()
        }
    }

    public func repairWirelessConnection() {
        queue.async {
            guard self.running, self.canRepairWireless, self.connectionMode != .usb else { return }
            self.wirelessADB = nil
            self.privateSerials.removeAll()
            self.attemptedRepair = false
            self.repairError = nil
            self.reconnectControl.resume()
            self.resetReconnectAttempts()
            self.poll()
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
            self.attemptedRepair = false
            self.repairError = nil
            self.resetReconnectAttempts()
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
            self?.resetReconnectAttempts()
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

    private func resetReconnectAttempts() {
        reconnectPolicy.reset()
        discoveryPolicy.reset()
        candidateReconnectPolicy.reset()
        lastDiscoveryAt = nil
        pendingService = nil
    }

    private func stopBrowsing() {
        browser = nil
        advertisedServices.removeAll()
        canRepairWireless = false
    }

    private func route(for serial: String) -> UInt16? {
        privateSerials.contains(serial) ? wirelessADB?.port : nil
    }

    private func adb(_ arguments: [String], port: UInt16? = nil, timeout: TimeInterval = 2) throws -> String {
        try CommandRunner.checked(executable: dependencies.adbURL,
            arguments: dependencies.routingWirelessADB(to: port).adbArguments(arguments), timeout: timeout)
    }

    private func connect(_ endpoint: String, port: UInt16?) {
        _ = try? adb(["connect", endpoint], port: port)
    }

    private func repairIfNeeded(for identity: WirelessDeviceIdentity?, device: AndroidDevice?) {
        guard connectionMode != .usb, let identity, device?.isConnected != true,
              device?.connectionState != "unauthorized", device?.connectionState != "identity-mismatch" else {
            stopBrowsing()
            if device?.isConnected == true {
                attemptedRepair = false
                repairError = nil
            }
            return
        }
        // A user-requested pause stops discovery as well as outbound reconnect attempts.
        guard reconnectControl.status == .automatic else {
            stopBrowsing()
            return
        }
        if browser == nil {
            browser = makeBrowser(queue) { [weak self] services in self?.advertisedServices = services }
        }
        canRepairWireless = advertisedServices.contains { identity.matches(serviceName: $0.name) }
        guard canRepairWireless, !attemptedRepair else { return }
        attemptedRepair = true
        do {
            if wirelessADB?.isRunning != true {
                wirelessADB = try WirelessADBServer(dependencies: dependencies)
                wirelessADBIsReady = false
            }
            wirelessADBIdentity = identity
            resetReconnectAttempts()
        } catch {
            repairError = error.localizedDescription
        }
    }

    private func privateDevices() -> [AndroidDevice] {
        wirelessADBIsReady = false
        guard let wirelessADB, wirelessADB.isRunning, let identity = wirelessADBIdentity,
              let requestedSerial, identities[requestedSerial]?.serialNumber == identity.serialNumber,
              connectionMode != .usb,
              let output = try? adb(["devices", "-l"], port: wirelessADB.port) else { return [] }
        wirelessADBIsReady = true
        // Ignore every transport except the numeric endpoint explicitly connected
        // and authenticated by this monitor for the selected physical device.
        return DeviceParser.parse(output).filter {
            WirelessReconnectPolicy.isNetworkSerial($0.serial)
                && identities[$0.serial]?.serialNumber == identity.serialNumber
        }
    }

    private func publish(devices: [AndroidDevice], displays: [AndroidDisplay] = [],
                         serial: String?, error: String? = nil, transportAvailable: Bool = true) {
        let repairHint = canRepairWireless ? repairError ?? "检测到手机的无线调试，正在尝试恢复无线 ADB。" : nil
        onUpdate(DiscoverySnapshot(devices: devices, displays: displays, selectedSerial: serial,
            error: repairHint ?? error, replacingSerial: replacementSerial,
            reconnectStatus: reconnectControl.status, transportAvailable: transportAvailable,
            wirelessADBPort: serial.flatMap(route(for:)), canRepairWireless: canRepairWireless))
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
            let shared = Result { try adb(["devices", "-l"], timeout: 5) }
            let ownDevices = privateDevices()
            if ownDevices.isEmpty, wirelessADB?.isRunning != true { _ = try shared.get() }
            let sharedDevices = DeviceParser.parse((try? shared.get()) ?? "")
            let own = ownDevices.filter { candidate in
                candidate.isConnected || !sharedDevices.contains(where: { $0.serial == candidate.serial })
            }
            let nextPrivateSerials = Set(own.map(\.serial))
            for serial in privateSerials.symmetricDifference(nextPrivateSerials) {
                verifiedOnline.removeValue(forKey: serial)
            }
            privateSerials = nextPrivateSerials
            var devices = identify(sharedDevices.filter { !privateSerials.contains($0.serial) } + own)
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
            repairIfNeeded(for: requestedSerial.flatMap { identities[$0] }, device: selected)
            guard let device = selected else {
                let wireless = requestedSerial.map(WirelessReconnectPolicy.isNetworkSerial) == true
                publish(devices: devices, serial: requestedSerial,
                    error: connectionMode == .automatic ? (wireless ? wirelessOfflineHint : nil) : "所选连接方式不可用，正在等待连接。",
                    transportAvailable: false)
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
                publish(devices: devices, serial: device.serial, error: hint)
                reconnectWirelessDevice(devices: devices)
                return
            }
            reconnectWirelessDevice(devices: devices)
            if let error = rememberIdentity(for: device) {
                publish(devices: devices, serial: device.serial, error: error)
                return
            }
            do {
                let dump = try adb(["-s", device.serial, "shell", "dumpsys", "display"], port: route(for: device.serial), timeout: 5)
                let displays = DisplayParser.parse(dump, serial: device.serial).map { $0.identified(as: device.physicalID) }
                publish(devices: devices, displays: displays, serial: device.serial,
                        error: displays.isEmpty ? "暂时读不到设备屏幕，正在重试。" : nil)
            } catch {
                publish(devices: devices, serial: device.serial, error: error.localizedDescription)
            }
        } catch {
            _ = reconnectControl.allowsAttempt(connected: false, now: ProcessInfo.processInfo.systemUptime)
            repairIfNeeded(for: requestedSerial.flatMap { identities[$0] }, device: nil)
            publish(devices: [], serial: requestedSerial, error: error.localizedDescription)
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
            guard let hardware = try? adb(["-s", device.serial, "shell", "getprop", "ro.serialno"], port: route(for: device.serial))
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !["unknown", "null"].contains(hardware.lowercased()),
                let identity = WirelessDeviceIdentity(serialNumber: hardware) else { continue }
            // A reused wireless address must not inherit the old phone's identity.
            if device.serial == requestedSerial || privateSerials.contains(device.serial),
               let known = identities[device.serial], known.serialNumber != hardware {
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
            if privateSerials.contains(device.serial), device.isConnected, identity == nil {
                return AndroidDevice(serial: device.serial, model: device.model, connectionState: "offline",
                                     physicalSerial: identities[device.serial]?.serialNumber, transportID: device.transportID)
            }
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
        guard let previousEndpoint, requestedSerial == previousEndpoint,
              reconnectPort(for: previousEndpoint) == nil else { return }
        guard let target = reconnectPolicy.target(serial: requestedSerial, devices: devices,
            now: ProcessInfo.processInfo.systemUptime) else { return }
        // Stay on the discovery queue, bound each attempt, and let the next devices
        // poll confirm connectivity. Command output alone does not mean a live stream.
        connect(target, port: nil)
        reconnectPolicy.attemptFinished(now: ProcessInfo.processInfo.systemUptime)
    }

    private func rememberIdentity(for device: AndroidDevice) -> String? {
        guard device.isConnected, WirelessReconnectPolicy.isNetworkSerial(device.serial),
              identityAttemptedFor != device.serial else { return identityVerificationError }
        identityAttemptedFor = device.serial
        identityVerificationError = identities[device.serial] == nil ? nil : "无法核对无线设备身份，请重试。"
        guard let serialNumber = try? adb(["-s", device.serial, "shell", "getprop", "ro.serialno"], port: route(for: device.serial))
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return identityVerificationError }
        if let known = identities[device.serial], known.serialNumber != serialNumber {
            identityVerificationError = "无线地址对应的设备与记录不符，已停止自动恢复。"
            return identityVerificationError
        }
        let guid = (try? adb(["-s", device.serial, "shell", "getprop", "persist.adb.wifi.guid"], port: route(for: device.serial)))?
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

    private func reconnectPort(for endpoint: String) -> UInt16? {
        guard let wirelessADB, wirelessADB.isRunning, let identity = identities[endpoint],
              identity.serialNumber == wirelessADBIdentity?.serialNumber else { return nil }
        return wirelessADB.port
    }

    private func discoverWirelessDevice(devices: [AndroidDevice]) {
        guard connectionMode != .usb, let endpoint = requestedSerial,
              (connectionMode == .wireless && !WirelessReconnectPolicy.isNetworkSerial(endpoint)) ||
                !devices.contains(where: { $0.serial == endpoint && $0.connectionState != "offline" }),
              let identity = identities[endpoint] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastDiscoveryAt.map({ now - $0 >= 5 }) ?? true else { return }
        let port = reconnectPort(for: endpoint)
        guard port == nil || wirelessADBIsReady else { return }
        lastDiscoveryAt = now
        let services: [WirelessService]
        if port != nil {
            // Use the same Bonjour service that triggered recovery, even if the
            // replacement ADB server cannot receive mDNS announcements either.
            let resolved = advertisedServices.filter { identity.matches(serviceName: $0.name) }.flatMap(resolveBonjourService)
            services = Array(Set(resolved))
        } else if let text = try? adb(["mdns", "services"]) {
            services = WirelessService.parse(text)
        } else {
            return
        }
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
        guard candidate.endpoint != endpoint || port != nil else { pendingService = nil; return }
        guard candidateReconnectPolicy.target(serial: candidate.endpoint, devices: [], now: now) != nil else { return }
        connect(candidate.endpoint, port: port)
        candidateReconnectPolicy.attemptFinished(now: ProcessInfo.processInfo.systemUptime)
        // Do not select or stream from an announcement until authenticated shell access
        // confirms the remembered identity. Never disconnect unrelated transports.
        guard let serialNumber = try? adb(["-s", candidate.endpoint, "shell", "getprop", "ro.serialno"], port: port)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard serialNumber == identity.serialNumber else {
            // A wrong device is not a transient network error. Wait for a changed
            // announcement or explicit refresh before considering it again.
            pendingService = nil
            return
        }
        identities[candidate.endpoint] = identity
        saveIdentities()
        if candidate.endpoint != endpoint {
            replacementSerial = endpoint
            requestedSerial = candidate.endpoint
        }
        identityAttemptedFor = candidate.endpoint
        identityVerificationError = nil
        pendingService = nil
    }

    deinit { timer?.cancel() }
}
