import XCTest
@testable import ViewerCore

final class DisplayParserTests: XCTestCase {
    private let serial = "fixture-device"

    func testStoppedOutputRemainsOffEvenWhenLogicalAndOverrideInfoSayOn() throws {
        let dump = """
        Display Devices:
          DisplayDeviceInfo{"Presentation fixture", uniqueId="virtual:fixture,930", 1080 x 2400, state OFF, owner com.example.presentation (uid 10001)}
        Logical Displays:
          mBaseDisplayInfo=DisplayInfo{"Presentation fixture", displayId 17, real 1080 x 2400, state ON, uniqueId "virtual:fixture,930"}
          mOverrideDisplayInfo=DisplayInfo{"Presentation fixture", displayId 17, real 1080 x 2400, state ON, uniqueId "virtual:fixture,930"}
        """

        let display = try XCTUnwrap(DisplayParser.parse(dump, serial: serial).first)
        XCTAssertEqual(display.state, "OFF")
        XCTAssertFalse(display.isActive, "A retained logical display must not look live after its output Surface stops.")
        XCTAssertFalse(display.isMain)
        XCTAssertEqual(display.title, "副屏 17")
        XCTAssertEqual(display.owner, "com.example.presentation")
    }

    func testUsesLogicalDisplayIDInsteadOfUniqueIDSuffixOrSurfaceFlingerID() throws {
        // The long physical ID is synthetic, not captured from a device.
        let dump = """
        DisplayDeviceInfo{"Built-in Screen", uniqueId="local:9000000000000000001", 1080 x 2400, state ON}
        DisplayDeviceInfo{"Presentation fixture", uniqueId="virtual:com.example.presentation,10001,fixture,930", 1080 x 2400, state ON, owner com.example.presentation (uid 10001)}
        mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, real 1080 x 2400, state ON, uniqueId "local:9000000000000000001"}
        mBaseDisplayInfo=DisplayInfo{"Presentation fixture", displayId 17, real 1080 x 2400, state ON, uniqueId "virtual:com.example.presentation,10001,fixture,930"}
        """

        let displays = DisplayParser.parse(dump, serial: serial)
        XCTAssertEqual(displays.map(\.displayID), [0, 17])
        XCTAssertEqual(displays.last?.uniqueID, "virtual:com.example.presentation,10001,fixture,930")
    }

    func testExcludesScrcpyOwnedMirrorsWithoutHidingOtherAppsDisplays() {
        let dump = """
        DisplayDeviceInfo{"scrcpy", uniqueId="virtual:mirror", 1080 x 2400, state ON, owner com.android.shell (uid 2000)}
        DisplayDeviceInfo{"scrcpy presentation", uniqueId="virtual:presentation", 1280 x 720, state ON, owner com.example.presentation (uid 10002)}
        DisplayDeviceInfo{"Presentation", uniqueId="virtual:ordinary", 1280 x 720, state ON, owner com.example.presentation (uid 10002)}
        mBaseDisplayInfo=DisplayInfo{"scrcpy", displayId 19, real 1080 x 2400, state ON, uniqueId "virtual:mirror"}
        mBaseDisplayInfo=DisplayInfo{"scrcpy presentation", displayId 20, real 1280 x 720, state ON, uniqueId "virtual:presentation"}
        mBaseDisplayInfo=DisplayInfo{"Presentation", displayId 21, real 1280 x 720, state ON, uniqueId "virtual:ordinary"}
        """

        let displays = DisplayParser.parse(dump, serial: serial)
        XCTAssertEqual(displays.map(\.displayID), [20, 21], "Capturing the viewer's own mirrors would recursively create more streams.")
        XCTAssertFalse(displays.contains(where: \.isCaptureMirror))
    }

    func testDuplicateNamesUseUniqueIDToMatchPhysicalStateAndOwner() throws {
        let dump = """
        DisplayDeviceInfo{"Shared display name", uniqueId="virtual:first", 800 x 600, state OFF, owner com.example.presentation.first (uid 10003)}
        DisplayDeviceInfo{"Shared display name", uniqueId="virtual:second", 1600 x 900, state ON, owner com.example.presentation.second (uid 10004)}
        mBaseDisplayInfo=DisplayInfo{"Shared display name", displayId 8, real 1600 x 900, state OFF, uniqueId "virtual:second"}
        mBaseDisplayInfo=DisplayInfo{"Shared display name", displayId 7, real 800 x 600, state ON, uniqueId "virtual:first"}
        """

        let displays = DisplayParser.parse(dump, serial: serial)
        XCTAssertEqual(displays.map(\.displayID), [7, 8])
        let first = try XCTUnwrap(displays.first)
        let second = try XCTUnwrap(displays.last)
        XCTAssertEqual(first.state, "OFF")
        XCTAssertEqual(first.owner, "com.example.presentation.first")
        XCTAssertEqual(second.state, "ON")
        XCTAssertEqual(second.owner, "com.example.presentation.second")
    }

    func testEnumeratesMainAndOrdinaryVirtualDisplayWithDimensions() throws {
        let dump = """
        DisplayDeviceInfo{"Built-in Screen", uniqueId="local:screen", 1080 x 2400, state ON}
        DisplayDeviceInfo{"Slides", uniqueId="virtual:slides", 1920 x 1080, state ON, owner com.example.presentation.slides (uid 10005)}
        mBaseDisplayInfo=DisplayInfo{"Slides", displayId 6, real 1920 x 1080, state ON, uniqueId "virtual:slides"}
        mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, real 1080 x 2400, state ON, uniqueId "local:screen"}
        """

        let displays = DisplayParser.parse(dump, serial: serial)
        XCTAssertEqual(displays.count, 2)
        let main = try XCTUnwrap(displays.first)
        let secondary = try XCTUnwrap(displays.last)
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(main.title, "主屏")
        XCTAssertEqual(main.width, 1080)
        XCTAssertEqual(main.height, 2400)
        XCTAssertFalse(secondary.isMain)
        XCTAssertEqual(secondary.title, "副屏 6")
        XCTAssertTrue(secondary.isActive)
        XCTAssertEqual(secondary.width, 1920)
        XCTAssertEqual(secondary.height, 1080)
    }

    func testReusedLogicalIDWithNewUniqueIDGetsNewDisplayIdentity() throws {
        let first = try XCTUnwrap(DisplayParser.parse("""
        mBaseDisplayInfo=DisplayInfo{"Presentation", displayId 5, real 1280 x 720, state ON, uniqueId "virtual:generation-one"}
        """, serial: serial).first)
        let next = try XCTUnwrap(DisplayParser.parse("""
        mBaseDisplayInfo=DisplayInfo{"Presentation", displayId 5, real 1280 x 720, state ON, uniqueId "virtual:generation-two"}
        """, serial: serial).first)

        XCTAssertEqual(first.displayID, next.displayID)
        XCTAssertNotEqual(first.id, next.id, "A new display generation must not inherit the previous display's live stream or last frame.")
        let otherDevice = try XCTUnwrap(DisplayParser.parse("""
        mBaseDisplayInfo=DisplayInfo{"Presentation", displayId 5, real 1280 x 720, state ON, uniqueId "virtual:generation-one"}
        """, serial: "another-fixture-device").first)
        XCTAssertNotEqual(first.id, otherDevice.id)
    }

    func testIgnoresMalformedAndOverrideOnlyEntries() {
        let dump = """
        DisplayManager dump follows:
        mBaseDisplayInfo=DisplayInfo{"Missing ID", real 800 x 600, state ON}
        mBaseDisplayInfo=DisplayInfo{"Bad ID", displayId invalid, real 800 x 600, state ON}
        mOverrideDisplayInfo=DisplayInfo{"Override only", displayId 9, real 800 x 600, state ON}
        """
        XCTAssertTrue(DisplayParser.parse(dump, serial: serial).isEmpty)
    }

    func testParsesConnectedUnauthorizedAndOfflineDevicesWithoutDroppingStatus() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        fixture-usb device usb:1-1 product:fixture model:Fixture_Phone device:fixture transport_id:1
        fixture-locked unauthorized usb:1-2 transport_id:2
        fixture-offline offline transport_id:3

        """

        let devices = DeviceParser.parse(output)
        XCTAssertEqual(devices.map(\.serial), ["fixture-usb", "fixture-locked", "fixture-offline"])
        XCTAssertEqual(devices.map(\.connectionState), ["device", "unauthorized", "offline"])
        XCTAssertEqual(devices.map(\.isConnected), [true, false, false])
        XCTAssertEqual(devices.first?.model, "Fixture Phone")
        XCTAssertEqual(devices[1].model, "fixture-locked")
    }
}
