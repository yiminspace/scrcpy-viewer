import Foundation
import XCTest
@testable import ViewerCore

final class DisplayMonitorConnectionTests: XCTestCase {
    private final class Snapshots {
        let lock = NSLock()
        var values: [DiscoverySnapshot] = []
        func append(_ snapshot: DiscoverySnapshot) {
            lock.lock(); defer { lock.unlock() }
            values.append(snapshot)
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return values.count
        }
        func wait(after count: Int, matching: (DiscoverySnapshot) -> Bool) throws -> DiscoverySnapshot {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                lock.lock()
                let found = values.dropFirst(count).first(where: matching)
                lock.unlock()
                if let found { return found }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw NSError(domain: "MonitorFixtureTimeout", code: 1)
        }
    }

    func testTransportSwitchFailoverAndReusedAddressKeepPhysicalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("adb")
        try """
        #!/bin/sh
        root="$(dirname "$0")"
        case "$*" in
          'devices -l') cat "$root/devices" ;;
          '-s usb-one shell getprop ro.serialno') echo phone-one ;;
          '-s other-usb shell getprop ro.serialno') echo phone-two ;;
          '-s 192.0.2.1:40000 shell getprop ro.serialno') cat "$root/wireless-identity" ;;
          *'shell getprop persist.adb.wifi.guid') echo '' ;;
          *'shell dumpsys display') cat "$root/display" ;;
          *) exit 1 ;;
        esac
        """.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        try "phone-one\n".write(to: root.appendingPathComponent("wireless-identity"), atomically: true, encoding: .utf8)
        try """
        DisplayDeviceInfo{"Built-in Screen", uniqueId="local:fixture", 1080 x 2400, state ON}
        mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, real 1080 x 2400, state ON, uniqueId "local:fixture"}
        """.write(to: root.appendingPathComponent("display"), atomically: true, encoding: .utf8)
        let usb = "usb-one device model:Example_Phone transport_id:1"
        let wireless = "192.0.2.1:40000 device model:Example_Phone transport_id:2"
        func setDevices(_ rows: [String]) throws {
            try ("List of devices attached\n" + rows.joined(separator: "\n") + "\n")
                .write(to: root.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
        }
        try setDevices([usb, wireless])
        let suite = "DeviceConnectionFixture-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let snapshots = Snapshots()
        let monitor = DisplayMonitor(dependencies: ViewerDependencies(adbURL: adb, serverURL: root, serverVersion: "3.3.3"),
                                     preferences: preferences, onUpdate: snapshots.append)
        defer { monitor.stop() }
        monitor.start()
        let initial = try snapshots.wait(after: 0) { $0.selectedSerial == "usb-one" && !$0.displays.isEmpty }
        XCTAssertEqual(DeviceConnectionPolicy.groups(initial.devices).count, 1)
        let displayID = try XCTUnwrap(initial.displays.first?.id)

        var revision = snapshots.count
        monitor.setConnectionMode(.wireless)
        let switched = try snapshots.wait(after: revision) { $0.selectedSerial == "192.0.2.1:40000" && !$0.displays.isEmpty }
        XCTAssertEqual(switched.replacingSerial, "usb-one")
        XCTAssertEqual(switched.displays.first?.id, displayID)

        revision = snapshots.count
        monitor.setConnectionMode(.automatic)
        _ = try snapshots.wait(after: revision) { $0.selectedSerial == "192.0.2.1:40000" && !$0.displays.isEmpty }
        revision = snapshots.count
        try setDevices([usb])
        monitor.refresh()
        let fallback = try snapshots.wait(after: revision) { $0.selectedSerial == "usb-one" && !$0.displays.isEmpty }
        XCTAssertEqual(fallback.displays.first?.id, displayID)

        revision = snapshots.count
        try setDevices(["other-usb device model:Example_Phone transport_id:3"])
        monitor.refresh()
        let lost = try snapshots.wait(after: revision) { $0.selectedSerial == "usb-one" && $0.displays.isEmpty }
        XCTAssertFalse(lost.devices.first { $0.serial == lost.selectedSerial }?.isConnected ?? true)

        try setDevices([wireless])
        revision = snapshots.count
        monitor.refresh()
        _ = try snapshots.wait(after: revision) { $0.selectedSerial == "192.0.2.1:40000" && !$0.displays.isEmpty }
        try "phone-two\n".write(to: root.appendingPathComponent("wireless-identity"), atomically: true, encoding: .utf8)
        try setDevices([wireless.replacingOccurrences(of: "transport_id:2", with: "transport_id:4")])
        revision = snapshots.count
        monitor.refresh()
        let reused = try snapshots.wait(after: revision) { $0.devices.contains { $0.connectionState == "identity-mismatch" } }
        XCTAssertTrue(reused.displays.isEmpty)
    }
}
