import XCTest
@testable import ViewerCore

final class DisplayScenePolicyTests: XCTestCase {
    private let main = DisplaySceneItem(id: "fixture:0:main", isMain: true, isActive: true)
    private let secondary = DisplaySceneItem(id: "fixture:7:generation-a", isMain: false, isActive: true)

    private func inactive(_ item: DisplaySceneItem) -> DisplaySceneItem {
        DisplaySceneItem(id: item.id, isMain: item.isMain, isActive: false)
    }

    func testDefaultStageKeepsSleepingMainButExcludesInactiveSecondary() {
        let policy = DisplayScenePolicy()
        let old = DisplaySceneItem(id: "fixture:8:old", isMain: false, isActive: false)
        XCTAssertEqual(policy.visibleIDs(in: [inactive(main), secondary, old]), [main.id, secondary.id])
        XCTAssertNil(policy.inspectedHistoryID)
    }

    func testSelectedSecondaryLeavesStageWhenItStopsWithoutBeingExplicitlyInspected() {
        var policy = DisplayScenePolicy()
        policy.select(secondary)
        XCTAssertEqual(policy.visibleIDs(in: [main, secondary]), [main.id, secondary.id])

        let after = [main, inactive(secondary)]
        XCTAssertTrue(policy.accept(inactive(secondary)))
        XCTAssertEqual(policy.visibleIDs(in: after), [main.id])
        XCTAssertEqual(policy.selection(afterUpdating: after, previous: secondary.id,
                                       newlyActive: [], followNew: true, mainInputFocused: false), main.id)
    }

    func testManualHistoryInspectionSurvivesRepeatedInactivePolls() {
        var policy = DisplayScenePolicy()
        let history = inactive(secondary)
        policy.select(history)
        for _ in 0..<3 {
            XCTAssertTrue(policy.accept(history))
            XCTAssertEqual(policy.visibleIDs(in: [main, history]), [main.id, history.id])
            XCTAssertEqual(policy.selection(afterUpdating: [main, history], previous: history.id,
                                           newlyActive: [], followNew: true, mainInputFocused: false), history.id)
        }
        XCTAssertEqual(policy.inspectedHistoryID, history.id)
    }

    func testSelectingMainDismissesExplicitHistoryFromStage() {
        var policy = DisplayScenePolicy()
        let history = inactive(secondary)
        policy.select(history)
        policy.select(main)
        XCTAssertNil(policy.inspectedHistoryID)
        XCTAssertEqual(policy.visibleIDs(in: [main, history]), [main.id])
    }

    func testClearingHistoryOnlyRemovesInactiveSecondariesAndDismissesInspection() {
        var policy = DisplayScenePolicy()
        let history = inactive(secondary)
        let another = DisplaySceneItem(id: "fixture:9:old", isMain: false, isActive: false)
        let active = DisplaySceneItem(id: "fixture:10:live", isMain: false, isActive: true)
        policy.select(history)

        let removed = policy.clearHistory([inactive(main), history, another, active])
        XCTAssertEqual(removed, Set([history.id, another.id]))
        XCTAssertNil(policy.inspectedHistoryID)
        XCTAssertTrue(policy.accept(inactive(main)))
        XCTAssertTrue(policy.accept(active))
        XCTAssertFalse(policy.accept(history))
        XCTAssertFalse(policy.accept(another))
    }

    func testClearedInactiveIdentityDoesNotReturnOnLaterPollOrAfterTemporaryAbsence() {
        var policy = DisplayScenePolicy()
        let history = inactive(secondary)
        _ = policy.clearHistory([history])
        XCTAssertFalse(policy.accept(history))

        // A display can disappear from discovery and later return with the same
        // identity while still OFF. Changing selection must not forget the clear.
        XCTAssertEqual(policy.selection(afterUpdating: [main], previous: history.id,
                                       newlyActive: [], followNew: false, mainInputFocused: false), main.id)
        policy.resetSelection()
        XCTAssertFalse(policy.accept(history))
        XCTAssertFalse(policy.accept(history))
    }

    func testClearedIdentityAppearsAgainWhenItsSourceBecomesActive() {
        var policy = DisplayScenePolicy()
        _ = policy.clearHistory([inactive(secondary)])
        XCTAssertFalse(policy.accept(inactive(secondary)))

        XCTAssertTrue(policy.accept(secondary))
        XCTAssertEqual(policy.visibleIDs(in: [main, secondary]), [main.id, secondary.id])
        XCTAssertEqual(policy.selection(afterUpdating: [main, secondary], previous: main.id,
                                       newlyActive: [secondary.id], followNew: true, mainInputFocused: false), secondary.id)
        // A later stop is fresh history, rather than a permanently hidden display.
        XCTAssertTrue(policy.accept(inactive(secondary)))
        XCTAssertEqual(policy.visibleIDs(in: [main, inactive(secondary)]), [main.id])
    }

    func testNewGenerationWithReusedLogicalIDIsNotHiddenByOlderHistoryClear() {
        var policy = DisplayScenePolicy()
        _ = policy.clearHistory([inactive(secondary)])
        let next = DisplaySceneItem(id: "fixture:7:generation-b", isMain: false, isActive: true)

        XCTAssertFalse(policy.accept(inactive(secondary)))
        XCTAssertTrue(policy.accept(next))
        XCTAssertEqual(policy.visibleIDs(in: [main, next]), [main.id, next.id])
        let otherDevice = DisplaySceneItem(id: "other-fixture:7:generation-a", isMain: false, isActive: false)
        XCTAssertTrue(policy.accept(otherDevice))
    }

    func testResumingInspectedHistoryEndsInspectionSoNextStopLeavesStage() {
        var policy = DisplayScenePolicy()
        policy.select(inactive(secondary))
        XCTAssertEqual(policy.inspectedHistoryID, secondary.id)
        XCTAssertTrue(policy.accept(secondary))
        XCTAssertNil(policy.inspectedHistoryID)

        XCTAssertTrue(policy.accept(inactive(secondary)))
        XCTAssertEqual(policy.visibleIDs(in: [main, inactive(secondary)]), [main.id])
        XCTAssertEqual(policy.selection(afterUpdating: [main, inactive(secondary)], previous: secondary.id,
                                       newlyActive: [], followNew: true, mainInputFocused: false), main.id)
    }

    func testMainKeyboardFocusPreventsNewSecondarySelectionButNotItsAppearance() {
        let policy = DisplayScenePolicy()
        let items = [main, secondary]
        XCTAssertEqual(policy.visibleIDs(in: items), [main.id, secondary.id])
        XCTAssertEqual(policy.selection(afterUpdating: items, previous: main.id,
                                       newlyActive: [secondary.id], followNew: true, mainInputFocused: true), main.id)
        // Releasing keyboard focus is not a new-display event: no delayed switch.
        XCTAssertEqual(policy.selection(afterUpdating: items, previous: main.id,
                                       newlyActive: [], followNew: true, mainInputFocused: false), main.id)
    }

    func testFollowNewSecondaryOnlyWhenEnabledAndMainIsNotBeingTypedInto() {
        let policy = DisplayScenePolicy()
        let items = [main, secondary]
        XCTAssertEqual(policy.selection(afterUpdating: items, previous: main.id,
                                       newlyActive: [secondary.id], followNew: true, mainInputFocused: false), secondary.id)
        XCTAssertEqual(policy.selection(afterUpdating: items, previous: main.id,
                                       newlyActive: [secondary.id], followNew: false, mainInputFocused: false), main.id)
    }

    func testFollowIgnoresInactiveUnknownAndMainDisplayEvents() {
        let policy = DisplayScenePolicy()
        let old = DisplaySceneItem(id: "fixture:8:old", isMain: false, isActive: false)
        XCTAssertEqual(policy.selection(afterUpdating: [main, secondary, old], previous: secondary.id,
                                       newlyActive: [main.id, old.id, "missing"], followNew: true,
                                       mainInputFocused: false), secondary.id)
    }

    func testSelectionFallsBackToActiveDisplayInsteadOfUnselectedHistory() {
        let policy = DisplayScenePolicy()
        let old = DisplaySceneItem(id: "fixture:8:old", isMain: false, isActive: false)
        XCTAssertEqual(policy.selection(afterUpdating: [old, secondary], previous: old.id,
                                       newlyActive: [], followNew: false, mainInputFocused: false), secondary.id)
        XCTAssertTrue(policy.visibleIDs(in: [old]).isEmpty)
        XCTAssertNil(policy.selection(afterUpdating: [old], previous: old.id,
                                      newlyActive: [], followNew: false, mainInputFocused: false))
    }
}
