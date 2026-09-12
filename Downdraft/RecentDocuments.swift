import CryptoKit
import Foundation
import PDFKit
import UIKit
import WidgetKit

struct RecentDocument: Codable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let thumbnailData: Data?
    let lastPageIndex: Int?
}

enum RecentDocumentStore {
    static let appGroupID = "group.com.dan.Downdraft"
    private static var recentDocumentsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("recent-documents.json")
    }

    static var documents: [RecentDocument] {
        guard let url = recentDocumentsURL,
              let data = try? Data(contentsOf: url),
              let documents = try? JSONDecoder().decode([RecentDocument].self, from: data) else {
            return []
        }
        return documents
    }

    static func record(
        id: UUID,
        name: String,
        bookmarkData: Data,
        document: PDFDocument?,
        lastPageIndex: Int? = nil,
        thumbnailCacheIdentity: String? = nil
    ) {
        let thumbnailData = thumbnailData(for: document?.page(at: 0))
        if let thumbnailData {
            DocumentThumbnailCache.store(
                thumbnailData,
                contentIdentity: thumbnailCacheIdentity,
                bookmarkData: bookmarkData
            )
        }
        let recentDocument = RecentDocument(
            id: id,
            displayName: name,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnailData,
            lastPageIndex: lastPageIndex
        )
        var updated = documents.filter { $0.bookmarkData != bookmarkData }
        updated.insert(recentDocument, at: 0)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Array(updated.prefix(4))) else { return }
        if let url = recentDocumentsURL {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func updateReadingPosition(bookmarkData: Data, pageIndex: Int) {
        var updated = documents
        guard let index = updated.firstIndex(where: { $0.bookmarkData == bookmarkData }) else { return }
        let document = updated[index]
        guard document.lastPageIndex != pageIndex else { return }
        updated[index] = RecentDocument(
            id: document.id,
            displayName: document.displayName,
            bookmarkData: document.bookmarkData,
            thumbnailData: document.thumbnailData,
            lastPageIndex: pageIndex
        )
        write(updated)
    }

    private static func write(_ documents: [RecentDocument]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Array(documents.prefix(4))) else { return }
        if let url = recentDocumentsURL {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func thumbnailData(for page: PDFPage?) -> Data? {
        guard let page else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        guard !pageBounds.isEmpty else { return nil }

        let targetSize = CGSize(width: 240, height: 320)
        let image = UIGraphicsImageRenderer(size: targetSize).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.cgContext.fill(CGRect(origin: .zero, size: targetSize))

            let scale = max(targetSize.width / pageBounds.width, targetSize.height / pageBounds.height)
            let renderedSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
            let origin = CGPoint(
                x: (targetSize.width - renderedSize.width) / 2,
                y: (targetSize.height - renderedSize.height) / 2
            )
            let context = rendererContext.cgContext
            context.translateBy(
                x: origin.x - pageBounds.minX * scale,
                y: origin.y + renderedSize.height + pageBounds.minY * scale
            )
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
        }
        return image.pngData()
    }
}

/// First-page previews are deliberately separate from the four-item widget
/// list.  The app keeps a bounded local cache so reopening an old tab never
/// requires eagerly loading its PDF just to populate the document chooser.
enum DocumentThumbnailCache {
    private static let maximumEntryCount = 100
    private static let cacheDirectory: URL? = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    ).first?.appendingPathComponent("DowndraftPDFThumbnails", isDirectory: true)
    private static var indexURL: URL? {
        cacheDirectory?.appendingPathComponent("index.json")
    }

    private struct Entry: Codable {
        var key: String
        var lastUsed: Date
    }

    static func data(contentIdentity: String?, bookmarkData: Data) -> Data? {
        for key in keys(contentIdentity: contentIdentity, bookmarkData: bookmarkData) {
            guard let data = try? Data(contentsOf: fileURL(for: key)) else { continue }
            return data
        }
        return nil
    }

    static func store(_ data: Data, contentIdentity: String?, bookmarkData: Data) {
        guard let directory = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The Files bookmark survives a relaunch even before a lazy PDF has
        // been reopened and had its content identity recalculated.
        let key = keys(contentIdentity: contentIdentity, bookmarkData: bookmarkData).last!
        try? data.write(to: fileURL(for: key), options: .atomic)

        var entries = loadIndex()
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, lastUsed: Date()))
        entries.sort { $0.lastUsed > $1.lastUsed }
        let expiredEntries = entries.dropFirst(maximumEntryCount)
        for entry in expiredEntries {
            try? FileManager.default.removeItem(at: fileURL(for: entry.key))
        }
        saveIndex(Array(entries.prefix(maximumEntryCount)))
    }

    private static func keys(contentIdentity: String?, bookmarkData: Data) -> [String] {
        let bookmarkKey = digest(bookmarkData)
        if let contentIdentity {
            let contentKey = digest(Data(contentIdentity.utf8))
            return contentKey == bookmarkKey ? [contentKey] : [contentKey, bookmarkKey]
        }
        return [bookmarkKey]
    }

    private static func fileURL(for key: String) -> URL {
        cacheDirectory!.appendingPathComponent("\(key).png")
    }

    private static func loadIndex() -> [Entry] {
        guard let indexURL,
              let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveIndex(_ entries: [Entry]) {
        guard let indexURL,
              let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
