import XCTest
@testable import ViewerCore

final class WirelessReconnectControlTests: XCTestCase {
    func testTimeoutStopsAttemptsUntilExplicitResume() {
        var control = WirelessReconnectControl(timeout: 600)
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 0))
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 599))
        XCTAssertFalse(control.allowsAttempt(connected: false, now: 600))
        XCTAssertEqual(control.status, .timedOut)
        XCTAssertFalse(control.allowsAttempt(connected: false, now: 1_000))
        control.resume()
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 1_001))
        XCTAssertEqual(control.status, .automatic)
    }

    func testManualPauseSurvivesConnectedPollsAndResumeStartsFreshWindow() {
        var control = WirelessReconnectControl(timeout: 10)
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 0))
        control.pause()
        XCTAssertFalse(control.allowsAttempt(connected: false, now: 1))
        XCTAssertFalse(control.allowsAttempt(connected: true, now: 2))
        XCTAssertEqual(control.status, .paused)
        control.resume()
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 100))
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 109))
        XCTAssertFalse(control.allowsAttempt(connected: false, now: 110))
    }

    func testExternalConnectionClearsAutomaticTimeout() {
        var control = WirelessReconnectControl(timeout: 10)
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 0))
        XCTAssertFalse(control.allowsAttempt(connected: false, now: 10))
        XCTAssertFalse(control.allowsAttempt(connected: true, now: 11))
        XCTAssertEqual(control.status, .automatic)
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 20))
        XCTAssertTrue(control.allowsAttempt(connected: false, now: 29))
    }

    func testMonitorPauseBlocksConnectAndDiscoveryUntilManualRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "wireless-control-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone"))
        preferences.set(try JSONEncoder().encode(["192.0.2.10:5555": identity]), forKey: "wirelessDeviceIdentities.v1")
        let adb = directory.appendingPathComponent("adb")
        try """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        printf '%s\\n' "$*" >> commands
        if [ "$1" = devices ]; then printf 'List of devices attached\\n'; fi
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        let paused = expectation(description: "Paused snapshot")
        let resumed = expectation(description: "Resumed snapshot")
        paused.assertForOverFulfill = false
        resumed.assertForOverFulfill = false
        let dependencies = ViewerDependencies(adbURL: adb, serverURL: directory.appendingPathComponent("server"), serverVersion: "3.3.3")
        let monitor = DisplayMonitor(dependencies: dependencies, preferences: preferences) { snapshot in
            if snapshot.reconnectStatus == .paused { paused.fulfill() }
            if snapshot.reconnectStatus == .automatic { resumed.fulfill() }
        }
        monitor.selectDevice("192.0.2.10:5555")
        monitor.pauseWirelessReconnect()
        monitor.start()
        wait(for: [paused], timeout: 3)
        let pausedCommands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        XCTAssertFalse(pausedCommands.contains("connect "))
        XCTAssertFalse(pausedCommands.contains("mdns services"))
        monitor.refresh()
        wait(for: [resumed], timeout: 3)
        // Wait for the subsequent poll, which follows the resumed connect command.
        let nextPoll = expectation(description: "Following poll")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { nextPoll.fulfill() }
        wait(for: [nextPoll], timeout: 3)
        monitor.stop()
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        XCTAssertTrue(commands.contains("connect 192.0.2.10:5555"))
        XCTAssertTrue(commands.contains("mdns services"))
    }
}
