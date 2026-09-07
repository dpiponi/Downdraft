import PDFKit
import SwiftUI
import UIKit
import WidgetKit
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
    @State private var treatsFirstPageAsCover = true
    @State private var scrubbedPageIndex = 0
    @State private var requestedPageIndex: Int?
    @State private var bookmarkPageIndices: [Int?] = [nil, nil, nil]
    @State private var navigationRevision = 0
    @State private var scrubberRevision = 0
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var isSearchPresented = false
    @State private var isShowingBookmarks = false

    private var selectedDocument: OpenDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    private var currentSearchSelection: PDFSelection? {
        guard searchResults.indices.contains(currentSearchResultIndex) else { return nil }
        return searchResults[currentSearchResultIndex]
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
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
                    GeometryReader { _ in
                        VStack(spacing: 0) {
                            // Keep every PDFView in the hierarchy, so switching tabs
                            // retains its zoom level and reading position.
                            ZStack(alignment: .bottom) {
                                ForEach(documents) { document in
                                    reader(for: document)
                                }

                                if selectedDocument?.url == nil {
                                    ProgressView()
                                }

                                if !isReaderFocused, let document = selectedDocument,
                                   let pdfDocument = document.pdfDocument {
                                    scrubber(for: pdfDocument)
                                        .padding(.bottom, isPhone ? 58 : 24)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                        }
                        .animation(.easeInOut(duration: 0.24), value: isReaderFocused)
                    }
                }
            }
            // The PDF's frame stays fixed. Reader chrome floats over it,
            // rather than forcing PDFKit to redraw during every transition.
            .ignoresSafeArea(edges: .all)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(
                isReaderFocused ? .hidden : .visible,
                for: .navigationBar
            )
            .toolbar {
                if !isReaderFocused {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open PDF", systemImage: "folder") {
                        isShowingFilePicker = true
                    }
                }
                if isPhone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Search", systemImage: "magnifyingglass") {
                            isSearchPresented = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu(selectedDocument?.displayName ?? "Documents", systemImage: "doc.on.doc") {
                        ForEach(documents) { document in
                            Button(document.displayName) {
                                selectDocument(document.id)
                            }
                        }
                        if selectedDocument != nil {
                            Divider()
                            Button("Close Current Document", role: .destructive) {
                                if let id = selectedDocumentID { close(id) }
                            }
                        }
                    }
                }
                if isPhone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                                Button("Contents", systemImage: "list.bullet") {
                                    isShowingContents = true
                                }
                            }
                        }
                    }
                    if selectedDocument != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Bookmarks", systemImage: "bookmark") {
                                isShowingBookmarks = true
                            }
                        }
                    }
                }
                if !isPhone, selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Contents", systemImage: "list.bullet") {
                            isShowingContents = true
                        }
                    }
                }
                if !isPhone, selectedDocument != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            setFirstPageCover(!treatsFirstPageAsCover)
                        } label: {
                            Image(systemName: treatsFirstPageAsCover
                                ? "rectangle.split.2x1"
                                : "rectangle")
                        }
                        .accessibilityLabel(
                            treatsFirstPageAsCover
                                ? "Show first page in facing pages"
                                : "Show first page as a cover"
                        )
                    }
                }
                if !isPhone, selectedDocument != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(0..<3, id: \.self) { index in
                            BookmarkSlotButton(
                                number: index + 1,
                                isSet: bookmarkPageIndices[index] != nil,
                                goToBookmark: { goToBookmark(at: index) },
                                storeBookmark: { storeBookmark(at: index) }
                            )
                        }
                    }
                }
                if !isPhone, !searchResults.isEmpty || selectedDocument != nil {
                    // The search field occupies the far trailing position.
                    // Keep its navigation controls directly beside it.
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !searchResults.isEmpty {
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
                        if let document = selectedDocument {
                            // Reading this state refreshes the toolbar after
                            // the document's transient history changes.
                            let historyControlsAreCurrent = navigationRevision >= 0
                            Button("Back", systemImage: "chevron.backward") {
                                navigateBack(in: document)
                            }
                            .disabled(!document.canNavigateBack || !historyControlsAreCurrent)

                            Button("Forward", systemImage: "chevron.forward") {
                                navigateForward(in: document)
                            }
                            .disabled(!document.canNavigateForward || !historyControlsAreCurrent)
                        }
                    }
                }
                if isPhone, !isReaderFocused, !searchResults.isEmpty || selectedDocument != nil {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if let document = selectedDocument {
                            let historyControlsAreCurrent = navigationRevision >= 0
                            Button("Back", systemImage: "chevron.backward") {
                                navigateBack(in: document)
                            }
                            .disabled(!document.canNavigateBack || !historyControlsAreCurrent)

                            Button("Forward", systemImage: "chevron.forward") {
                                navigateForward(in: document)
                            }
                            .disabled(!document.canNavigateForward || !historyControlsAreCurrent)
                        }
                        if !searchResults.isEmpty {
                            Spacer()
                            Button("Previous match", systemImage: "chevron.up") {
                                moveSearchResult(by: -1)
                            }
                            Button("Next match", systemImage: "chevron.down") {
                                moveSearchResult(by: 1)
                            }
                            Text("\(currentSearchResultIndex + 1) of \(searchResults.count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                }
            }
        }
        .readerSearchable(
            !isReaderFocused,
            text: $searchText,
            isPresented: $isSearchPresented
        )
        .statusBarHidden(isReaderFocused)
        .persistentSystemOverlays(isReaderFocused ? .hidden : .visible)
        .toolbar(.visible, for: .bottomBar)
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
                    if let document = selectedDocument,
                       let page = destination.page {
                        navigate(to: document.pdfDocument?.index(for: page) ?? document.lastPageIndex)
                    }
                    outlineDestination = destination
                    isShowingContents = false
                }
            }
        }
        .sheet(isPresented: $isShowingBookmarks) {
            VStack(spacing: 14) {
                Text("Bookmarks")
                    .font(.headline)
                HStack(spacing: 24) {
                    ForEach(0..<3, id: \.self) { index in
                        BookmarkSlotButton(
                            number: index + 1,
                            isSet: bookmarkPageIndices[index] != nil,
                            size: 48,
                            goToBookmark: {
                                goToBookmark(at: index)
                                isShowingBookmarks = false
                            },
                            storeBookmark: { storeBookmark(at: index) }
                        )
                    }
                }
            }
            .padding()
            .presentationDetents([.height(140)])
            .presentationDragIndicator(.visible)
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
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientation = UIDevice.current.orientation
            if selectedDocumentID == nil, let firstDocument = documents.first {
                selectDocument(firstDocument.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification
        )) { _ in
            deviceOrientation = UIDevice.current.orientation
        }
        .onOpenURL { url in
            if url.isFileURL {
                open(url)
                return
            }
            guard url.scheme == "downdraft",
                  url.host == "open",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: idString),
                  let recentDocument = RecentDocumentStore.documents.first(where: { $0.id == id }) else {
                return
            }
            openBookmark(recentDocument.bookmarkData)
        }
    }

    @ViewBuilder
    private func reader(for document: OpenDocument) -> some View {
        if let pdfDocument = document.pdfDocument {
            let isSelected = document.id == selectedDocumentID
            PDFDocumentView(
                document: pdfDocument,
                initialPageIndex: document.lastPageIndex,
                isActive: isSelected,
                isReaderFocused: isReaderFocused,
                isLandscape: !isPhone && isLandscapeInterface,
                displaysAsBook: treatsFirstPageAsCover,
                searchSelection: isSelected ? currentSearchSelection : nil,
                searchSelections: isSelected ? searchResults : [],
                outlineDestination: isSelected ? outlineDestination : nil,
                requestedPageIndex: isSelected ? requestedPageIndex : nil,
                onPageChanged: { pageIndex in
                    updatePage(pageIndex, for: document.id)
                },
                onCenterTap: {
                    toggleReaderFocus()
                },
                onLinkNavigation: { sourcePageIndex, destinationPageIndex in
                    recordNavigation(
                        in: document,
                        from: sourcePageIndex,
                        to: destinationPageIndex
                    )
                }
            )
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            // The system bars are visual overlays for the reader.  Keep the
            // UIKit PDF view out of their safe-area relayout path.
            .ignoresSafeArea()
        }
    }

    private func scrubber(for document: PDFDocument) -> some View {
        PageScrubber(
            pageIndex: scrubbedPageIndex,
            pageCount: document.pageCount,
            seek: { requestedPageIndex = $0 },
            commit: { sourcePageIndex, destinationPageIndex in
                guard let selectedDocument else { return }
                recordNavigation(
                    in: selectedDocument,
                    from: sourcePageIndex,
                    to: destinationPageIndex
                )
            }
        )
        .id(scrubberRevision)
        .frame(maxWidth: .infinity)
    }


    private var isLandscapeInterface: Bool {
        if deviceOrientation.isLandscape {
            return true
        }
        if deviceOrientation.isPortrait {
            return false
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation
            .isLandscape ?? false
    }

    private func toggleReaderFocus() {
        withAnimation(.easeInOut(duration: 0.24)) {
            if !isReaderFocused {
                isSearchPresented = false
            }
            isReaderFocused.toggle()
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
        let matchingDocuments = documents.filter { $0.matches(url) }
        if let existingDocument = matchingDocuments.first {
            for duplicate in matchingDocuments.dropFirst() {
                close(duplicate.id)
            }
            selectDocument(existingDocument.id)
            return
        }

        let isAccessingSecurityScope = url.startAccessingSecurityScopedResource()

        guard let document = OpenDocument(
            url: url,
            isAccessingSecurityScope: isAccessingSecurityScope
        ) else {
            errorMessage = "Downdraft couldn’t save permission to reopen this PDF."
            return
        }
        document.bookmarkPageIndices = BookmarkStore.bookmarks(for: document)
            ?? document.bookmarkPageIndices
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
        treatsFirstPageAsCover = document.displaysAsBook
        scrubbedPageIndex = document.lastPageIndex
        requestedPageIndex = nil
        let storedBookmarks = BookmarkStore.bookmarks(for: document)
        if let storedBookmarks {
            document.bookmarkPageIndices = storedBookmarks
        } else {
            BookmarkStore.save(document.bookmarkPageIndices, for: document)
        }
        bookmarkPageIndices = document.bookmarkPageIndices
        RecentDocumentStore.record(
            id: document.id,
            name: document.displayName,
            bookmarkData: document.bookmarkData,
            document: document.pdfDocument
        )
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
        recordNavigation(to: searchResults.first)
    }

    private func moveSearchResult(by offset: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchResultIndex = (currentSearchResultIndex + offset + searchResults.count)
            % searchResults.count
        recordNavigation(to: currentSearchSelection)
    }

    private func clearSearch() {
        searchResults = []
        currentSearchResultIndex = 0
    }

    private func setFirstPageCover(_ value: Bool) {
        treatsFirstPageAsCover = value
        selectedDocument?.displaysAsBook = value
        saveDocuments()
    }

    private func goToBookmark(at index: Int) {
        guard let document = selectedDocument,
              let pageIndex = document.bookmarkPageIndices[index] else { return }
        navigate(to: pageIndex)
    }

    private func storeBookmark(at index: Int) {
        guard let document = selectedDocument else { return }
        document.bookmarkPageIndices[index] = document.lastPageIndex
        bookmarkPageIndices[index] = document.lastPageIndex
        BookmarkStore.save(document.bookmarkPageIndices, for: document)
        saveDocuments()
    }

    private func openBookmark(_ bookmarkData: Data) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            errorMessage = "The PDF is no longer available in Files."
            return
        }
        open(url)
    }

    private func updatePage(_ pageIndex: Int, for id: OpenDocument.ID) {
        guard let document = documents.first(where: { $0.id == id }),
              document.lastPageIndex != pageIndex else { return }
        document.lastPageIndex = pageIndex
        if id == selectedDocumentID {
            scrubbedPageIndex = pageIndex
            requestedPageIndex = nil
        }
        saveDocuments()
    }

    private func navigate(to pageIndex: Int) {
        guard let document = selectedDocument else { return }
        recordNavigation(in: document, from: document.lastPageIndex, to: pageIndex)
        requestedPageIndex = pageIndex
    }

    private func recordNavigation(to selection: PDFSelection?) {
        guard let document = selectedDocument,
              let page = selection?.pages.first else { return }
        recordNavigation(
            in: document,
            from: document.lastPageIndex,
            to: document.pdfDocument?.index(for: page) ?? document.lastPageIndex
        )
    }

    private func recordNavigation(in document: OpenDocument, from source: Int, to destination: Int) {
        document.recordNavigation(from: source, to: destination)
        navigationRevision += 1
    }

    private func navigateBack(in document: OpenDocument) {
        guard let pageIndex = document.navigateBack(from: document.lastPageIndex) else { return }
        navigationRevision += 1
        scrubbedPageIndex = pageIndex
        scrubberRevision += 1
        requestedPageIndex = pageIndex
    }

    private func navigateForward(in document: OpenDocument) {
        guard let pageIndex = document.navigateForward(from: document.lastPageIndex) else { return }
        navigationRevision += 1
        scrubbedPageIndex = pageIndex
        scrubberRevision += 1
        requestedPageIndex = pageIndex
    }

    private func saveDocuments() {
        OpenDocument.save(documents)
    }
}

private extension View {
    @ViewBuilder
    func readerSearchable(
        _ isEnabled: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>
    ) -> some View {
        if isEnabled {
            searchable(text: text, isPresented: isPresented, prompt: "Find in PDF")
        } else {
            self
        }
    }
}

private struct PageScrubber: View {
    let pageIndex: Int
    let pageCount: Int
    let seek: (Int) -> Void
    let commit: (Int, Int) -> Void
    @State private var pageIndexWhenScrubbingBegan: Int?
    @State private var pendingPageIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            Text("Page \(pageIndex + 1) of \(pageCount)")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 104, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(pendingPageIndex ?? pageIndex) },
                    set: { newValue in
                        let newPageIndex = Int(newValue.rounded())
                        pendingPageIndex = newPageIndex
                        seek(newPageIndex)
                    }
                ),
                in: 0...Double(max(pageCount - 1, 0)),
                step: 1,
                onEditingChanged: { isEditing in
                    if isEditing {
                        pageIndexWhenScrubbingBegan = pageIndex
                        pendingPageIndex = pageIndex
                        return
                    }

                    let sourcePageIndex = pageIndexWhenScrubbingBegan ?? pageIndex
                    let destinationPageIndex = pendingPageIndex ?? pageIndex
                    commit(sourcePageIndex, destinationPageIndex)
                    pageIndexWhenScrubbingBegan = nil
                    pendingPageIndex = nil
                }
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .onChange(of: pageIndex) { _, _ in
            // Outside an active drag, the PDF view is authoritative.  This
            // covers links, contents, search, history, bookmarks, and
            // ordinary scrolling as well as direct scrubber moves.
            if pageIndexWhenScrubbingBegan == nil {
                pendingPageIndex = nil
            }
        }
    }
}

private struct BookmarkSlotButton: UIViewRepresentable {
    let number: Int
    let isSet: Bool
    var size: CGFloat = 36
    let goToBookmark: () -> Void
    let storeBookmark: () -> Void

    func makeUIView(context: Context) -> BookmarkSlotControl {
        BookmarkSlotControl(size: size)
    }

    func updateUIView(_ control: BookmarkSlotControl, context: Context) {
        control.configure(
            number: number,
            isSet: isSet,
            goToBookmark: goToBookmark,
            storeBookmark: storeBookmark
        )
    }
}

private final class BookmarkSlotControl: UIControl {
    private let label = UILabel()
    private var goToBookmark: () -> Void = { }
    private var storeBookmark: () -> Void = { }
    private var didStoreDuringTouch = false
    private var mutedColor = UIColor.clear
    private let size: CGFloat

    override var intrinsicContentSize: CGSize {
        CGSize(width: size, height: size)
    }

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addTarget(self, action: #selector(pressCancelled), for: [.touchUpOutside, .touchCancel])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        addGestureRecognizer(longPress)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = bounds.height / 2
    }

    func configure(
        number: Int,
        isSet: Bool,
        goToBookmark: @escaping () -> Void,
        storeBookmark: @escaping () -> Void
    ) {
        self.goToBookmark = goToBookmark
        self.storeBookmark = storeBookmark
        label.text = "\(number)"
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: isSet ? .semibold : .regular)
        mutedColor = isSet ? tintColor.withAlphaComponent(0.18) : .clear
        if !isHighlighted {
            backgroundColor = mutedColor
        }
        accessibilityLabel = "Bookmark \(number)"
        accessibilityHint = isSet
            ? "Double tap to go to its saved page. Press and hold to replace it with the current page."
            : "Press and hold to save the current page."
    }

    @objc private func pressBegan() {
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.backgroundColor = self.tintColor.withAlphaComponent(0.42)
            self.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }
    }

    @objc private func pressCancelled() {
        releaseTension()
    }

    private func releaseTension() {
        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            usingSpringWithDamping: 0.58,
            initialSpringVelocity: 0.8,
            options: [.beginFromCurrentState]
        ) {
            self.backgroundColor = self.mutedColor
            self.transform = .identity
        }
    }

    @objc private func tapped() {
        defer { didStoreDuringTouch = false }
        guard !didStoreDuringTouch else { return }
        releaseTension()
        goToBookmark()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        didStoreDuringTouch = true
        storeBookmark()
        releaseTension()
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
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    } else {
                        Text(entry.title)
                            .foregroundStyle(.primary)
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
    let originalURLString: String
    var lastPageIndex: Int
    var displaysAsBook: Bool
    var bookmarkPageIndices: [Int?]
    private var isAccessingFile: Bool
    private var navigationHistory: [Int]
    private var navigationHistoryIndex: Int

    var canNavigateBack: Bool {
        navigationHistoryIndex > 0
    }

    var canNavigateForward: Bool {
        navigationHistoryIndex < navigationHistory.count - 1
    }

    init(
        url: URL?,
        bookmarkData: Data,
        displayName: String,
        originalURLString: String,
        lastPageIndex: Int = 0,
        displaysAsBook: Bool = true,
        bookmarkPageIndices: [Int?] = [nil, nil, nil],
        isAccessingFile: Bool
    ) {
        self.url = url
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.originalURLString = originalURLString
        self.lastPageIndex = lastPageIndex
        self.displaysAsBook = displaysAsBook
        self.bookmarkPageIndices = Array(bookmarkPageIndices.prefix(3))
        while self.bookmarkPageIndices.count < 3 {
            self.bookmarkPageIndices.append(nil)
        }
        self.isAccessingFile = isAccessingFile
        self.navigationHistory = [lastPageIndex]
        self.navigationHistoryIndex = 0
    }

    convenience init?(url: URL, isAccessingSecurityScope: Bool) {
        guard let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            if isAccessingSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            return nil
        }
        self.init(
            url: url,
            bookmarkData: bookmarkData,
            displayName: url.deletingPathExtension().lastPathComponent,
            originalURLString: url.standardizedFileURL.absoluteString,
            isAccessingFile: isAccessingSecurityScope
        )
    }

    func stopAccessingFile() {
        guard isAccessingFile, let url else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessingFile = false
        pdfDocument = nil
    }

    func matches(_ otherURL: URL) -> Bool {
        originalURLString == otherURL.standardizedFileURL.absoluteString
            || url?.standardizedFileURL == otherURL.standardizedFileURL
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
        ) else {
            return false
        }
        let isAccessingSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        url = resolvedURL
        isAccessingFile = isAccessingSecurityScope
        pdfDocument = PDFDocument(url: resolvedURL)
        return pdfDocument != nil
    }

    func recordNavigation(from source: Int, to destination: Int) {
        guard source != destination else { return }
        navigationHistory[navigationHistoryIndex] = source
        navigationHistory.removeSubrange((navigationHistoryIndex + 1)..<navigationHistory.count)
        navigationHistory.append(destination)
        if navigationHistory.count > 100 {
            navigationHistory.removeFirst(navigationHistory.count - 100)
        }
        navigationHistoryIndex = navigationHistory.count - 1
    }

    func navigateBack(from currentPage: Int) -> Int? {
        guard canNavigateBack else { return nil }
        navigationHistory[navigationHistoryIndex] = currentPage
        navigationHistoryIndex -= 1
        return navigationHistory[navigationHistoryIndex]
    }

    func navigateForward(from currentPage: Int) -> Int? {
        guard canNavigateForward else { return nil }
        navigationHistory[navigationHistoryIndex] = currentPage
        navigationHistoryIndex += 1
        return navigationHistory[navigationHistoryIndex]
    }

    deinit {
        stopAccessingFile()
    }

    private struct SavedDocument: Codable {
        let bookmarkData: Data
        let displayName: String
        let originalURLString: String?
        let lastPageIndex: Int
        let displaysAsBook: Bool?
        let bookmarkPageIndices: [Int?]?
    }

    private static let savedDocumentsKey = "openDocuments"

    static func save(_ documents: [OpenDocument]) {
        let savedDocuments = documents.map {
            SavedDocument(
                bookmarkData: $0.bookmarkData,
                displayName: $0.displayName,
                originalURLString: $0.originalURLString,
                lastPageIndex: $0.lastPageIndex,
                displaysAsBook: $0.displaysAsBook,
                bookmarkPageIndices: $0.bookmarkPageIndices
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
                originalURLString: savedDocument.originalURLString ?? "",
                lastPageIndex: savedDocument.lastPageIndex,
                displaysAsBook: savedDocument.displaysAsBook ?? true,
                bookmarkPageIndices: savedDocument.bookmarkPageIndices ?? [nil, nil, nil],
                isAccessingFile: false
            )
        }
    }
}

private enum BookmarkStore {
    private static let savedBookmarksKey = "quickBookmarksByDocument"

    static func bookmarks(for document: OpenDocument) -> [Int?]? {
        guard let key = key(for: document),
              let data = UserDefaults.standard.data(forKey: savedBookmarksKey),
              let storedBookmarks = try? JSONDecoder().decode([String: [Int?]].self, from: data),
              let bookmarks = storedBookmarks[key] else {
            return nil
        }
        return normalized(bookmarks)
    }

    static func save(_ bookmarks: [Int?], for document: OpenDocument) {
        guard let key = key(for: document) else { return }
        var storedBookmarks: [String: [Int?]] = [:]
        if let data = UserDefaults.standard.data(forKey: savedBookmarksKey),
           let decoded = try? JSONDecoder().decode([String: [Int?]].self, from: data) {
            storedBookmarks = decoded
        }
        storedBookmarks[key] = normalized(bookmarks)
        guard let data = try? JSONEncoder().encode(storedBookmarks) else { return }
        UserDefaults.standard.set(data, forKey: savedBookmarksKey)
    }

    private static func key(for document: OpenDocument) -> String? {
        if !document.originalURLString.isEmpty {
            return document.originalURLString
        }
        return document.url?.standardizedFileURL.absoluteString
    }

    private static func normalized(_ bookmarks: [Int?]) -> [Int?] {
        var normalized = Array(bookmarks.prefix(3))
        while normalized.count < 3 {
            normalized.append(nil)
        }
        return normalized
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
