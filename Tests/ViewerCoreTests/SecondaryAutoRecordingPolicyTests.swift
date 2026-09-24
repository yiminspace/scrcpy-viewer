import XCTest
@testable import ViewerCore

final class SecondaryAutoRecordingPolicyTests: XCTestCase {
    private func evaluate(_ policy: inout SecondaryAutoRecordingPolicy,
                          enabled: Bool = true, secondary: Bool = true, frame: Bool = true,
                          automatic: Bool = false, recording: Bool = false,
                          finishing: Bool = false) -> SecondaryAutoRecordingPolicy.Action {
        policy.action(enabled: enabled, hasSecondary: secondary, hasFrame: frame,
                      recordingIsAutomatic: automatic, isRecording: recording,
                      isFinishing: finishing)
    }

    func testWaitsForFirstFrameAndStartsOnlyOnceWhileIdle() {
        var policy = SecondaryAutoRecordingPolicy()
        XCTAssertEqual(evaluate(&policy, secondary: false), .none)
        XCTAssertEqual(evaluate(&policy, frame: false), .none)
        XCTAssertEqual(evaluate(&policy), .start)
        XCTAssertEqual(evaluate(&policy), .none)
        XCTAssertEqual(evaluate(&policy, automatic: true, recording: true), .none)
    }

    func testOverlappingSecondariesShareRecordingUntilLastCloses() {
        var policy = SecondaryAutoRecordingPolicy()
        XCTAssertEqual(evaluate(&policy), .start)
        // The first secondary remains, then a second joins, then the first leaves.
        for _ in 0..<3 {
            XCTAssertEqual(evaluate(&policy, automatic: true, recording: true), .none)
        }
        XCTAssertEqual(evaluate(&policy, secondary: false, automatic: true, recording: true), .stop)
        XCTAssertEqual(evaluate(&policy, secondary: false, automatic: true, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy, secondary: false), .none)
        XCTAssertEqual(evaluate(&policy), .start)
    }

    func testManualStopOrFailureSuppressesRestartUntilAllSecondariesClose() {
        var policy = SecondaryAutoRecordingPolicy()
        XCTAssertEqual(evaluate(&policy), .start)
        policy.suppressUntilNoSecondary()
        XCTAssertEqual(evaluate(&policy, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy), .none)
        XCTAssertEqual(evaluate(&policy, frame: false), .none)
        XCTAssertEqual(evaluate(&policy), .none)
        XCTAssertEqual(evaluate(&policy, secondary: false), .none)
        XCTAssertEqual(evaluate(&policy), .start)
    }

    func testDisabledModeStopsAutomaticRecordingAndLeavesManualRecordingAlone() {
        var policy = SecondaryAutoRecordingPolicy()
        XCTAssertEqual(evaluate(&policy, enabled: false), .none)
        XCTAssertEqual(evaluate(&policy, enabled: false, automatic: true, recording: true), .stop)
        XCTAssertEqual(evaluate(&policy, enabled: false, recording: true), .none)
        XCTAssertEqual(evaluate(&policy, secondary: false, recording: true), .none)
        XCTAssertEqual(evaluate(&policy, recording: true), .none)
    }

    func testSavingBlocksStartAndStopThenStartsForReopenedSecondary() {
        var policy = SecondaryAutoRecordingPolicy()
        XCTAssertEqual(evaluate(&policy), .start)
        XCTAssertEqual(evaluate(&policy, automatic: true, recording: true), .none)
        XCTAssertEqual(evaluate(&policy, secondary: false, automatic: true, recording: true), .stop)
        XCTAssertEqual(evaluate(&policy, secondary: false, automatic: true, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy, automatic: true, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy, automatic: true), .start)
        XCTAssertEqual(evaluate(&policy, automatic: true), .none)
        XCTAssertEqual(evaluate(&policy, enabled: false, automatic: true,
                                recording: true, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy, enabled: false, automatic: true, recording: true), .stop)
    }

    func testAbsenceDuringSavingRearmsSuppressionAndResetAllowsSameSecondary() {
        var policy = SecondaryAutoRecordingPolicy()
        policy.suppressUntilNoSecondary()
        XCTAssertEqual(evaluate(&policy, secondary: false, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy, finishing: true), .none)
        XCTAssertEqual(evaluate(&policy), .start)
        policy.suppressUntilNoSecondary()
        XCTAssertEqual(evaluate(&policy), .none)
        policy.reset()
        XCTAssertEqual(evaluate(&policy), .start)
    }
}
