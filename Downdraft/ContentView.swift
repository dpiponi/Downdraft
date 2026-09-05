import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var documents = OpenDocument.restoreSavedDocuments()
    @State private var selectedDocumentID: OpenDocument.ID?
    @State private var isShowingFilePicker = false
    @State private var errorMessage: String?
    @State private var isReaderFocused = false
    @State private var searchText = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var currentSearchResultIndex = 0
    @State private var isShowingContents = false
    @State private var outlineDestination: PDFDestination?

    private var selectedDocument: OpenDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    private var currentSearchSelection: PDFSelection? {
        guard searchResults.indices.contains(currentSearchResultIndex) else { return nil }
        return searchResults[currentSearchResultIndex]
    }

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView(
                        "No PDFs Open",
                        systemImage: "doc.richtext",
                        description: Text("Choose a PDF from Files to begin reading.")
                    )
                } else {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            if !isReaderFocused {
                                DocumentTabStrip(
                                    documents: documents,
                                    selectedID: selectedDocumentID,
                                    select: selectDocument,
                                    close: close
                                )
                            }

                            // Keep every PDFView in the hierarchy, so switching tabs
                            // retains its zoom level and reading position.
                            ZStack {
                                ForEach(documents) { document in
                                    if let pdfDocument = document.pdfDocument {
                                        PDFDocumentView(
                                            document: pdfDocument,
                                            initialPageIndex: document.lastPageIndex,
                                            isActive: document.id == selectedDocumentID,
                                            isReaderFocused: isReaderFocused,
                                            isLandscape: proxy.size.width > proxy.size.height,
                                            searchSelection: document.id == selectedDocumentID
                                                ? currentSearchSelection
                                                : nil,
                                            searchSelections: document.id == selectedDocumentID
                                                ? searchResults
                                                : [],
                                            outlineDestination: document.id == selectedDocumentID
                                                ? outlineDestination
                                                : nil
                                    ) { pageIndex in
                                            updatePage(pageIndex, for: document.id)
                                        } onCenterTap: {
                                            isReaderFocused.toggle()
                                        }
                                        .opacity(document.id == selectedDocumentID ? 1 : 0)
                                        .allowsHitTesting(document.id == selectedDocumentID)
                                        .accessibilityHidden(document.id != selectedDocumentID)
                                    }
                                }

                                if selectedDocument?.url == nil {
                                    ProgressView()
                                }
                            }
                        }
                    }
                }
            }
            .toolbar(isReaderFocused ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open PDF", systemImage: "folder") {
                        isShowingFilePicker = true
                    }
                }
                if !searchResults.isEmpty {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button("Previous match", systemImage: "chevron.up") {
                            moveSearchResult(by: -1)
                        }
                        Button("Next match", systemImage: "chevron.down") {
                            moveSearchResult(by: 1)
                        }
                        Text("\(currentSearchResultIndex + 1) of \(searchResults.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Contents", systemImage: "list.bullet") {
                            isShowingContents = true
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Find in PDF")
        .onSubmit(of: .search) {
            performSearch()
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                clearSearch()
            }
        }
        .sheet(isPresented: $isShowingContents) {
            if let outline = selectedDocument?.pdfDocument?.outlineRoot {
                TableOfContentsView(entries: TableOfContentsEntry.children(of: outline)) { destination in
                    clearSearch()
                    outlineDestination = destination
                    isShowingContents = false
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .alert("Couldn’t Open PDF", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onAppear {
            if selectedDocumentID == nil, let firstDocument = documents.first {
                selectDocument(firstDocument.id)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            open(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        if let existingDocument = documents.first(where: { $0.url == url }) {
            selectedDocumentID = existingDocument.id
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Files didn’t grant access to this PDF."
            return
        }

        guard let document = OpenDocument(url: url) else {
            errorMessage = "Downdraft couldn’t save permission to reopen this PDF."
            return
        }
        documents.append(document)
        selectDocument(document.id)
        saveDocuments()
    }

    private func close(_ id: OpenDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let document = documents.remove(at: index)
        document.stopAccessingFile()
        saveDocuments()

        if selectedDocumentID == id,
           let nextDocument = documents.indices.contains(index) ? documents[index] : documents.last {
            selectDocument(nextDocument.id)
        }
    }

    private func selectDocument(_ id: OpenDocument.ID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        guard document.loadFileIfNeeded() else {
            errorMessage = "The PDF is no longer available in Files."
            return
        }
        selectedDocumentID = id
        outlineDestination = nil
        clearSearch()
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let document = selectedDocument?.pdfDocument else {
            clearSearch()
            return
        }
        searchResults = document.findString(query, withOptions: [.caseInsensitive])
        currentSearchResultIndex = 0
    }

    private func moveSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchResultIndex = (currentSearchResultIndex + offset + searchResults.count)
            % searchResults.count
    }

    private func clearSearch() {
        searchResults = []
        currentSearchResultIndex = 0
    }

    private func updatePage(_ pageIndex: Int, for id: OpenDocument.ID) {
        guard let document = documents.first(where: { $0.id == id }),
              document.lastPageIndex != pageIndex else { return }
        document.lastPageIndex = pageIndex
        saveDocuments()
    }

    private func saveDocuments() {
        OpenDocument.save(documents)
    }
}

private struct TableOfContentsEntry: Identifiable {
    let id = UUID()
    let title: String
    let destination: PDFDestination?
    let children: [TableOfContentsEntry]?

    static func children(of outline: PDFOutline) -> [TableOfContentsEntry] {
        (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let childEntries = children(of: child)
            return TableOfContentsEntry(
                title: child.label ?? "Untitled Section",
                destination: child.destination,
                children: childEntries.isEmpty ? nil : childEntries
            )
        }
    }
}

private struct TableOfContentsView: View {
    let entries: [TableOfContentsEntry]
    let select: (PDFDestination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                OutlineGroup(entries, children: \.children) { entry in
                    if let destination = entry.destination {
                        Button(entry.title) {
                            select(destination)
                        }
                    } else {
                        Text(entry.title)
                    }
                }
            }
            .navigationTitle("Contents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private final class OpenDocument: Identifiable {
    let id = UUID()
    private(set) var url: URL?
    private(set) var pdfDocument: PDFDocument?
    let bookmarkData: Data
    let displayName: String
    var lastPageIndex: Int
    private var isAccessingFile: Bool

    init(url: URL?, bookmarkData: Data, displayName: String, lastPageIndex: Int = 0, isAccessingFile: Bool) {
        self.url = url
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.lastPageIndex = lastPageIndex
        self.isAccessingFile = isAccessingFile
    }

    convenience init?(url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        self.init(
            url: url,
            bookmarkData: bookmarkData,
            displayName: url.deletingPathExtension().lastPathComponent,
            isAccessingFile: true
        )
    }

    func stopAccessingFile() {
        guard isAccessingFile, let url else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessingFile = false
        pdfDocument = nil
    }

    func loadFileIfNeeded() -> Bool {
        if let url {
            if pdfDocument == nil {
                pdfDocument = PDFDocument(url: url)
            }
            return pdfDocument != nil
        }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), resolvedURL.startAccessingSecurityScopedResource() else {
            return false
        }
        url = resolvedURL
        isAccessingFile = true
        pdfDocument = PDFDocument(url: resolvedURL)
        return pdfDocument != nil
    }

    deinit {
        stopAccessingFile()
    }

    private struct SavedDocument: Codable {
        let bookmarkData: Data
        let displayName: String
        let lastPageIndex: Int
    }

    private static let savedDocumentsKey = "openDocuments"

    static func save(_ documents: [OpenDocument]) {
        let savedDocuments = documents.map {
            SavedDocument(
                bookmarkData: $0.bookmarkData,
                displayName: $0.displayName,
                lastPageIndex: $0.lastPageIndex
            )
        }
        guard let data = try? JSONEncoder().encode(savedDocuments) else { return }
        UserDefaults.standard.set(data, forKey: savedDocumentsKey)
    }

    static func restoreSavedDocuments() -> [OpenDocument] {
        guard let data = UserDefaults.standard.data(forKey: savedDocumentsKey),
              let savedDocuments = try? JSONDecoder().decode([SavedDocument].self, from: data) else {
            return []
        }

        return savedDocuments.map { savedDocument in
            OpenDocument(
                url: nil,
                bookmarkData: savedDocument.bookmarkData,
                displayName: savedDocument.displayName,
                lastPageIndex: savedDocument.lastPageIndex,
                isAccessingFile: false
            )
        }
    }
}

private struct DocumentTabStrip: View {
    let documents: [OpenDocument]
    let selectedID: OpenDocument.ID?
    let select: (OpenDocument.ID) -> Void
    let close: (OpenDocument.ID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(documents) { document in
                    HStack(spacing: 4) {
                        Button {
                            select(document.id)
                        } label: {
                            Text(document.displayName)
                                .lineLimit(1)
                                .frame(maxWidth: 180)
                                .fontWeight(document.id == selectedID ? .medium : .regular)
                        }
                        .buttonStyle(.plain)

                        Button {
                            close(document.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close \(document.displayName)")
                    }
                    .padding(.vertical, 7)
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .foregroundStyle(document.id == selectedID ? .primary : .secondary)
                    .background(
                        document.id == selectedID ? Color.primary.opacity(0.10) : Color.clear,
                        in: Capsule()
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

#Preview {
    ContentView()
}
