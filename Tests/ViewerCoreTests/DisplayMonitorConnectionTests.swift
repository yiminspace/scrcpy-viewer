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

    func testWirelessRepairRejectsWrongDeviceAndRecoversChangedPort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ text: String, _ file: String) throws {
            try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let adb = root.appendingPathComponent("adb")
        try write(#"""
        #!/bin/sh
        root="$(dirname "$0")"
        case "$*" in
          'version') echo 'Version 37.0.1-example'; exit ;;
          '-L tcp:localhost:'*' server nodaemon')
            [ "$ADB_USB/$ADB_EMU/$ADB_MDNS/$ADB_MDNS_AUTO_CONNECT" = 0/0/0/0 ] || exit 1
            echo "$$" >> "$root/owned-pids"
            rm -f "$root/connected" "$root/block-connect"
            exec /bin/sleep 120 ;;
          'devices -l') echo 'List of devices attached'; exit ;;
        esac
        case "$2" in tcp:127.0.0.1:*) shift 2 ;; *) exit 1 ;; esac
        case "$*" in
          'devices -l')
            echo 'List of devices attached'
            endpoint="$(cat "$root/endpoint")"
            if [ "$(cat "$root/connected" 2>/dev/null)" = "$endpoint" ]; then
              echo "$endpoint device model:Example_Phone transport_id:1"
            fi ;;
          'connect '*) [ ! -f "$root/block-connect" ] && printf '%s\n' "$2" > "$root/connected" ;;
          *'shell getprop ro.serialno') cat "$root/hardware" ;;
          *'shell getprop persist.adb.wifi.guid') echo '' ;;
          *'shell dumpsys display') cat "$root/display" ;;
          *) exit 1 ;;
        esac
        """#, "adb")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        try write("""
        DisplayDeviceInfo{"Built-in Screen", uniqueId="local:fixture", 1080 x 2400, state ON}
        mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, real 1080 x 2400, state ON, uniqueId "local:fixture"}
        """, "display")
        let first = "192.0.2.1:40000"
        let second = "192.0.2.1:40001"
        try write(first, "endpoint")
        try write("wrong-phone", "hardware")

        let suite = "WirelessRepairFixture-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "phone-one"))
        preferences.set(try JSONEncoder().encode([first: identity]), forKey: "wirelessDeviceIdentities.v1")
        let snapshots = Snapshots()
        let monitor = DisplayMonitor(dependencies: ViewerDependencies(adbURL: adb, serverURL: root, serverVersion: "3.3.3"),
            preferences: preferences, makeBrowser: { queue, onChange in
                queue.async { onChange([.init(name: "adb-phone-one-000000", interfaceIndex: 0)]) }
                return NSObject()
            }, resolveBonjourService: { service in
                guard let endpoint = try? String(contentsOf: root.appendingPathComponent("endpoint"), encoding: .utf8) else { return [] }
                return WirelessService.parse("\(service.name)\t_adb-tls-connect._tcp\t\(endpoint)")
            }, onUpdate: snapshots.append)
        defer {
            monitor.stop()
            let stopped = expectation(description: "owned ADB stopped")
            monitor.finishShutdown { stopped.fulfill() }
            wait(for: [stopped], timeout: 5)
        }
        monitor.selectDevice(first)
        monitor.start()
        let rejected = try snapshots.wait(after: 0) {
            $0.devices.contains { $0.connectionState == "identity-mismatch" }
        }
        XCTAssertTrue(rejected.displays.isEmpty)

        // A changed advertisement must be authenticated before the saved address changes.
        try write("phone-one", "hardware")
        try write(second, "endpoint")
        let recovered = try snapshots.wait(after: 0) { $0.selectedSerial == second && !$0.displays.isEmpty }
        XCTAssertEqual(recovered.replacingSerial, first)
        XCTAssertNotNil(recovered.wirelessADBPort)
        XCTAssertFalse(recovered.canRepairWireless)

        let revision = snapshots.count
        let third = "192.0.2.1:40002"
        try write("", "block-connect")
        try write(third, "endpoint")
        _ = try snapshots.wait(after: revision) { $0.canRepairWireless && $0.displays.isEmpty }
        monitor.repairWirelessConnection()
        let repaired = try snapshots.wait(after: revision) { $0.selectedSerial == third && !$0.displays.isEmpty }
        XCTAssertNotNil(repaired.wirelessADBPort)
        let ownedPIDs = try String(contentsOf: root.appendingPathComponent("owned-pids"), encoding: .utf8)
        XCTAssertEqual(Set(ownedPIDs.split(whereSeparator: \.isNewline)).count, 2)
    }

}
