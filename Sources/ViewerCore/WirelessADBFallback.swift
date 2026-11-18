import Darwin
import dnssd
import Foundation
import Network

/// One foreground ADB server, owned by the Viewer. All clients use an explicit
/// non-local socket spelling so a failed connection cannot spawn a replacement.
final class WirelessADBServer {
    let port: UInt16
    private let process: Process

    var isRunning: Bool { process.isRunning }

    init(dependencies: ViewerDependencies) throws {
        let version = try CommandRunner.checked(executable: dependencies.adbURL, arguments: ["version"], timeout: 2)
        // Require the platform-tools generation supporting both ADB_USB and ADB_EMU.
        guard let line = version.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Version ") }),
              let major = Int(line.dropFirst("Version ".count).prefix(while: { $0.isNumber })), major >= 37 else {
            throw ViewerError.message("修复无线连接需要 Android SDK Platform-Tools 37 或更新版本。")
        }
        port = try Self.availablePort()
        process = Process()
        process.executableURL = dependencies.adbURL
        process.arguments = ["-L", "tcp:localhost:\(port)", "server", "nodaemon"]
        var environment = ProcessInfo.processInfo.environment
        environment["ADB_USB"] = "0"
        environment["ADB_EMU"] = "0"
        environment["ADB_MDNS"] = "0"
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ViewerError.message("无法为无线 ADB 分配本地端口。") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        let port: UInt16? = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(fd, $0, length) == 0, getsockname(fd, $0, &length) == 0 else { return nil }
                return UInt16(bigEndian: pointer.pointee.sin_port)
            }
        }
        guard let port, port != 0 else { throw ViewerError.message("无法为无线 ADB 分配本地端口。") }
        return port
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

/// Use the system resolver to detect a known phone even when shared ADB's mDNS is unhealthy.
final class WirelessADBBrowser {
    struct Service: Hashable {
        let name: String
        let interfaceIndex: UInt32
    }

    private let browser: NWBrowser

    init(queue: DispatchQueue, onChange: @escaping (Set<Service>) -> Void) {
        browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."), using: .udp)
        browser.browseResultsChangedHandler = { results, _ in
            onChange(Set(results.compactMap { result in
                guard case let .service(name, _, _, interface) = result.endpoint else { return nil }
                return Service(name: name, interfaceIndex: UInt32(interface?.index ?? 0))
            }))
        }
        browser.start(queue: queue)
    }

    deinit { browser.cancel() }

    private final class Lookup {
        var host: String?
        var port: UInt16 = 0
        var addresses = Set<String>()
        var complete = false
    }

    /// Resolve through macOS's DNS-SD cache, independently of adb's mDNS backend.
    static func resolve(_ service: Service) -> [WirelessService] {
        let lookup = Lookup()
        let context = Unmanaged.passUnretained(lookup).toOpaque()
        var reference: DNSServiceRef?
        let status = DNSServiceResolve(&reference, 0, service.interfaceIndex, service.name,
                                      "_adb-tls-connect._tcp", "local.", { _, flags, _, error, _, host, port, _, _, context in
            guard let context else { return }
            let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
            if error == kDNSServiceErr_NoError, let host {
                lookup.host = String(cString: host)
                lookup.port = UInt16(bigEndian: port)
            }
            lookup.complete = error != kDNSServiceErr_NoError || flags & UInt32(kDNSServiceFlagsMoreComing) == 0
        }, context)
        guard status == kDNSServiceErr_NoError, let reference else { return [] }
        readResult(reference, lookup: lookup)
        guard let host = lookup.host, lookup.port != 0 else { return [] }

        // Prefer IPv4 when a dual-stack service advertises both addresses. A
        // link-local IPv6 result needs a scope, which numeric adb endpoints omit.
        for addressFamily in [kDNSServiceProtocol_IPv4, kDNSServiceProtocol_IPv6] {
            lookup.complete = false
            var addressRef: DNSServiceRef?
            let result = DNSServiceGetAddrInfo(&addressRef, 0, service.interfaceIndex, UInt32(addressFamily),
                                               host, { _, flags, _, error, _, address, _, context in
                guard let context else { return }
                let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_NoError, let address, flags & UInt32(kDNSServiceFlagsAdd) != 0 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let numeric = String(cString: host)
                        if !numeric.contains("%") {
                            lookup.addresses.insert(address.pointee.sa_family == AF_INET6 ? "[\(numeric)]" : numeric)
                        }
                    }
                }
                lookup.complete = error != kDNSServiceErr_NoError || flags & UInt32(kDNSServiceFlagsMoreComing) == 0
            }, context)
            if result == kDNSServiceErr_NoError, let addressRef { readResult(addressRef, lookup: lookup) }
            if !lookup.addresses.isEmpty { break }
        }
        let records = lookup.addresses.map { "\(service.name)\t_adb-tls-connect._tcp\t\($0):\(lookup.port)" }
        return WirelessService.parse(records.sorted().joined(separator: "\n"))
    }

    private static func readResult(_ reference: DNSServiceRef, lookup: Lookup) {
        defer { DNSServiceRefDeallocate(reference) }
        var descriptor = pollfd(fd: DNSServiceRefSockFD(reference), events: Int16(POLLIN), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        while !lookup.complete {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, Darwin.poll(&descriptor, 1, Int32(max(1, remaining * 1000))) > 0,
                  descriptor.revents & Int16(POLLIN) != 0,
                  DNSServiceProcessResult(reference) == kDNSServiceErr_NoError else { return }
        }
    }
}
