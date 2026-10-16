import Foundation
import Darwin

/// Retry only the selected numeric network endpoint, never scan for other devices.
public struct WirelessReconnectPolicy {
    private var lastSerial: String?
    private var nextAttemptAt: TimeInterval?
    private var nextInterval: TimeInterval = 1
    private var scheduledDelay: TimeInterval?
    private let jitter: () -> Double

    public init() { jitter = { Double.random(in: 0.9...1.1) } }
    init(jitter: @escaping () -> Double) { self.jitter = jitter }

    public mutating func reset() {
        lastSerial = nil
        nextAttemptAt = nil
        nextInterval = 1
        scheduledDelay = nil
    }

    public static func isNetworkSerial(_ serial: String) -> Bool {
        guard let separator = serial.lastIndex(of: ":") else { return false }
        let portText = serial[serial.index(after: separator)...]
        guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (1...65535).contains(port) else { return false }
        let host = String(serial[..<separator])
        if host.hasPrefix("["), host.hasSuffix("]") {
            var address = in6_addr()
            return String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    public mutating func target(serial: String?, devices: [AndroidDevice], now: TimeInterval) -> String? {
        if serial != lastSerial {
            reset()
            lastSerial = serial
        }
        guard let serial, Self.isNetworkSerial(serial) else { return nil }
        if let device = devices.first(where: { $0.serial == serial }), device.connectionState != "offline" {
            // Connected and unauthorized transports need no connect command.
            reset()
            lastSerial = serial
            return nil
        }
        guard nextAttemptAt.map({ now >= $0 }) ?? true else { return nil }
        // Keep the base interval separate from jitter so randomness cannot
        // compound. The first attempt is immediate; later waits cap at 30s.
        let delay = min(30, nextInterval * min(1.1, max(0.9, jitter())))
        scheduledDelay = delay
        nextAttemptAt = now + delay
        nextInterval = min(30, nextInterval * 2)
        return serial
    }

    /// Start the waiting period after the bounded connect command completes.
    /// Its output is not proof of success; only device discovery resets backoff.
    public mutating func attemptFinished(now: TimeInterval) {
        if let scheduledDelay { nextAttemptAt = now + scheduledDelay }
    }
}
