import Foundation
import Darwin

/// A remembered device identity, learned only from an already selected, online transport.
public struct WirelessDeviceIdentity: Codable, Equatable {
    public let serialNumber: String
    public let serviceNames: [String]

    public init?(serialNumber: String, wifiGUID: String = "") {
        guard Self.isIdentifier(serialNumber) else { return nil }
        self.serialNumber = serialNumber
        self.serviceNames = ["adb-" + serialNumber] + (Self.isIdentifier(wifiGUID) ? [wifiGUID] : [])
    }

    public func matches(serviceName: String) -> Bool {
        if serviceNames.contains(serviceName) { return true }
        // Some Android builds hide the Wi-Fi GUID property from the shell. The
        // platform-generated name still contains the full serial and a six-character suffix.
        let prefix = "adb-" + serialNumber + "-"
        guard serviceName.hasPrefix(prefix) else { return false }
        let suffix = serviceName.dropFirst(prefix.count)
        return suffix.count == 6 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }
    }
}

public struct WirelessService: Equatable, Hashable {
    public let name: String
    public let type: String
    public let endpoint: String

    private static func isUnicastEndpoint(_ endpoint: String) -> Bool {
        guard let separator = endpoint.lastIndex(of: ":") else { return false }
        let host = String(endpoint[..<separator])
        if !host.hasPrefix("[") {
            guard let first = host.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
            return first > 0 && first != 127 && first < 224
        }
        let address = String(host.dropFirst().dropLast()).lowercased()
        // Discovery can transiently return an unspecified address before resolution completes.
        var bytes = in6_addr()
        let valid = address.withCString { inet_pton(AF_INET6, $0, &bytes) == 1 }
        guard valid else { return false }
        return withUnsafeBytes(of: &bytes) { raw in
            let values = Array(raw)
            let unspecified = values.allSatisfy { $0 == 0 }
            let loopback = values.dropLast().allSatisfy { $0 == 0 } && values.last == 1
            return !unspecified && !loopback && values.first != 0xff
        }
    }

    /// Parse only adb connection services, never pairing endpoints or arbitrary hostnames.
    public static func parse(_ text: String) -> [WirelessService] {
        let parsed: [WirelessService] = text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count == 3 else { return nil }
            let type = columns[1].hasSuffix(".") ? String(columns[1].dropLast()) : columns[1]
            guard ["_adb._tcp", "_adb-tls-connect._tcp"].contains(type),
                  WirelessReconnectPolicy.isNetworkSerial(columns[2]),
                  isUnicastEndpoint(columns[2]) else { return nil }
            return WirelessService(name: columns[0], type: type, endpoint: columns[2])
        }
        // adb can report the same announcement through multiple interfaces.
        var seen = Set<WirelessService>()
        return parsed.filter { seen.insert($0).inserted }
    }
}

/// Announcements are hints: the transport must still authenticate and its serial must be checked.
public struct WirelessDiscoveryPolicy {
    private var previous: [WirelessService] = []
    public init() {}
    public mutating func reset() { previous = [] }

    public static func matching(services: [WirelessService], identity: WirelessDeviceIdentity) -> [WirelessService] {
        let matching = services.filter { identity.matches(serviceName: $0.name) }
        let tls = matching.filter { $0.type == "_adb-tls-connect._tcp" }
        return tls.isEmpty ? matching : tls
    }

    public mutating func candidate(services: [WirelessService], identity: WirelessDeviceIdentity) -> WirelessService? {
        let matching = Self.matching(services: services, identity: identity)
        defer { previous = matching }
        // Ambiguous announcements must never cause an automatic device switch.
        guard matching.count == 1, let service = matching.first,
              !previous.contains(service) else { return nil }
        return service
    }
}
