import Foundation

public enum DeviceConnectionMode: String, CaseIterable, Sendable {
    case automatic, usb, wireless

    public var title: String {
        switch self {
        case .automatic: return "自动"
        case .usb: return "USB"
        case .wireless: return "无线"
        }
    }
}

/// Physical identity is verified through an authenticated shell, never inferred from a model or IP.
public struct PhysicalAndroidDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let transports: [AndroidDevice]
    public var model: String { transports.first(where: \.isConnected)?.model ?? transports.first?.model ?? id }
}

public enum DeviceConnectionPolicy {
    public static func groups(_ devices: [AndroidDevice]) -> [PhysicalAndroidDevice] {
        var order: [String] = []
        var members: [String: [AndroidDevice]] = [:]
        for device in devices {
            if members[device.physicalID] == nil { order.append(device.physicalID) }
            members[device.physicalID, default: []].append(device)
        }
        return order.map { PhysicalAndroidDevice(id: $0, transports: members[$0]!) }
    }

    /// Auto stays on a working connection. USB wins only for an initial choice or recovery.
    public static func select(from devices: [AndroidDevice], current: String?, mode: DeviceConnectionMode) -> AndroidDevice? {
        let physicalID = current.flatMap { serial in devices.first { $0.serial == serial }?.physicalID }
        let candidates = devices.filter {
            (physicalID == nil || $0.physicalID == physicalID) &&
            (mode == .automatic || (mode == .wireless ? $0.isWireless : !$0.isWireless))
        }
        if let current, let working = candidates.first(where: { $0.serial == current && $0.isConnected }) {
            return working
        }
        return candidates.filter(\.isConnected).sorted {
            if $0.isWireless != $1.isWireless { return !$0.isWireless }
            return $0.serial < $1.serial
        }.first ?? candidates.first(where: { $0.serial == current }) ?? candidates.first
    }
}
