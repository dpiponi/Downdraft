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

    static func record(id: UUID, name: String, bookmarkData: Data, document: PDFDocument?) {
        let thumbnailData = thumbnailData(for: document?.page(at: 0))
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
