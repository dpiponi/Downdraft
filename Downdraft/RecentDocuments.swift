import Foundation
import PDFKit
import UIKit
import WidgetKit

struct RecentDocument: Codable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let thumbnailData: Data?
}

enum RecentDocumentStore {
    static let appGroupID = "group.com.dan.Downdraft"
    private static let key = "recentDocuments"

    static var documents: [RecentDocument] {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key),
              let documents = try? JSONDecoder().decode([RecentDocument].self, from: data) else {
            return []
        }
        return documents
    }

    static func record(id: UUID, name: String, bookmarkData: Data, document: PDFDocument?) {
        let thumbnailData = document?.page(at: 0)?
            .thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
            .pngData()
        let recentDocument = RecentDocument(
            id: id,
            displayName: name,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnailData
        )
        var updated = documents.filter { $0.bookmarkData != bookmarkData }
        updated.insert(recentDocument, at: 0)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Array(updated.prefix(4))) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
