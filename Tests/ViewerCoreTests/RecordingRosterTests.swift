import XCTest
import CoreGraphics
@testable import ViewerCore

final class RecordingRosterTests: XCTestCase {
    private func screen(_ id: String, live: Bool = true, status: String = "正在显示") -> RecordingScreen {
        RecordingScreen(id: id, title: id, image: nil, sourceSize: CGSize(width: 360, height: 800),
                        status: status, lastFrameAt: Date(timeIntervalSince1970: 123), isLive: live)
    }

    func testIncludesAllCurrentAndLaterScreensButNotPreexistingHistory() {
        var roster = RecordingRoster()
        let initial = [screen("main"), screen("secondary-a"), screen("old", live: false)]
        XCTAssertEqual(roster.update(currentIDs: ["main", "secondary-a"], screens: initial).map(\.id),
                       ["main", "secondary-a"])
        let expanded = roster.update(currentIDs: ["main", "secondary-a", "secondary-b", "secondary-c"],
            screens: initial + [screen("secondary-b"), screen("secondary-c")])
        XCTAssertEqual(expanded.map(\.id), ["main", "secondary-a", "secondary-b", "secondary-c"])
        // Returning to the original current set does not drop captured screens.
        let removed = roster.update(currentIDs: ["main"], screens: [screen("main")])
        XCTAssertEqual(removed.count, 4)
        XCTAssertTrue(removed.dropFirst().allSatisfy { !$0.isLive && $0.status == "画面已停止" })
        XCTAssertEqual(removed.last?.lastFrameAt, Date(timeIntervalSince1970: 123))
    }

    func testSleepingAndResumedScreenUpdateExistingSlotAndNewSessionResets() {
        var roster = RecordingRoster()
        _ = roster.update(currentIDs: ["main", "secondary"], screens: [screen("main"), screen("secondary")])
        let sleeping = roster.update(currentIDs: ["main"],
            screens: [screen("main"), screen("secondary", live: false, status: "已休眠")])
        XCTAssertEqual(sleeping.last?.status, "已休眠")
        XCTAssertEqual(sleeping.last?.isLive, false)
        let cleared = roster.update(currentIDs: ["main"], screens: [screen("main")])
        XCTAssertEqual(cleared.last?.status, "已休眠", "Clearing local history is not evidence of device removal")
        let resumed = roster.update(currentIDs: ["main", "secondary"], screens: [screen("main"), screen("secondary")])
        XCTAssertEqual(resumed.map(\.id), ["main", "secondary"])
        XCTAssertEqual(resumed.last?.isLive, true)
        roster = RecordingRoster()
        XCTAssertEqual(roster.update(currentIDs: ["other-main"], screens: [screen("other-main")]).map(\.id), ["other-main"])
    }
}
