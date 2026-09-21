import CryptoKit
import Foundation
import PDFKit

/// Syncs the small, personal state associated with a PDF, rather than the
/// PDF or Files permission itself.  Each field has its own timestamp, so a
/// new bookmark on one device cannot overwrite a newer reading position from
/// another.
enum ReadingStateStore {
    private static let keyPrefix = "reading-state."
    private static let localPrefix = "local-reading-state."
    // All reading-state access happens on the app's main thread.  These
    // Foundation reference types predate Swift Sendable annotations.
    nonisolated(unsafe) private static let cloud = NSUbiquitousKeyValueStore.default
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let deviceIDKey = "reading-state-device-id"

    struct State: Codable, Equatable {
        var page: Page
        var bookmarks: [Bookmark]

        struct Page: Codable, Equatable {
            var index: Int
            var modifiedAt: Date
            var deviceID: String
        }

        struct Bookmark: Codable, Equatable {
            var pageIndex: Int?
            var modifiedAt: Date
            var deviceID: String
        }

        static func initial(
            pageIndex: Int,
            bookmarks: [Int?],
            pageModifiedAt: Date = .distantPast
        ) -> State {
            // A fallback is only a local starting point while iCloud state is
            // still arriving.  It must never outrank an actual reading event
            // from another device merely because this app was opened later.
            let deviceID = ReadingStateStore.deviceID
            return State(
                page: Page(index: pageIndex, modifiedAt: pageModifiedAt, deviceID: deviceID),
                bookmarks: bookmarks.map {
                    Bookmark(pageIndex: $0, modifiedAt: .distantPast, deviceID: deviceID)
                }
            )
        }
    }

    /// A stable identity for the same PDF opened through different Files URLs.
    /// A PDF trailer ID is preferred.  The fallback only reads 128 KiB of a
    /// file (64 KiB at either end), never hashes the full document.
    static func identity(for url: URL, document: PDFDocument) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let sampleSize: UInt64 = 64 * 1024
        let head = (try? handle.read(upToCount: Int(min(size, sampleSize)))) ?? Data()

        let tail: Data
        if size > sampleSize {
            try? handle.seek(toOffset: max(0, size - sampleSize))
            tail = (try? handle.read(upToCount: Int(sampleSize))) ?? Data()
        } else {
            tail = head
        }

        if let trailerID = trailerID(in: tail) {
            return "pdf-id-\(digest(Data(trailerID.utf8)))"
        }

        var signature = Data()
        signature.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
        signature.append(contentsOf: withUnsafeBytes(of: UInt64(document.pageCount).bigEndian, Array.init))
        signature.append(head)
        signature.append(tail)
        return "pdf-sample-\(digest(signature))"
    }

    static func state(
        for identity: String,
        fallbackPageIndex: Int,
        fallbackBookmarks: [Int?],
        fallbackPageModifiedAt: Date = .distantPast
    ) -> State {
        let local = decode(defaults.data(forKey: localKey(for: identity)))
        let remote = decode(cloud.data(forKey: cloudKey(for: identity)))
        let fallback = State.initial(
            pageIndex: fallbackPageIndex,
            bookmarks: fallbackBookmarks,
            pageModifiedAt: fallbackPageModifiedAt
        )

        let resolved: State
        switch (local, remote) {
        case let (local?, remote?): resolved = merged(merged(local, remote), fallback)
        case let (local?, nil): resolved = merged(local, fallback)
        case let (nil, remote?): resolved = merged(remote, fallback)
        case (nil, nil): resolved = fallback
        }
        // Reading state must not itself publish to iCloud.  A device may have
        // only a stale local fallback while a newer value is still being
        // downloaded; writing here would overwrite that remote value.
        saveLocal(resolved, for: identity)
        return resolved
    }

    static func savePage(
        _ pageIndex: Int,
        for identity: String,
        fallbackBookmarks: [Int?]
    ) {
        var state = state(
            for: identity,
            fallbackPageIndex: pageIndex,
            fallbackBookmarks: fallbackBookmarks
        )
        state.page = .init(index: pageIndex, modifiedAt: Date(), deviceID: deviceID)
        save(state, for: identity)
    }

    static func saveBookmark(
        _ pageIndex: Int?,
        at index: Int,
        for identity: String,
        fallbackPageIndex: Int,
        fallbackBookmarks: [Int?],
        fallbackPageModifiedAt: Date = .distantPast
    ) {
        guard index >= 0 else { return }
        var state = state(
            for: identity,
            fallbackPageIndex: fallbackPageIndex,
            fallbackBookmarks: fallbackBookmarks,
            fallbackPageModifiedAt: fallbackPageModifiedAt
        )
        while state.bookmarks.count <= index {
            state.bookmarks.append(.init(pageIndex: nil, modifiedAt: .distantPast, deviceID: ""))
        }
        state.bookmarks[index] = .init(pageIndex: pageIndex, modifiedAt: Date(), deviceID: deviceID)
        save(state, for: identity)
    }

    private static var deviceID: String {
        if let value = defaults.string(forKey: deviceIDKey) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    private static func save(_ state: State, for identity: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        saveLocalData(data, for: identity)
        cloud.set(data, forKey: cloudKey(for: identity))
        cloud.synchronize()
    }

    private static func saveLocal(_ state: State, for identity: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        saveLocalData(data, for: identity)
    }

    private static func saveLocalData(_ data: Data, for identity: String) {
        defaults.set(data, forKey: localKey(for: identity))
    }

    static func merged(_ lhs: State, _ rhs: State) -> State {
        State(
            page: newer(lhs.page, rhs.page),
            bookmarks: deduplicatedBookmarks(mergedBookmarks(lhs.bookmarks, rhs.bookmarks))
        )
    }

    private static func newer(_ lhs: State.Page, _ rhs: State.Page) -> State.Page {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        return lhs.deviceID >= rhs.deviceID ? lhs : rhs
    }

    private static func newer(_ lhs: State.Bookmark, _ rhs: State.Bookmark) -> State.Bookmark {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        return lhs.deviceID >= rhs.deviceID ? lhs : rhs
    }

    private static func mergedBookmarks(_ lhs: [State.Bookmark], _ rhs: [State.Bookmark]) -> [State.Bookmark] {
        let count = max(lhs.count, rhs.count)
        return (0..<count).map { index in
            switch (lhs.indices.contains(index) ? lhs[index] : nil, rhs.indices.contains(index) ? rhs[index] : nil) {
            case let (left?, right?): return newer(left, right)
            case let (left?, nil): return left
            case let (nil, right?): return right
            case (nil, nil): return .init(pageIndex: nil, modifiedAt: .distantPast, deviceID: "")
            }
        }
    }

    /// Slots are synced independently, so two devices can legitimately write
    /// the same page to different slots before their states meet.  The reader
    /// treats a page as a single bookmark; preserve its newest slot and clear
    /// any older duplicates when merging.
    private static func deduplicatedBookmarks(_ bookmarks: [State.Bookmark]) -> [State.Bookmark] {
        let newestSlotByPage = bookmarks.enumerated().reduce(into: [Int: Int]()) { slots, entry in
            guard let pageIndex = entry.element.pageIndex else { return }
            guard let existingIndex = slots[pageIndex] else {
                slots[pageIndex] = entry.offset
                return
            }
            if newer(bookmarks[existingIndex], entry.element) == entry.element {
                slots[pageIndex] = entry.offset
            }
        }

        return bookmarks.enumerated().map { index, bookmark in
            guard let pageIndex = bookmark.pageIndex,
                  newestSlotByPage[pageIndex] != index else {
                return bookmark
            }
            return .init(pageIndex: nil, modifiedAt: bookmark.modifiedAt, deviceID: bookmark.deviceID)
        }
    }

    private static func decode(_ data: Data?) -> State? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private static func cloudKey(for identity: String) -> String { keyPrefix + identity }
    private static func localKey(for identity: String) -> String { localPrefix + identity }

    private static func trailerID(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let pattern = #"/ID\s*\[\s*<([0-9A-Fa-f]+)>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).lowercased()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stores the reading-position relationship for this device only. The choice
/// to follow a PDF's shared position is deliberately not synced: the same
/// PDF can be linked on an iPhone while remaining detached on an iPad.
enum DeviceReadingModeStore {
    struct Preference: Codable, Equatable {
        var followsSharedPosition: Bool
        var detachedPageIndex: Int?
        var showsChapterMarks: Bool

        init(
            followsSharedPosition: Bool,
            detachedPageIndex: Int?,
            showsChapterMarks: Bool = true
        ) {
            self.followsSharedPosition = followsSharedPosition
            self.detachedPageIndex = detachedPageIndex
            self.showsChapterMarks = showsChapterMarks
        }

        private enum CodingKeys: String, CodingKey {
            case followsSharedPosition
            case detachedPageIndex
            case showsChapterMarks
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            followsSharedPosition = try values.decodeIfPresent(Bool.self, forKey: .followsSharedPosition) ?? true
            detachedPageIndex = try values.decodeIfPresent(Int.self, forKey: .detachedPageIndex)
            // Existing preferences predate this setting and should retain the
            // original, uncluttered-by-default behaviour of showing marks.
            showsChapterMarks = try values.decodeIfPresent(Bool.self, forKey: .showsChapterMarks) ?? true
        }

        static let linked = Preference(followsSharedPosition: true, detachedPageIndex: nil)
    }

    private static let preferencesKey = "device-reading-position-preferences"
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    static func preference(for identity: String) -> Preference {
        preferences()[identity] ?? .linked
    }

    static func detach(_ identity: String, at pageIndex: Int) {
        var preference = preference(for: identity)
        preference.followsSharedPosition = false
        preference.detachedPageIndex = pageIndex
        save(preference, for: identity)
    }

    static func updateDetachedPage(_ pageIndex: Int, for identity: String) {
        var preference = preference(for: identity)
        guard !preference.followsSharedPosition else { return }
        preference.detachedPageIndex = pageIndex
        save(preference, for: identity)
    }

    static func link(_ identity: String) {
        var preference = preference(for: identity)
        preference.followsSharedPosition = true
        preference.detachedPageIndex = nil
        save(preference, for: identity)
    }

    static func setShowsChapterMarks(_ showsChapterMarks: Bool, for identity: String) {
        var preference = preference(for: identity)
        preference.showsChapterMarks = showsChapterMarks
        save(preference, for: identity)
    }

    static func removePreference(for identity: String) {
        var values = preferences()
        values.removeValue(forKey: identity)
        save(values)
    }

    private static func preferences() -> [String: Preference] {
        guard let data = defaults.data(forKey: preferencesKey),
              let values = try? JSONDecoder().decode([String: Preference].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func save(_ preference: Preference, for identity: String) {
        var values = preferences()
        values[identity] = preference
        save(values)
    }

    private static func save(_ values: [String: Preference]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: preferencesKey)
    }
}
