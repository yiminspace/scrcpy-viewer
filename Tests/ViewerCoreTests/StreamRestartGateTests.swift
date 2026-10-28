import XCTest
@testable import ViewerCore

final class StreamRestartGateTests: XCTestCase {
    func testRetryStormCoalescesUntilOwnedSessionCleanupCompletes() {
        var gate = StreamRestartGate()
        XCTAssertTrue(gate.requestStart(for: "main"))
        gate.beginRetirement(for: "main")
        for _ in 0..<10_000 {
            gate.cancelStart(for: "main")
            XCTAssertFalse(gate.requestStart(for: "main"))
        }
        XCTAssertTrue(gate.requestStart(for: "secondary"))
        XCTAssertTrue(gate.didRetire("main"))
        XCTAssertFalse(gate.didRetire("main"))
        XCTAssertTrue(gate.requestStart(for: "main"))
    }

    func testDisconnectOrShutdownCancelsDeferredRestarts() {
        var gate = StreamRestartGate()
        gate.beginRetirement(for: "main")
        XCTAssertFalse(gate.requestStart(for: "main"))
        gate.cancelStart(for: "main")
        XCTAssertFalse(gate.didRetire("main"))
        gate.beginRetirement(for: "main")
        gate.beginRetirement(for: "secondary")
        XCTAssertFalse(gate.requestStart(for: "main"))
        XCTAssertFalse(gate.requestStart(for: "secondary"))
        gate.cancelPendingStarts()
        XCTAssertFalse(gate.didRetire("main"))
        XCTAssertFalse(gate.didRetire("secondary"))
    }
}
