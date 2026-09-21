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

    func testMergeKeepsOnlyTheNewestBookmarkForTheSamePage() {
        let older = Date(timeIntervalSinceReferenceDate: 10)
        let newer = Date(timeIntervalSinceReferenceDate: 20)
        let left = ReadingStateStore.State(
            page: .init(index: 0, modifiedAt: older, deviceID: "ipad"),
            bookmarks: [.init(pageIndex: 12, modifiedAt: newer, deviceID: "ipad")]
        )
        let right = ReadingStateStore.State(
            page: .init(index: 0, modifiedAt: newer, deviceID: "phone"),
            bookmarks: [
                .init(pageIndex: 4, modifiedAt: older, deviceID: "phone"),
                .init(pageIndex: 12, modifiedAt: newer, deviceID: "phone")
            ]
        )

        XCTAssertEqual(ReadingStateStore.merged(left, right).bookmarks.map(\.pageIndex), [nil, 12])
    }

    func testSavedPageFallbackBeatsAnOlderCloudPage() {
        let older = Date(timeIntervalSinceReferenceDate: 10)
        let saved = Date(timeIntervalSinceReferenceDate: 20)
        let cloud = ReadingStateStore.State(
            page: .init(index: 1, modifiedAt: older, deviceID: "phone"),
            bookmarks: []
        )
        let fallback = ReadingStateStore.State.initial(
            pageIndex: 47,
            bookmarks: [],
            pageModifiedAt: saved
        )

        XCTAssertEqual(ReadingStateStore.merged(cloud, fallback).page.index, 47)
    }

    func testDetachedPositionIsLocalAndClearedWhenRelinking() {
        let identity = "test-local-position-\(UUID().uuidString)"
        defer { DeviceReadingModeStore.removePreference(for: identity) }

        XCTAssertEqual(DeviceReadingModeStore.preference(for: identity), .linked)

        DeviceReadingModeStore.detach(identity, at: 12)
        XCTAssertEqual(
            DeviceReadingModeStore.preference(for: identity),
            .init(followsSharedPosition: false, detachedPageIndex: 12)
        )

        DeviceReadingModeStore.updateDetachedPage(19, for: identity)
        XCTAssertEqual(DeviceReadingModeStore.preference(for: identity).detachedPageIndex, 19)

        DeviceReadingModeStore.link(identity)
        XCTAssertEqual(DeviceReadingModeStore.preference(for: identity), .linked)
    }

    func testExistingDevicePreferenceDefaultsToShowingChapterMarks() throws {
        let legacyData = Data(#"{"followsSharedPosition":false,"detachedPageIndex":8}"#.utf8)
        let preference = try JSONDecoder().decode(DeviceReadingModeStore.Preference.self, from: legacyData)

        XCTAssertFalse(preference.followsSharedPosition)
        XCTAssertEqual(preference.detachedPageIndex, 8)
        XCTAssertTrue(preference.showsChapterMarks)
    }
}
