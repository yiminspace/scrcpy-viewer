import Foundation

public enum WirelessReconnectStatus: String, Sendable {
    case automatic, paused, timedOut
}

/// Limits an offline reconnect session without closing any existing transport.
public struct WirelessReconnectControl {
    public private(set) var status: WirelessReconnectStatus = .automatic
    private var offlineSince: TimeInterval?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 600) { self.timeout = timeout }

    public mutating func pause() { status = .paused; offlineSince = nil }
    public mutating func resume() { status = .automatic; offlineSince = nil }

    public mutating func allowsAttempt(connected: Bool, now: TimeInterval) -> Bool {
        if connected {
            offlineSince = nil
            if status == .timedOut { status = .automatic }
            return false
        }
        guard status == .automatic else { return false }
        if offlineSince == nil { offlineSince = now }
        if let offlineSince, now - offlineSince >= timeout {
            status = .timedOut
            return false
        }
        return true
    }
}
