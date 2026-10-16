import XCTest
@testable import ViewerCore

final class WirelessDiscoveryTests: XCTestCase {
    func testOnlyConnectionServicesWithValidNumericEndpointsAreAccepted() {
        let services = WirelessService.parse("""
        List of discovered mdns services
        adb-test _adb._tcp 192.0.2.10:5555
        adb-test-guid _adb-tls-connect._tcp. [2001:db8::1]:43210
        adb-test _adb-tls-pairing._tcp 192.0.2.10:40000
        adb-test _adb._tcp invalid:5555
        adb-test _adb._tcp 192.0.2.10:0
        adb-test _other._tcp 192.0.2.10:5555
        """)
        XCTAssertEqual(services.map(\.endpoint), ["192.0.2.10:5555", "[2001:db8::1]:43210"])
    }

    func testOnlyRememberedIdentityCanProduceCandidateAndAmbiguityFailsClosed() throws {
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone", wifiGUID: "adb-test-phone-guid"))
        var policy = WirelessDiscoveryPolicy()
        let stranger = WirelessService.parse("adb-other _adb._tcp 192.0.2.20:5555")
        XCTAssertNil(policy.candidate(services: stranger, identity: identity))
        let known = WirelessService.parse("adb-test-phone _adb._tcp 192.0.2.30:5555")
        XCTAssertEqual(policy.candidate(services: known + stranger, identity: identity)?.endpoint, "192.0.2.30:5555")
        XCTAssertNil(policy.candidate(services: known + stranger, identity: identity))
        let duplicate = WirelessService.parse("adb-test-phone _adb._tcp 192.0.2.40:5555")
        XCTAssertNil(policy.candidate(services: known + duplicate, identity: identity))
    }

    func testDisappearanceReappearanceAndAddressChangeWakeRetries() throws {
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone"))
        var policy = WirelessDiscoveryPolicy()
        let original = WirelessService.parse("adb-test-phone _adb._tcp 192.0.2.10:5555")
        XCTAssertNotNil(policy.candidate(services: original, identity: identity))
        XCTAssertNil(policy.candidate(services: original, identity: identity))
        XCTAssertNil(policy.candidate(services: [], identity: identity))
        XCTAssertNotNil(policy.candidate(services: original, identity: identity))
        let changed = WirelessService.parse("adb-test-phone _adb._tcp 192.0.2.11:5555")
        XCTAssertEqual(policy.candidate(services: changed, identity: identity)?.endpoint, "192.0.2.11:5555")
        policy.reset()
        XCTAssertNotNil(policy.candidate(services: changed, identity: identity))
    }

    func testUnresolvedAndNonUnicastAnnouncementsNeverConnect() {
        for endpoint in ["0.0.0.0:43210", "127.0.0.1:43210", "224.0.0.251:43210", "255.255.255.255:43210",
                         "[::]:43210", "[0:0:0:0:0:0:0:0]:43210", "[::1]:43210", "[ff02::fb]:43210"] {
            XCTAssertTrue(WirelessService.parse("adb-test-phone _adb._tcp " + endpoint).isEmpty, endpoint)
        }
    }

    func testDuplicateInterfacesCollapseAndTLSIsPreferredWithoutReadableGUID() throws {
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone"))
        let services = WirelessService.parse("""
        adb-test-phone _adb._tcp 192.0.2.10:5555
        adb-test-phone-Ab12Cd _adb-tls-connect._tcp 192.0.2.10:43210
        adb-test-phone-Ab12Cd _adb-tls-connect._tcp 192.0.2.10:43210
        adb-test-phone-extra-Ab12Cd _adb-tls-connect._tcp 192.0.2.20:43210
        """)
        XCTAssertEqual(services.count, 3)
        var policy = WirelessDiscoveryPolicy()
        XCTAssertEqual(policy.candidate(services: services, identity: identity)?.endpoint, "192.0.2.10:43210")
        XCTAssertNil(policy.candidate(services: services, identity: identity))
        XCTAssertFalse(identity.matches(serviceName: "adb-test-phone-Ab12C"))
        XCTAssertFalse(identity.matches(serviceName: "adb-test-phone-Ab12C-"))
    }

    func testIdentityRoundTripAndInvalidSerials() throws {
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone", wifiGUID: "adb-test-phone-guid"))
        XCTAssertEqual(try JSONDecoder().decode(WirelessDeviceIdentity.self,
            from: JSONEncoder().encode(identity)), identity)
        for serial in ["", "test phone", "test\nphone", "$(command)"] {
            XCTAssertNil(WirelessDeviceIdentity(serialNumber: serial))
        }
    }

    func testMonitorMigratesOnlyAfterMatchingAuthenticatedSerial() throws {
        try checkMigration(returnedSerial: "test-phone", failFirstProbe: false, shouldMigrate: true)
    }

    func testMonitorDoesNotSwitchToDeviceWithMismatchedSerial() throws {
        try checkMigration(returnedSerial: "other-phone", failFirstProbe: false, shouldMigrate: false)
    }

    func testTransientProbeFailureRetriesUnchangedAdvertisement() throws {
        try checkMigration(returnedSerial: "test-phone", failFirstProbe: true, shouldMigrate: true)
    }

    private func checkMigration(returnedSerial: String, failFirstProbe: Bool, shouldMigrate: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "wireless-discovery-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let identity = try XCTUnwrap(WirelessDeviceIdentity(serialNumber: "test-phone"))
        preferences.set(try JSONEncoder().encode(["192.0.2.10:5555": identity]), forKey: "wirelessDeviceIdentities.v1")
        let adb = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        printf '%s\\n' "$*" >> commands
        case "$1" in
          devices)
            printf 'List of devices attached\\n'
            if [ -f connected ]; then printf '192.0.2.20:5555 device model:Test\\n'; fi
            ;;
          mdns) printf 'adb-test-phone _adb._tcp 192.0.2.20:5555\\n' ;;
          connect) if [ "$2" = '192.0.2.20:5555' ]; then touch connected; fi ;;
          -s)
            if [ "$2" = '192.0.2.20:5555' ] && [ "$5" = 'ro.serialno' ]; then
              if [ '\(failFirstProbe)' = true ] && [ ! -f probed ]; then touch probed; exit 1; fi
              printf '%s\\n' '\(returnedSerial)'
            fi
            ;;
        esac
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        let completed = expectation(description: "Identity checked before selection changes")
        completed.assertForOverFulfill = false
        var snapshots = 0
        let dependencies = ViewerDependencies(adbURL: adb, serverURL: directory.appendingPathComponent("server"), serverVersion: "3.3.3")
        let monitor = DisplayMonitor(dependencies: dependencies, preferences: preferences) { snapshot in
            snapshots += 1
            if shouldMigrate {
                if snapshot.selectedSerial == "192.0.2.20:5555" {
                    XCTAssertEqual(snapshot.replacingSerial, "192.0.2.10:5555")
                    completed.fulfill()
                }
            } else {
                XCTAssertEqual(snapshot.selectedSerial, "192.0.2.10:5555")
                if snapshots >= 2 { completed.fulfill() }
            }
        }
        monitor.selectDevice("192.0.2.10:5555")
        monitor.start()
        wait(for: [completed], timeout: 10)
        monitor.stop()
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        XCTAssertTrue(commands.contains("-s 192.0.2.20:5555 shell getprop ro.serialno"))
        XCTAssertFalse(commands.contains("kill-server"))
        XCTAssertFalse(commands.contains("disconnect"))
        if !shouldMigrate { XCTAssertFalse(commands.contains("shell dumpsys display")) }
    }

}
