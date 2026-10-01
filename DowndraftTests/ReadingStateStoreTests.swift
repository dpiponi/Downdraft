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

    func testLatestUpdateIncludesBookmarksAndIgnoresUnmodifiedSlots() {
        let pageUpdate = Date(timeIntervalSinceReferenceDate: 10)
        let bookmarkUpdate = Date(timeIntervalSinceReferenceDate: 20)
        let state = ReadingStateStore.State(
            page: .init(index: 8, modifiedAt: pageUpdate, deviceID: "ipad"),
            bookmarks: [
                .init(pageIndex: 12, modifiedAt: bookmarkUpdate, deviceID: "phone"),
                .init(pageIndex: nil, modifiedAt: .distantPast, deviceID: "")
            ]
        )

        XCTAssertEqual(ReadingStateStore.latestUpdate(in: state), bookmarkUpdate)
        XCTAssertNil(ReadingStateStore.latestUpdate(in: .initial(pageIndex: 0, bookmarks: [])))
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

    func testDetachedPositionRemainsAvailableAsLocalPositionWhenRelinking() {
        let identity = "test-local-position-\(UUID().uuidString)"
        defer { DeviceReadingModeStore.removePreference(for: identity) }

        XCTAssertEqual(DeviceReadingModeStore.preference(for: identity), .linked)

        DeviceReadingModeStore.detach(identity, at: 12)
        let detachedPreference = DeviceReadingModeStore.preference(for: identity)
        XCTAssertFalse(detachedPreference.followsSharedPosition)
        XCTAssertEqual(detachedPreference.detachedPageIndex, 12)
        XCTAssertEqual(detachedPreference.localPageIndex, 12)

        DeviceReadingModeStore.updateDetachedPage(19, for: identity)
        XCTAssertEqual(DeviceReadingModeStore.preference(for: identity).detachedPageIndex, 19)

        DeviceReadingModeStore.link(identity)
        let linkedPreference = DeviceReadingModeStore.preference(for: identity)
        XCTAssertTrue(linkedPreference.followsSharedPosition)
        XCTAssertNil(linkedPreference.detachedPageIndex)
        XCTAssertEqual(linkedPreference.localPageIndex, 19)
    }

    func testExistingDevicePreferenceDefaultsToShowingChapterMarks() throws {
        let legacyData = Data(#"{"followsSharedPosition":false,"detachedPageIndex":8}"#.utf8)
        let preference = try JSONDecoder().decode(DeviceReadingModeStore.Preference.self, from: legacyData)

        XCTAssertFalse(preference.followsSharedPosition)
        XCTAssertEqual(preference.detachedPageIndex, 8)
        XCTAssertEqual(preference.localPageIndex, 8)
        XCTAssertTrue(preference.showsChapterMarks)
    }

    func testHandledSharedPageUsesTheFullRevision() {
        let identity = "test-handled-shared-page-\(UUID().uuidString)"
        defer { DeviceReadingModeStore.removePreference(for: identity) }
        let timestamp = Date(timeIntervalSinceReferenceDate: 123)
        let page = ReadingStateStore.State.Page(
            index: 42,
            modifiedAt: timestamp,
            deviceID: "beskar",
            deviceName: "Beskar"
        )

        XCTAssertFalse(DeviceReadingModeStore.hasHandledSharedPage(page, for: identity))
        DeviceReadingModeStore.markSharedPageHandled(page, for: identity)
        XCTAssertTrue(DeviceReadingModeStore.hasHandledSharedPage(page, for: identity))

        var newerRevision = page
        newerRevision.modifiedAt = timestamp.addingTimeInterval(1)
        XCTAssertFalse(DeviceReadingModeStore.hasHandledSharedPage(newerRevision, for: identity))
    }
}
