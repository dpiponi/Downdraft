import XCTest
@testable import Downdraft

final class ReadingStateStoreTests: XCTestCase {
    func testInitialStateUsesDistantPastTimestamps() {
        let state = ReadingStateStore.State.initial(pageIndex: 12, bookmarks: [2, nil])

        XCTAssertEqual(state.page.index, 12)
        XCTAssertEqual(state.page.modifiedAt, .distantPast)
        XCTAssertEqual(state.bookmarks.map(\.pageIndex), [2, nil])
        XCTAssertTrue(state.bookmarks.allSatisfy { $0.modifiedAt == .distantPast })
    }

    func testMergeKeepsNewestPageAndEachNewestBookmark() {
        let older = Date(timeIntervalSinceReferenceDate: 10)
        let newer = Date(timeIntervalSinceReferenceDate: 20)
        let left = ReadingStateStore.State(
            page: .init(index: 3, modifiedAt: older, deviceID: "a"),
            bookmarks: [
                .init(pageIndex: 1, modifiedAt: newer, deviceID: "a"),
                .init(pageIndex: 4, modifiedAt: older, deviceID: "a")
            ]
        )
        let right = ReadingStateStore.State(
            page: .init(index: 9, modifiedAt: newer, deviceID: "b"),
            bookmarks: [
                .init(pageIndex: 8, modifiedAt: older, deviceID: "b"),
                .init(pageIndex: 12, modifiedAt: newer, deviceID: "b"),
                .init(pageIndex: 18, modifiedAt: newer, deviceID: "b")
            ]
        )

        let merged = ReadingStateStore.merged(left, right)

        XCTAssertEqual(merged.page.index, 9)
        XCTAssertEqual(merged.bookmarks.map(\.pageIndex), [1, 12, 18])
    }

    func testMergeBreaksTimestampTiesByDeviceIdentifier() {
        let timestamp = Date(timeIntervalSinceReferenceDate: 10)
        let left = ReadingStateStore.State(
            page: .init(index: 2, modifiedAt: timestamp, deviceID: "ipad"),
            bookmarks: []
        )
        let right = ReadingStateStore.State(
            page: .init(index: 7, modifiedAt: timestamp, deviceID: "iphone"),
            bookmarks: []
        )

        XCTAssertEqual(ReadingStateStore.merged(left, right).page.index, 7)
    }
}
