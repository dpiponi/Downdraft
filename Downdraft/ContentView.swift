import PDFKit
import SwiftUI
import UIKit
import WidgetKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var documents = OpenDocument.restoreSavedDocuments()
    @State private var selectedDocumentID: OpenDocument.ID?
    @State private var isShowingFilePicker = false
    @State private var isShowingDocumentSwitcher = false
    @State private var errorMessage: String?
    @State private var isReaderFocused = false
    @State private var searchText = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var currentSearchResultIndex = 0
    @State private var isShowingContents = false
    @State private var isShowingMetadata = false
    @State private var outlineDestination: PDFDestination?
    @State private var treatsFirstPageAsCover = true
    @State private var scrubbedPageIndex = 0
    @State private var requestedPageIndex: Int?
    @State private var bookmarkPageIndices: [Int?] = []
    // Forces SwiftUI to refresh history-button availability after mutating a
    // reference-type document's navigation history.
    @State private var navigationRevision = 0
    @State private var scrubberRevision = 0
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var isSearchPresented = false

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

    private var visibleBookmarks: [(index: Int, pageIndex: Int)] {
        bookmarkPageIndices.enumerated().compactMap { index, pageIndex in
            pageIndex.map { (index, $0) }
        }
    }

    private var maximumBookmarkRailButtons: Int {
        if isLandscapeInterface {
            return isPhone ? 4 : 4
        }
        return isPhone ? 5 : 7
    }

    /// Includes space for the add control, and for the overflow control when
    /// necessary, so the rail cannot collide with the bottom scrubber.
    private var visibleBookmarkLimit: Int {
        let directCapacity = maximumBookmarkRailButtons - 1
        return visibleBookmarks.count > directCapacity ? directCapacity - 1 : directCapacity
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
                            ZStack {
                                ForEach(documents) { document in
                                    reader(for: document)
                                }

                                if selectedDocument?.url == nil {
                                    ProgressView()
                                }

                                if !isReaderFocused, let document = selectedDocument,
                                   let pdfDocument = document.pdfDocument {
                                    readerChrome(for: pdfDocument)
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
            // The system toolbar changes the hosting controller's safe area
            // while it appears and disappears.  PDFKit interprets that as a
            // new layout and may reset its private scroll view.  The reader's
            // chrome is therefore a sibling overlay, never a toolbar.
            .toolbar(.hidden, for: .navigationBar)
        }
        // Changing `statusBarHidden` changes the hosting controller's safe
        // area, which makes PDFKit relayout even though the status bar is an
        // overlay. Persistent system overlays handle reader-mode chrome
        // without changing the PDF view's geometry.
        .statusBarHidden(false)
        .persistentSystemOverlays(isReaderFocused ? .hidden : .visible)
        .toolbar(.hidden, for: .bottomBar)
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
        .sheet(isPresented: $isShowingMetadata) {
            if let document = selectedDocument, let pdfDocument = document.pdfDocument {
                PDFMetadataView(document: pdfDocument, filename: document.displayName)
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
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientation = UIDevice.current.orientation
            if selectedDocumentID == nil {
                let documentID = OpenDocument.restoredSelectedDocumentID(in: documents)
                    ?? documents.first?.id
                if let documentID {
                    selectDocument(documentID)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification
        )) { _ in
            deviceOrientation = UIDevice.current.orientation
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )) { _ in
            refreshSharedReadingState()
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
                isReaderFocused: isReaderFocused,
                isLandscape: !isPhone && isLandscapeInterface,
                displaysAsBook: treatsFirstPageAsCover,
                searchSelection: isSelected ? currentSearchSelection : nil,
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

    /// Reader controls deliberately sit beside the PDF view, rather than in a
    /// navigation or bottom toolbar.  They can animate independently without
    /// changing PDFKit's frame or safe area.
    private func readerChrome(for document: PDFDocument) -> some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.68), .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: isPhone ? 210 : 180)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.68)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: isPhone ? 260 : 200)
            }
            .allowsHitTesting(false)

            ZStack(alignment: .top) {
                // Controls do not fill this entire rectangle, but every
                // point within it is UI space and must not fall through to
                // the gesture-heavy PDFView underneath.
                Color.clear
                    .frame(height: isPhone ? 170 : 140)
                    .contentShape(Rectangle())
                    .onTapGesture { }

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        documentMenu
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.001), in: Circle())

                        topReaderControls

                        Spacer(minLength: 0)

                        if !isPhone || isSearchPresented {
                            searchControls
                                .frame(maxWidth: isPhone ? .infinity : 440)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, isPhone ? 56 : 42)
                    Spacer(minLength: 0)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))

            GeometryReader { _ in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        bookmarkControls
                    }
                    // Match the scrubber capsule's trailing edge.  The
                    // stack grows upward while the add control stays put.
                    .padding(.trailing, 28)
                }
                .padding(.bottom, isPhone ? 176 : 126)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    if isPhone {
                        historyControls
                            .padding(.vertical, 8)
                    }
                    scrubber(for: document)
                        .padding(.top, 6)
                        .padding(.bottom, isPhone ? 14 : 10)
                }
                .padding(.horizontal, 12)
                .padding(.horizontal, 28)
                .padding(.bottom, isPhone ? 56 : 42)
                .foregroundStyle(.white)
                .tint(.white)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.easeInOut(duration: 0.24), value: isSearchPresented)
        .allowsHitTesting(true)
    }

    private var topReaderControls: some View {
        HStack(spacing: 12) {
            primaryReaderControls
            if !isPhone {
                historyControls
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .background(.black.opacity(0.001), in: Capsule())
                    .tint(.white)
            }
        }
    }

    private var primaryReaderControls: some View {
        HStack(spacing: isPhone ? 12 : 18) {
            if !isPhone {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Open PDF")
                .frame(width: 40, height: 40)
                if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                    Button { isShowingContents = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Contents")
                    .frame(width: 40, height: 40)
                }
                Button { isShowingMetadata = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("PDF information")
                .frame(width: 40, height: 40)
                Button {
                    setFirstPageCover(!treatsFirstPageAsCover)
                } label: {
                    Image(systemName: treatsFirstPageAsCover ? "rectangle.split.2x1" : "rectangle")
                }
                .accessibilityLabel("Toggle facing-page cover")
                .frame(width: 40, height: 40)
            } else {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Open PDF")
                Button {
                    isSearchPresented.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
                Menu("More", systemImage: "ellipsis.circle") {
                    if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                        Button("Contents", systemImage: "list.bullet") { isShowingContents = true }
                    }
                    Button("PDF Information", systemImage: "info.circle") { isShowingMetadata = true }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.black.opacity(0.001), in: Capsule())
        .tint(.white)
        .foregroundStyle(.white)
        .font(.title3.weight(.medium))
    }

    private var bookmarkControls: some View {
        VStack(spacing: 10) {
            ForEach(Array(visibleBookmarks.prefix(visibleBookmarkLimit)), id: \.index) { bookmark in
                BookmarkSlotButton(
                    title: "\(visibleBookmarkNumber(for: bookmark.index))",
                    accessibilityLabel: "Bookmark \(visibleBookmarkNumber(for: bookmark.index))",
                    isSet: true,
                    size: 40,
                    goToBookmark: { goToBookmark(at: bookmark.index) },
                    storeBookmark: { storeBookmark(at: bookmark.index) },
                    removeBookmark: { removeBookmark(at: bookmark.index) }
                )
                .frame(width: 40, height: 40)
            }
            if visibleBookmarks.count > visibleBookmarkLimit {
                Menu {
                    ForEach(Array(visibleBookmarks.dropFirst(visibleBookmarkLimit)), id: \.index) { bookmark in
                        Menu("Bookmark \(visibleBookmarkNumber(for: bookmark.index))") {
                            Button("Go to Page \(bookmark.pageIndex + 1)") {
                                goToBookmark(at: bookmark.index)
                            }
                            Button("Remove Bookmark", role: .destructive) {
                                removeBookmark(at: bookmark.index)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("More bookmarks")
            }
            BookmarkSlotButton(
                title: "+",
                accessibilityLabel: "Add Bookmark",
                isSet: false,
                size: 40,
                goToBookmark: { },
                storeBookmark: addBookmark,
                removeBookmark: nil
            )
            .frame(width: 40, height: 40)
        }
        .padding(12)
        .background(.black.opacity(0.001), in: Capsule())
        .tint(.white)
        .foregroundStyle(.white)
        .font(.title3.weight(.medium))
    }

    private var documentMenu: some View {
        Button {
            isShowingDocumentSwitcher = true
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Documents")
        .tint(.white)
        .popover(isPresented: $isShowingDocumentSwitcher) {
            DocumentSwitcherView(
                documents: documents,
                selectedID: selectedDocumentID,
                select: { id in
                    isShowingDocumentSwitcher = false
                    selectDocument(id)
                },
                openPDF: {
                    isShowingDocumentSwitcher = false
                    isShowingFilePicker = true
                },
                close: close
            )
            .presentationCompactAdaptation(.sheet)
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            TextField("Find in PDF", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .onSubmit(performSearch)
            if !searchResults.isEmpty {
                Button { moveSearchResult(by: -1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Previous match")
                Button { moveSearchResult(by: 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Next match")
                Text("\(currentSearchResultIndex + 1) of \(searchResults.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(.black.opacity(0.001), in: Capsule())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.45))
                .frame(height: 1)
        }
        .tint(.white)
        .foregroundStyle(.white)
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            if let document = selectedDocument {
                Button { navigateBack(in: document) } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Back")
                    .disabled(!document.canNavigateBack)
                Button { navigateForward(in: document) } label: {
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Forward")
                    .disabled(!document.canNavigateForward)
            }
        }
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
        restoreSharedReadingState(for: document)
        selectedDocumentID = id
        treatsFirstPageAsCover = document.displaysAsBook
        scrubbedPageIndex = document.lastPageIndex
        requestedPageIndex = nil
        bookmarkPageIndices = document.bookmarkPageIndices
        RecentDocumentStore.record(
            id: document.id,
            name: document.displayName,
            bookmarkData: document.bookmarkData,
            document: document.pdfDocument,
            thumbnailCacheIdentity: document.readingStateIdentity
        )
        outlineDestination = nil
        clearSearch()
        saveDocuments()
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
        if let identity = document.readingStateIdentity {
            ReadingStateStore.saveBookmark(
                document.lastPageIndex,
                at: index,
                for: identity,
                fallbackPageIndex: document.lastPageIndex,
                fallbackBookmarks: document.bookmarkPageIndices
            )
        }
        saveDocuments()
    }

    private func addBookmark() {
        guard let document = selectedDocument else { return }
        document.bookmarkPageIndices.append(document.lastPageIndex)
        bookmarkPageIndices = document.bookmarkPageIndices
        let index = document.bookmarkPageIndices.index(before: document.bookmarkPageIndices.endIndex)
        if let identity = document.readingStateIdentity {
            ReadingStateStore.saveBookmark(
                document.lastPageIndex,
                at: index,
                for: identity,
                fallbackPageIndex: document.lastPageIndex,
                fallbackBookmarks: document.bookmarkPageIndices
            )
        }
        saveDocuments()
    }

    private func removeBookmark(at index: Int) {
        guard let document = selectedDocument,
              document.bookmarkPageIndices.indices.contains(index) else { return }
        document.bookmarkPageIndices[index] = nil
        bookmarkPageIndices = document.bookmarkPageIndices
        if let identity = document.readingStateIdentity {
            ReadingStateStore.saveBookmark(
                nil,
                at: index,
                for: identity,
                fallbackPageIndex: document.lastPageIndex,
                fallbackBookmarks: document.bookmarkPageIndices
            )
        }
        saveDocuments()
    }

    private func visibleBookmarkNumber(for index: Int) -> Int {
        (bookmarkPageIndices[..<index].compactMap { $0 }.count) + 1
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
        if let identity = document.readingStateIdentity {
            ReadingStateStore.savePage(
                pageIndex,
                for: identity,
                fallbackBookmarks: document.bookmarkPageIndices
            )
        }
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
        OpenDocument.save(documents, selectedDocumentID: selectedDocumentID)
    }

    private func restoreSharedReadingState(for document: OpenDocument) {
        guard let identity = document.readingStateIdentity else { return }
        let state = ReadingStateStore.state(
            for: identity,
            fallbackPageIndex: document.lastPageIndex,
            fallbackBookmarks: document.bookmarkPageIndices
        )
        document.lastPageIndex = state.page.index
        document.bookmarkPageIndices = state.bookmarks.map(\.pageIndex)
    }

    private func refreshSharedReadingState() {
        guard let document = selectedDocument,
              let identity = document.readingStateIdentity else { return }
        let previousPage = document.lastPageIndex
        let state = ReadingStateStore.state(
            for: identity,
            fallbackPageIndex: previousPage,
            fallbackBookmarks: document.bookmarkPageIndices
        )
        document.lastPageIndex = state.page.index
        document.bookmarkPageIndices = state.bookmarks.map(\.pageIndex)
        bookmarkPageIndices = document.bookmarkPageIndices
        if state.page.index != previousPage {
            scrubbedPageIndex = state.page.index
            scrubberRevision += 1
            requestedPageIndex = state.page.index
        }
        saveDocuments()
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
    let title: String
    let accessibilityLabel: String
    let isSet: Bool
    var size: CGFloat = 36
    let goToBookmark: () -> Void
    let storeBookmark: () -> Void
    let removeBookmark: (() -> Void)?

    func makeUIView(context: Context) -> BookmarkSlotControl {
        BookmarkSlotControl(size: size)
    }

    func updateUIView(_ control: BookmarkSlotControl, context: Context) {
        control.configure(
            title: title,
            accessibilityLabel: accessibilityLabel,
            isSet: isSet,
            goToBookmark: goToBookmark,
            storeBookmark: storeBookmark,
            removeBookmark: removeBookmark
        )
    }
}

private final class BookmarkSlotControl: UIControl {
    private let label = UILabel()
    private let holdProgressLayer = CAShapeLayer()
    private var goToBookmark: () -> Void = { }
    private var storeBookmark: () -> Void = { }
    private var removeBookmark: (() -> Void)?
    private var didStoreDuringTouch = false
    private var didRemoveDuringTouch = false
    private var mutedColor = UIColor.clear
    private let size: CGFloat

    override var intrinsicContentSize: CGSize {
        CGSize(width: size, height: size)
    }

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        isEnabled = true
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        holdProgressLayer.fillColor = UIColor.clear.cgColor
        holdProgressLayer.lineWidth = 2.5
        holdProgressLayer.lineCap = .round
        holdProgressLayer.strokeEnd = 0
        holdProgressLayer.opacity = 0
        layer.addSublayer(holdProgressLayer)
        addSubview(label)
        addTarget(self, action: #selector(pressBegan), for: .touchDown)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addTarget(self, action: #selector(pressCancelled), for: [.touchUpOutside, .touchCancel])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        addGestureRecognizer(longPress)

        let removePan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        removePan.cancelsTouchesInView = true
        addGestureRecognizer(removePan)

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
        holdProgressLayer.frame = bounds
        holdProgressLayer.path = UIBezierPath(
            ovalIn: bounds.insetBy(dx: 3, dy: 3)
        ).cgPath
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The SwiftUI overlay is deliberately just above a gesture-heavy
        // PDFView.  Keep the whole visual slot an explicit hit target.
        bounds.insetBy(dx: -6, dy: -6).contains(point)
    }

    func configure(
        title: String,
        accessibilityLabel: String,
        isSet: Bool,
        goToBookmark: @escaping () -> Void,
        storeBookmark: @escaping () -> Void,
        removeBookmark: (() -> Void)?
    ) {
        self.goToBookmark = goToBookmark
        self.storeBookmark = storeBookmark
        self.removeBookmark = removeBookmark
        label.text = title
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: isSet ? .semibold : .regular)
        holdProgressLayer.strokeColor = tintColor.cgColor
        mutedColor = isSet ? tintColor.withAlphaComponent(0.18) : .clear
        if !isHighlighted {
            backgroundColor = mutedColor
        }
        self.accessibilityLabel = accessibilityLabel
        accessibilityHint = isSet
            ? "Double tap to go to its saved page. Press and hold to replace it with the current page. Drag left to remove it."
            : "Press and hold to add the current page as a new bookmark."
    }

    @objc private func pressBegan() {
        layer.removeAllAnimations()
        holdProgressLayer.removeAllAnimations()
        holdProgressLayer.strokeEnd = 0
        holdProgressLayer.opacity = 1
        let progress = CABasicAnimation(keyPath: "strokeEnd")
        progress.fromValue = 0
        progress.toValue = 1
        progress.duration = 0.5
        progress.timingFunction = CAMediaTimingFunction(name: .linear)
        holdProgressLayer.add(progress, forKey: "holdProgress")
        holdProgressLayer.strokeEnd = 1
        UIView.animate(withDuration: 0.5, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
            self.backgroundColor = self.tintColor.withAlphaComponent(0.52)
            self.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
        }
    }

    @objc private func pressCancelled() {
        releaseTension()
    }

    private func releaseTension(recorded: Bool = false) {
        holdProgressLayer.removeAllAnimations()
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

        if recorded {
            let pulse = CAAnimationGroup()
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            pulse.animations = [scale, fade]
            pulse.duration = 0.28
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            holdProgressLayer.add(pulse, forKey: "recordedPulse")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = holdProgressLayer.presentation()?.opacity ?? holdProgressLayer.opacity
            fade.toValue = 0
            fade.duration = 0.16
            holdProgressLayer.add(fade, forKey: "cancelHold")
        }
        holdProgressLayer.opacity = 0
    }

    @objc private func tapped() {
        defer {
            didStoreDuringTouch = false
            didRemoveDuringTouch = false
        }
        guard !didStoreDuringTouch, !didRemoveDuringTouch else { return }
        releaseTension()
        goToBookmark()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        didStoreDuringTouch = true
        storeBookmark()
        releaseTension(recorded: true)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard removeBookmark != nil else { return }
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began, .changed:
            guard translation.x < 0 else { return }
            didStoreDuringTouch = true
            releaseTension()
            let progress = min(1, abs(translation.x) / 56)
            backgroundColor = UIColor.systemRed.withAlphaComponent(0.18 + 0.36 * progress)
            transform = CGAffineTransform(translationX: max(-14, translation.x * 0.25), y: 0)
        case .ended:
            guard translation.x < -56 else {
                releaseTension()
                didStoreDuringTouch = false
                return
            }
            didRemoveDuringTouch = true
            removeBookmark?()
            UIView.animate(withDuration: 0.18, animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: -24, y: 0)
            }) { _ in
                self.alpha = 1
                self.transform = .identity
            }
        case .cancelled, .failed:
            releaseTension()
            didStoreDuringTouch = false
        default:
            break
        }
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

private struct PDFMetadataView: View {
    let document: PDFDocument
    let filename: String
    @Environment(\.dismiss) private var dismiss

    private var rows: [(label: String, value: String)] {
        let attributes = document.documentAttributes ?? [:]
        let keys: [(String, PDFDocumentAttribute)] = [
            ("Title", .titleAttribute),
            ("Author", .authorAttribute),
            ("Subject", .subjectAttribute),
            ("Keywords", .keywordsAttribute),
            ("Creator", .creatorAttribute),
            ("Producer", .producerAttribute),
            ("Created", .creationDateAttribute),
            ("Modified", .modificationDateAttribute)
        ]
        return keys.compactMap { label, key in
            guard let value = attributes[key] else { return nil }
            return (label, formatted(value))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Document") {
                    LabeledContent("File", value: filename)
                    LabeledContent("Pages", value: String(document.pageCount))
                }
                if !rows.isEmpty {
                    Section("Metadata") {
                        ForEach(rows, id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PDF Information")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formatted(_ value: Any) -> String {
        if let date = value as? Date {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        if let values = value as? [String] {
            return values.joined(separator: ", ")
        }
        return String(describing: value)
    }
}

private final class OpenDocument: Identifiable {
    let id = UUID()
    private(set) var url: URL?
    private(set) var pdfDocument: PDFDocument?
    private(set) var readingStateIdentity: String?
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

    /// Survives the app's reconstruction of its in-memory document objects.
    var persistentIdentity: String {
        if !originalURLString.isEmpty { return originalURLString }
        return url?.standardizedFileURL.absoluteString ?? ""
    }

    init(
        url: URL?,
        bookmarkData: Data,
        displayName: String,
        originalURLString: String,
        lastPageIndex: Int = 0,
        displaysAsBook: Bool = true,
        bookmarkPageIndices: [Int?] = [],
        isAccessingFile: Bool
    ) {
        self.url = url
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.originalURLString = originalURLString
        self.lastPageIndex = lastPageIndex
        self.displaysAsBook = displaysAsBook
        self.bookmarkPageIndices = bookmarkPageIndices
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
            establishReadingStateIdentity()
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
        establishReadingStateIdentity()
        return pdfDocument != nil
    }

    private func establishReadingStateIdentity() {
        guard readingStateIdentity == nil, let url, let pdfDocument else { return }
        readingStateIdentity = ReadingStateStore.identity(for: url, document: pdfDocument)
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
    private static let selectedDocumentKey = "selectedDocumentIdentity"

    static func save(_ documents: [OpenDocument], selectedDocumentID: OpenDocument.ID?) {
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
        if let selectedDocument = documents.first(where: { $0.id == selectedDocumentID }) {
            UserDefaults.standard.set(selectedDocument.persistentIdentity, forKey: selectedDocumentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDocumentKey)
        }
    }

    static func restoredSelectedDocumentID(in documents: [OpenDocument]) -> OpenDocument.ID? {
        guard let identity = UserDefaults.standard.string(forKey: selectedDocumentKey) else { return nil }
        return documents.first(where: { $0.persistentIdentity == identity })?.id
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
                bookmarkPageIndices: savedDocument.bookmarkPageIndices ?? [],
                isAccessingFile: false
            )
        }
    }
}

private struct DocumentSwitcherView: View {
    let documents: [OpenDocument]
    let selectedID: OpenDocument.ID?
    let select: (OpenDocument.ID) -> Void
    let openPDF: () -> Void
    let close: (OpenDocument.ID) -> Void

    private var recentThumbnails: [Data: Data] {
        Dictionary(
            uniqueKeysWithValues: RecentDocumentStore.documents.compactMap { document in
                document.thumbnailData.map { (document.bookmarkData, $0) }
            }
        )
    }

    private var preferredHeight: CGFloat {
        min(640, max(220, CGFloat(documents.count) * 68 + 72))
    }

    private func thumbnailData(for document: OpenDocument) -> Data? {
        DocumentThumbnailCache.data(
            contentIdentity: document.readingStateIdentity,
            bookmarkData: document.bookmarkData
        ) ?? recentThumbnails[document.bookmarkData]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(documents) { document in
                    HStack(spacing: 12) {
                        DocumentThumbnail(data: thumbnailData(for: document))

                        Button {
                            select(document.id)
                        } label: {
                            Text(document.displayName)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        if document.id == selectedID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }

                        Button {
                            close(document.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.red)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close \(document.displayName)")
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Open PDFs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open PDF", systemImage: "folder") {
                        openPDF()
                    }
                }
            }
        }
        .frame(
            minWidth: 340,
            idealWidth: 520,
            maxWidth: 600,
            minHeight: 220,
            idealHeight: preferredHeight,
            maxHeight: 640
        )
    }
}

private struct DocumentThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(width: 36, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
