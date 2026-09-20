import Foundation
import Darwin
import XCTest
@testable import ViewerCore

final class ScrcpyControlTests: XCTestCase {
    func testTouchMatchesScrcpyWireFormatAndFixedPointPressure() throws {
        let event = ScrcpyControlProtocol.Touch(action: .down, x: 42, y: 300,
            width: 1080, height: 2400, pressure: 0.5, buttons: 1, actionButton: 1)
        XCTAssertEqual(try XCTUnwrap(ScrcpyControlProtocol.touch(event)), Data([
            2, 0, 255, 255, 255, 255, 255, 255, 255, 254,
            0, 0, 0, 42, 0, 0, 1, 44, 4, 56, 9, 96, 128, 0,
            0, 0, 0, 1, 0, 0, 0, 1,
        ]))
        let up = ScrcpyControlProtocol.Touch(action: .up, x: 42, y: 300,
            width: 1080, height: 2400, pressure: 1, buttons: 0, actionButton: 0)
        XCTAssertEqual(Array(try XCTUnwrap(ScrcpyControlProtocol.touch(up))[22..<24]), [0, 0])
        let invalid = ScrcpyControlProtocol.Touch(action: .down, x: 1080, y: 0,
            width: 1080, height: 2400, pressure: 1, buttons: 0, actionButton: 0)
        XCTAssertNil(ScrcpyControlProtocol.touch(invalid))
    }

    func testScrollHasSignedFixedPointLimitsAndRejectsNonfiniteInput() throws {
        let unit = try XCTUnwrap(ScrcpyControlProtocol.scroll(x: 0, y: 0, width: 100, height: 200,
            horizontal: 1, vertical: -1, buttons: 0))
        XCTAssertEqual(unit.count, 21)
        XCTAssertEqual(Array(unit[13..<17]), [8, 0, 248, 0])
        let limits = try XCTUnwrap(ScrcpyControlProtocol.scroll(x: 0, y: 0, width: 100, height: 200,
            horizontal: 100, vertical: -100, buttons: 0))
        XCTAssertEqual(Array(limits[13..<17]), [127, 255, 128, 0])
        XCTAssertNil(ScrcpyControlProtocol.scroll(x: 0, y: 0, width: 100, height: 200,
            horizontal: .nan, vertical: 0, buttons: 0))
    }

    func testKeyAndUnicodeClipboardHaveExactLengths() throws {
        XCTAssertEqual(ScrcpyControlProtocol.key(action: .down, keyCode: 29, repeatCount: 2, metaState: 0x1000),
            Data([0, 0, 0, 0, 0, 29, 0, 0, 0, 2, 0, 0, 16, 0]))
        XCTAssertEqual(ScrcpyControlProtocol.requestClipboard(.copy), Data([8, 1]))
        XCTAssertEqual(ScrcpyControlProtocol.requestClipboard(.cut), Data([8, 2]))
        XCTAssertEqual(try XCTUnwrap(ScrcpyControlProtocol.clipboard("中", paste: true, sequence: 0x1234)),
            Data([9, 0, 0, 0, 0, 0, 0, 0x12, 0x34, 1, 0, 0, 0, 3, 0xe4, 0xb8, 0xad]))
        XCTAssertNotNil(ScrcpyControlProtocol.text(String(repeating: "a", count: 300)))
        XCTAssertNil(ScrcpyControlProtocol.text(String(repeating: "中", count: 101)))
        XCTAssertNil(ScrcpyControlProtocol.clipboard(String(repeating: "a", count: 262131), paste: true, sequence: 1))
    }

    func testSecondaryDisplaysNeverExposeInputAndNeverStartedStopCompletes() {
        XCTAssertTrue(ScrcpyControlProtocol.allowsControl(displayID: 0))
        for id in [-1, 1, 42] { XCTAssertFalse(ScrcpyControlProtocol.allowsControl(displayID: id)) }
        let file = URL(fileURLWithPath: "/unused")
        let dependencies = ViewerDependencies(adbURL: file, scrcpyURL: file, serverURL: file, serverVersion: "3.3.3")
        let stream = ScrcpyStream(dependencies: dependencies, serial: "test", displayID: 42,
            onFrame: { _ in XCTFail("No stream was started") }, onState: { _ in })
        XCTAssertFalse(stream.isControlReady)
        XCTAssertFalse(stream.sendTouch(action: .down, x: 1, y: 1, width: 10, height: 10))
        XCTAssertFalse(stream.sendScroll(x: 1, y: 1, width: 10, height: 10, horizontal: 0, vertical: 1))
        XCTAssertFalse(stream.sendKey(action: .down, keyCode: 3))
        XCTAssertFalse(stream.pressKey(keyCode: 4))
        XCTAssertFalse(stream.injectText("test"))
        XCTAssertFalse(stream.setClipboard("test"))
        XCTAssertFalse(stream.requestClipboard())
        let finished = expectation(description: "never-started stream stop")
        stream.stop { finished.fulfill() }
        wait(for: [finished], timeout: 2)
    }

    func testControlReceiverConsumesAckAndFragmentedUnicodeClipboard() throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair.1) }
        let received = expectation(description: "device clipboard")
        let channel = ScrcpyControlChannel(fd: pair.0, onClipboard: {
            XCTAssertEqual($0, "你好"); received.fulfill()
        }, onFailure: { XCTFail($0) })
        // An ACK can precede the clipboard message; both may be split at any byte boundary.
        let bytes = Data([1, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 6]) + Data("你好".utf8)
        for byte in bytes { var byte = byte; XCTAssertEqual(Darwin.send(pair.1, &byte, 1, 0), 1) }
        wait(for: [received], timeout: 2)
        let finished = expectation(description: "receiver cleanup")
        channel.stop { finished.fulfill() }
        wait(for: [finished], timeout: 2)
    }

    func testStopReleasesSentInputsBeforeClosingControlSocket() throws {
        let pair = try makeSocketPair()
        defer { Darwin.close(pair.1) }
        let channel = ScrcpyControlChannel(fd: pair.0, onClipboard: { _ in }, onFailure: { XCTFail($0) })
        let touch = ScrcpyControlProtocol.Touch(action: .down, x: 10, y: 20,
            width: 100, height: 200, pressure: 1, buttons: 0, actionButton: 0)
        XCTAssertTrue(channel.send(try XCTUnwrap(ScrcpyControlProtocol.touch(touch)), touch: touch))
        XCTAssertTrue(channel.send(ScrcpyControlProtocol.key(action: .down, keyCode: 29, repeatCount: 0, metaState: 0),
            key: (.down, 29, 0)))
        _ = try receive(46, from: pair.1) // Confirm both input messages actually reached the peer.
        channel.updateFrameSize(width: 200, height: 400)
        let finished = expectation(description: "control shutdown")
        channel.stop { finished.fulfill() }
        let released = try receive(78, from: pair.1) // CANCEL + UP + KEY_UP.
        XCTAssertEqual(Array(released[0..<2]), [2, 3])
        XCTAssertEqual(Array(released[32..<34]), [2, 1])
        XCTAssertEqual(Array(released[64..<78]), [0, 1, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 0])
        // Release coordinates use the newest decoded frame after a resolution change.
        XCTAssertEqual(Array(released[10..<22]), [0, 0, 0, 20, 0, 0, 0, 40, 0, 200, 1, 144])
        wait(for: [finished], timeout: 2)
        XCTAssertFalse(channel.send(Data([8, 1])))
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw TestError.socket }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (pair[0], pair[1])
    }

    private func receive(_ count: Int, from fd: Int32) throws -> Data {
        var bytes = Data(count: count), offset = 0
        while offset < count {
            let size = bytes.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            guard size > 0 else { throw TestError.socket }
            offset += size
        }
        return bytes
    }

    private enum TestError: Error { case socket }
}
