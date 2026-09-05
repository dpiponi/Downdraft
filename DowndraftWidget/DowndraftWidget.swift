import SwiftUI
import WidgetKit

private struct RecentDocument: Codable, Identifiable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let thumbnailData: Data?
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
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct RecentDocumentsWidgetView: View {
    let documents: [RecentDocument]

    var body: some View {
        if documents.isEmpty {
            ContentUnavailableView("No Recent PDFs", systemImage: "doc.richtext")
                .containerBackground(.fill.tertiary, for: .widget)
        } else {
            HStack(spacing: 10) {
                ForEach(documents) { document in
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
                            .frame(height: 88)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                            Text(document.displayName)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

@main
struct DowndraftWidgetBundle: WidgetBundle {
    var body: some Widget {
        DowndraftWidget()
    }
}
