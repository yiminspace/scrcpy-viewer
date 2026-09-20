import Foundation

public struct AndroidDevice: Identifiable, Equatable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let model: String
    public let connectionState: String
    public var isConnected: Bool { connectionState == "device" }
    public init(serial: String, model: String, connectionState: String) {
        self.serial = serial; self.model = model; self.connectionState = connectionState
    }
}

public struct AndroidDisplay: Identifiable, Equatable, Sendable {
    public var id: String { "\(serial):\(displayID):\(uniqueID)" }
    public let serial: String
    public let displayID: Int
    public let name: String
    public let uniqueID: String
    public let owner: String
    public let width: Int
    public let height: Int
    public let state: String
    public var isMain: Bool { displayID == 0 }
    public var isActive: Bool { state == "ON" }
    public var isCaptureMirror: Bool { name.lowercased().hasPrefix("scrcpy") && owner == "com.android.shell" }
    public var title: String { isMain ? "主屏" : "副屏 \(displayID)" }
    public init(serial: String, displayID: Int, name: String, uniqueID: String, owner: String, width: Int, height: Int, state: String) {
        self.serial = serial; self.displayID = displayID; self.name = name
        self.uniqueID = uniqueID; self.owner = owner; self.width = width
        self.height = height; self.state = state
    }
}

public struct DiscoverySnapshot: Sendable {
    public let devices: [AndroidDevice]
    public let displays: [AndroidDisplay]
    public let selectedSerial: String?
    public let error: String?
    public init(devices: [AndroidDevice], displays: [AndroidDisplay], selectedSerial: String?, error: String? = nil) {
        self.devices = devices; self.displays = displays; self.selectedSerial = selectedSerial; self.error = error
    }
}

public struct ViewerDependencies: Sendable {
    public let adbURL: URL
    /// Present only when the server was located through a compatible desktop installation.
    public let scrcpyURL: URL?
    public let serverURL: URL
    public let serverVersion: String
    public init(adbURL: URL, scrcpyURL: URL? = nil, serverURL: URL, serverVersion: String) {
        self.adbURL = adbURL; self.scrcpyURL = scrcpyURL; self.serverURL = serverURL; self.serverVersion = serverVersion
    }
}

public enum StreamState: Equatable, Sendable {
    case starting
    case streaming
    case stopped
    case failed(String)
}
