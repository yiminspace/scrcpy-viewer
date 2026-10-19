import XCTest
@testable import ViewerCore

final class DeviceConnectionPolicyTests: XCTestCase {
    private func device(_ serial: String, physical: String? = "phone-one", state: String = "device") -> AndroidDevice {
        AndroidDevice(serial: serial, model: "Example Phone", connectionState: state, physicalSerial: physical)
    }

    func testVerifiedPhysicalIdentityGroupsTransportsButNeverModelsOrUnknownIdentities() {
        let devices = [device("usb-one"), device("192.0.2.1:40000"),
                       device("usb-two", physical: "phone-two"),
                       device("usb-unknown", physical: nil), device("192.0.2.2:40000", physical: nil)]
        let groups = DeviceConnectionPolicy.groups(devices)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first?.transports.map(\.serial), ["usb-one", "192.0.2.1:40000"])
    }

    func testAutoPrefersUSBInitiallyButDoesNotFlapWhenUSBReappears() {
        let devices = [device("192.0.2.1:40000"), device("usb-one")]
        XCTAssertEqual(DeviceConnectionPolicy.select(from: devices, current: nil, mode: .automatic)?.serial, "usb-one")
        XCTAssertEqual(DeviceConnectionPolicy.select(from: devices, current: "192.0.2.1:40000", mode: .automatic)?.serial, "192.0.2.1:40000")
    }

    func testAutoFailsOverBothWaysAndPinnedModesNeverUseAnotherKind() {
        let devices = [device("usb-one", state: "offline"), device("192.0.2.1:40000")]
        XCTAssertEqual(DeviceConnectionPolicy.select(from: devices, current: "usb-one", mode: .automatic)?.serial, "192.0.2.1:40000")
        XCTAssertEqual(DeviceConnectionPolicy.select(from: devices, current: "usb-one", mode: .usb)?.connectionState, "offline")
        XCTAssertNil(DeviceConnectionPolicy.select(from: [devices[1]], current: nil, mode: .usb))
        XCTAssertEqual(DeviceConnectionPolicy.select(from: [device("usb-one"), device("192.0.2.1:40000", state: "offline")],
                                                    current: "192.0.2.1:40000", mode: .automatic)?.serial, "usb-one")
    }

    func testDisplayIdentitySurvivesTransportChangeButNotPhysicalDeviceChange() {
        func display(_ serial: String) -> AndroidDisplay {
            AndroidDisplay(serial: serial, displayID: 0, name: "Main", uniqueID: "local:fixture", owner: "",
                           width: 1080, height: 2400, state: "ON")
        }
        let usb = display("usb-one").identified(as: "device:phone-one")
        let wireless = display("192.0.2.1:40000").identified(as: "device:phone-one")
        XCTAssertEqual(usb.id, wireless.id)
        XCTAssertNotEqual(usb.serial, wireless.serial)
        XCTAssertNotEqual(usb.id, display("usb-two").identified(as: "device:phone-two").id)
    }

    func testDisconnectedSelectionNeverFallsThroughToAnotherPhone() {
        let selected = device("usb-one", state: "offline")
        let other = device("192.0.2.2:40000", physical: "phone-two")
        XCTAssertEqual(DeviceConnectionPolicy.select(from: [selected, other], current: selected.serial, mode: .automatic)?.serial, selected.serial)
        XCTAssertNil(DeviceConnectionPolicy.select(from: [selected, other], current: selected.serial, mode: .wireless))
    }
}
