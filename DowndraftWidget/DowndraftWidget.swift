import SwiftUI
import WidgetKit

private struct RecentDocument: Codable, Identifiable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let thumbnailData: Data?
    let lastPageIndex: Int?
}

private struct RecentDocumentProvider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(documents: []) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(documents: documents))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(documents: documents)], policy: .never))
    }

    private var documents: [RecentDocument] {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.dan.Downdraft"),
              let data = try? Data(contentsOf: containerURL.appendingPathComponent("recent-documents.json")),
              let documents = try? JSONDecoder().decode([RecentDocument].self, from: data) else {
            return []
        }
        return documents
    }

    struct Entry: TimelineEntry {
        let date = Date()
        let documents: [RecentDocument]
    }
}

struct DowndraftWidget: Widget {
    let kind = "DowndraftWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentDocumentProvider()) { entry in
            RecentDocumentsWidgetView(documents: entry.documents)
        }
        .configurationDisplayName("Recent PDFs")
        .description("Open one of your recently read PDFs.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct RecentDocumentsWidgetView: View {
    let documents: [RecentDocument]
    @Environment(\.widgetFamily) private var family

    private var displayedDocuments: [RecentDocument] {
        let count = switch family {
        case .systemSmall: 1
        case .systemMedium: UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
        default: 4
        }
        return Array(documents.prefix(count))
    }

    var body: some View {
        if family == .accessoryRectangular {
            ContinueReadingWidgetView(document: documents.first)
        } else if documents.isEmpty {
            ContentUnavailableView("No Recent PDFs", systemImage: "doc.richtext")
                .containerBackground(.fill.tertiary, for: .widget)
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(displayedDocuments) { document in
                    Link(destination: URL(string: "downdraft://open?id=\(document.id.uuidString)")!) {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                if let data = document.thumbnailData,
                                   let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "doc.richtext")
                                        .font(.largeTitle)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: family == .systemSmall ? 104 : 88)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                            Text(document.displayName)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                                .frame(height: 30, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

private struct ContinueReadingWidgetView: View {
    let document: RecentDocument?

    var body: some View {
        if let document {
            Link(destination: URL(string: "downdraft://open?id=\(document.id.uuidString)")!) {
                HStack(spacing: 9) {
                    Text("§")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue Reading")
                            .font(.caption2)
                        Text(document.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if let pageIndex = document.lastPageIndex {
                            Text("Page \(pageIndex + 1)")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            Label("Open a PDF in Downdraft", systemImage: "doc.richtext")
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}

@main
struct DowndraftWidgetBundle: WidgetBundle {
    var body: some Widget {
        DowndraftWidget()
    }
}
