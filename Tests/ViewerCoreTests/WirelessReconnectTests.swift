import XCTest
@testable import ViewerCore

final class WirelessReconnectTests: XCTestCase {
    private let endpoint = "192.0.2.10:5555"

    func testAcceptsOnlyNumericNetworkEndpoints() {
        for serial in [endpoint, "[2001:db8::1]:5555"] {
            XCTAssertTrue(WirelessReconnectPolicy.isNetworkSerial(serial), serial)
        }
        for serial in ["usb-device", "192.0.2.10", "192.0.2.10:0", "192.0.2.10:65536",
                       "192.0.2.10:+5555", "192.0.2.999:5555", "--help:5555", "host:5555",
                       "adb-example._adb-tls-connect._tcp", "[invalid]:5555", "192.0.2.10:5555\n"] {
            XCTAssertFalse(WirelessReconnectPolicy.isNetworkSerial(serial), serial)
        }
    }

    func testMissingAndOfflineRetryWithExponentialBackoffAndCap() {
        var policy = WirelessReconnectPolicy(jitter: { 1 })
        XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: 0), endpoint)
        let offline = AndroidDevice(serial: endpoint, model: "Test", connectionState: "offline")
        var now: TimeInterval = 0
        for interval in [TimeInterval]([1, 2, 4, 8, 16, 30, 30, 30]) {
            // A slow attempt must not consume its own waiting period.
            let finished = now + 2
            policy.attemptFinished(now: finished)
            XCTAssertNil(policy.target(serial: endpoint, devices: [offline], now: finished + interval - 0.001))
            now = finished + interval
            XCTAssertEqual(policy.target(serial: endpoint, devices: [offline], now: now), endpoint)
        }
    }

    func testJitterBoundsAndCap() {
        for factor in [0.9, 1.1] {
            var policy = WirelessReconnectPolicy(jitter: { factor })
            var now: TimeInterval = 0
            XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: now), endpoint)
            for interval in [TimeInterval]([1, 2, 4, 8, 16, 30, 30]) {
                let delay = min(30, interval * factor)
                XCTAssertNil(policy.target(serial: endpoint, devices: [], now: now + delay - 0.001))
                now += delay
                XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: now), endpoint)
            }
        }
    }

    func testManualRetryResetsLongBackoff() {
        var policy = WirelessReconnectPolicy(jitter: { 1 })
        for now in [TimeInterval]([0, 1, 3, 7, 15, 31]) {
            XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: now), endpoint)
        }
        XCTAssertNil(policy.target(serial: endpoint, devices: [], now: 32))
        policy.reset()
        XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: 32), endpoint)
        XCTAssertNil(policy.target(serial: endpoint, devices: [], now: 32.999))
        XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: 33), endpoint)
    }

    func testConnectedUnauthorizedUSBAndNoSelectionNeverConnect() {
        var policy = WirelessReconnectPolicy()
        for state in ["device", "unauthorized"] {
            let device = AndroidDevice(serial: endpoint, model: "Test", connectionState: state)
            XCTAssertNil(policy.target(serial: endpoint, devices: [device], now: 0))
        }
        XCTAssertNil(policy.target(serial: "usb-device", devices: [], now: 0))
        XCTAssertNil(policy.target(serial: nil, devices: [], now: 0))
    }

    func testSelectionAndSuccessfulConnectionResetRetryDelay() {
        var policy = WirelessReconnectPolicy(jitter: { 1 })
        for now in [TimeInterval]([0, 1, 3, 7, 15, 31]) {
            XCTAssertEqual(policy.target(serial: endpoint, devices: [], now: now), endpoint)
        }
        let other = "192.0.2.20:5555"
        XCTAssertEqual(policy.target(serial: other, devices: [], now: 32), other)
        XCTAssertNil(policy.target(serial: other, devices: [], now: 32.999))
        XCTAssertEqual(policy.target(serial: other, devices: [], now: 33), other)
        let connected = AndroidDevice(serial: other, model: "Test", connectionState: "device")
        XCTAssertNil(policy.target(serial: other, devices: [connected], now: 34))
        XCTAssertEqual(policy.target(serial: other, devices: [], now: 35), other)
        XCTAssertNil(policy.target(serial: other, devices: [], now: 35.999))
        XCTAssertEqual(policy.target(serial: other, devices: [], now: 36), other)
        // An unrelated connected device must not replace the requested endpoint.
        XCTAssertEqual(policy.target(serial: endpoint, devices: [connected], now: 37), endpoint)
    }

    func testMonitorConnectsOnlySelectedEndpointAndConfirmsOnNextPoll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        printf '%s\\n' "$*" >> commands
        case "$1" in
          devices)
            printf 'List of devices attached\\n'
            if [ -f connected ]; then printf '192.0.2.10:5555 device model:Test\\n'; fi
            ;;
          connect) touch connected ;;
        esac
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        let disconnected = expectation(description: "Disconnected before connect is confirmed")
        let connected = expectation(description: "Connected on a subsequent devices poll")
        disconnected.assertForOverFulfill = false
        connected.assertForOverFulfill = false
        let dependencies = ViewerDependencies(adbURL: adb, serverURL: directory.appendingPathComponent("server"), serverVersion: "3.3.3")
        let monitor = DisplayMonitor(dependencies: dependencies) { snapshot in
            XCTAssertEqual(snapshot.selectedSerial, self.endpoint)
            if snapshot.devices.contains(where: \.isConnected) { connected.fulfill() }
            else { disconnected.fulfill() }
        }
        monitor.selectDevice(endpoint)
        monitor.start()
        wait(for: [disconnected, connected], timeout: 5, enforceOrder: true)
        monitor.stop()
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(commands.prefix(3), ["devices -l", "connect \(endpoint)", "devices -l"])
        XCTAssertEqual(commands.filter { $0.hasPrefix("connect ") }, ["connect \(endpoint)"])
        XCTAssertTrue(commands.allSatisfy {
            $0 == "devices -l" || $0 == "connect \(endpoint)" || $0 == "-s \(endpoint) shell dumpsys display" ||
                $0 == "-s \(endpoint) shell getprop ro.serialno" || $0 == "-s \(endpoint) shell getprop persist.adb.wifi.guid"
        })
    }
}
