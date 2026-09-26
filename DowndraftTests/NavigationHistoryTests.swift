import XCTest
@testable import Downdraft

final class NavigationHistoryTests: XCTestCase {
    func testBackUsesConfirmedCurrentPageAndMakesForwardAvailable() {
        var history = NavigationHistory(currentPage: 3)
        history.record(from: 3, to: 221)

        XCTAssertEqual(history.navigateBack(from: 221), 3)
        XCTAssertFalse(history.canNavigateBack)
        XCTAssertTrue(history.canNavigateForward)
        XCTAssertEqual(history.navigateForward(from: 3), 221)
    }

    func testNewJumpDiscardsForwardHistory() {
        var history = NavigationHistory(currentPage: 3)
        history.record(from: 3, to: 221)
        XCTAssertEqual(history.navigateBack(from: 221), 3)

        history.record(from: 3, to: 42)

        XCTAssertFalse(history.canNavigateForward)
        XCTAssertEqual(history.navigateBack(from: 42), 3)
    }

    func testCurrentPageJumpDoesNotChangeHistory() {
        var history = NavigationHistory(currentPage: 3)
        let original = history

        history.record(from: 3, to: 3)

        XCTAssertEqual(history, original)
    }
}
