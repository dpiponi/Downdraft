import PDFKit
import SwiftUI
import UIKit
import WidgetKit
import UniformTypeIdentifiers

private struct BookmarkPreview {
    let image: UIImage
    let pageIndex: Int
}

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
    @State private var readsHorizontally = false
    @State private var scrubbedPageIndex = 0
    @State private var pdfKitCurrentPageIndex: Int?
    @State private var requestedPageIndex: Int?
    // PDFKit needs a distinct request for every explicit jump, including a
    // second jump to a page that was requested previously.
    @State private var requestedPageRequestID: UUID?
    @State private var bookmarkPageIndices: [Int?] = []
    // Forces SwiftUI to refresh history-button availability after mutating a
    // reference-type document's navigation history.
    @State private var navigationRevision = 0
    @State private var scrubberRevision = 0
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var isSearchPresented = false
    @State private var selectedPDFText: String?
    @State private var loadingMessage = "Opening PDF…"
    @FocusState private var isSearchFieldFocused: Bool
    @State private var bookmarkPreview: BookmarkPreview?

    private var selectedDocument: OpenDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    private var loadingReaderState: some View {
        ZStack {
            Color.black.opacity(0.72)

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(loadingMessage)
                    .font(.callout)
                Button("Open Another PDF") {
                    isShowingFilePicker = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .foregroundStyle(.white)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentSearchSelection: PDFSelection? {
        guard searchResults.indices.contains(currentSearchResultIndex) else { return nil }
        return searchResults[currentSearchResultIndex]
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var isSearchActive: Bool {
        isSearchFieldFocused || !searchText.isEmpty
    }

    private var visibleBookmarks: [(index: Int, pageIndex: Int)] {
        bookmarkPageIndices.enumerated().compactMap { index, pageIndex in
            pageIndex.map { (index, $0) }
        }
        .sorted { lhs, rhs in
            lhs.pageIndex == rhs.pageIndex ? lhs.index < rhs.index : lhs.pageIndex < rhs.pageIndex
        }
    }

    /// Calculates the thumbnail count from the actual reader height. The rail
    /// grows upward from the fixed add button, but must never intrude into the
    /// top controls (including the optional search row).
    private func visibleBookmarkLimit(for readerHeight: CGFloat) -> Int {
        let topControlsClearance: CGFloat = isPhone ? 180 : 140
        let railBottomInset: CGFloat = isPhone ? 176 : 144
        let railVerticalPadding: CGFloat = 16
        let thumbnailHeight: CGFloat = 62
        let addButtonHeight: CGFloat = 40
        let spacing: CGFloat = 8
        let availableHeight = max(0, readerHeight - topControlsClearance - railBottomInset)
        let directCapacity = max(
            1,
            Int(((availableHeight - railVerticalPadding - addButtonHeight) / (thumbnailHeight + spacing)).rounded(.down))
        )
        return visibleBookmarks.count > directCapacity
            ? max(1, directCapacity - 1)
            : directCapacity
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

                                if selectedDocument?.pdfDocument == nil {
                                    loadingReaderState
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
                PDFMetadataView(
                    document: pdfDocument,
                    filename: document.fullFileName,
                    fileLocation: document.fullFileLocation
                )
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-fixture") {
                installUITestFixture()
                return
            }
            #endif
            if selectedDocumentID == nil {
                let documentID = OpenDocument.restoredSelectedDocumentID(in: documents)
                    ?? documents.first?.id
                if let documentID {
                    // Let SwiftUI draw its loading state before PDFKit opens
                    // the remembered document. Large or cloud-backed PDFs can
                    // otherwise make a cold launch look unresponsive.
                    selectedDocumentID = documentID
                    DispatchQueue.main.async {
                        selectDocument(documentID)
                    }
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
                readsHorizontally: readsHorizontally,
                searchSelection: isSelected ? currentSearchSelection : nil,
                outlineDestination: isSelected ? outlineDestination : nil,
                requestedPageIndex: isSelected ? requestedPageIndex : nil,
                requestedPageRequestID: isSelected ? requestedPageRequestID : nil,
                onPageChanged: { pageIndex in
                    updatePage(pageIndex, for: document.id)
                },
                onPDFKitCurrentPageChanged: { pageIndex in
                    guard document.id == selectedDocumentID else { return }
                    pdfKitCurrentPageIndex = pageIndex
                },
                onTextSelectionChanged: { text in
                    guard document.id == selectedDocumentID else { return }
                    selectedPDFText = text
                },
                onJumpToFirstPage: { sourcePageIndex, destinationPageIndex in
                    recordNavigation(
                        in: document,
                        from: sourcePageIndex,
                        to: destinationPageIndex
                    )
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
            chapterPositions: topLevelChapterPositions(in: document),
            seek: requestPage,
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

    /// The PDF outline is already available for the contents sheet.  Its
    /// top-level entries make useful, restrained landmarks on the page bar
    /// without inspecting any additional document data.
    private func topLevelChapterPositions(in document: PDFDocument) -> [Double] {
        guard document.pageCount > 1, let outline = document.outlineRoot else {
            return []
        }

        let lastPageIndex = Double(document.pageCount - 1)
        var seen = Set<Int>()
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let entry = outline.child(at: index),
                  let page = entry.destination?.page else {
                return nil
            }
            let pageIndex = document.index(for: page)
            guard seen.insert(pageIndex).inserted else { return nil }
            return Double(pageIndex) / lastPageIndex
        }
    }

    /// Reader controls deliberately sit beside the PDF view, rather than in a
    /// navigation or bottom toolbar.  They can animate independently without
    /// changing PDFKit's frame or safe area.
    private func readerChrome(for document: PDFDocument) -> some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: isPhone ? 210 : 180)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.78)],
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
                Color.black.opacity(0.001)
                    .frame(height: isPhone ? 180 : 140)
                    .contentShape(Rectangle())
                    .onTapGesture { }

                VStack(spacing: 0) {
                    if isPhone {
                        HStack(alignment: .center, spacing: 8) {
                            documentMenu
                                .frame(width: 48, height: 48)
                                .background(.black.opacity(0.001), in: Circle())

                            topReaderControls

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 56)

                        if isSearchPresented {
                            searchControls
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 28)
                                .padding(.top, 6)
                                .onAppear {
                                    isSearchFieldFocused = true
                                }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 12) {
                            documentMenu
                                .frame(width: 48, height: 48)
                                .background(.black.opacity(0.001), in: Circle())

                            topReaderControls

                            Spacer(minLength: 0)

                            searchControls
                                .frame(maxWidth: 440)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 42)
                    }
                    Spacer(minLength: 0)
                }
                .zIndex(1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        bookmarkControls(visibleLimit: visibleBookmarkLimit(for: geometry.size.height))
                    }
                    // Match the scrubber capsule's trailing edge.  The
                    // stack grows upward while the add control stays put.
                    .padding(.trailing, 28)
                }
                .padding(.bottom, isPhone ? 176 : 144)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))

            if let bookmarkPreview {
                Image(uiImage: bookmarkPreview.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: isPhone ? 180 : 220, height: isPhone ? 252 : 308)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottom) {
                        Text("Page \(bookmarkPreview.pageIndex + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.52), in: Capsule())
                            .padding(.bottom, 12)
                    }
                    .shadow(color: .black.opacity(0.65), radius: 18, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, isPhone ? 90 : 100)
                    .padding(.bottom, isPhone ? 168 : 130)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    .zIndex(10)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    scrubber(for: document)
                        .padding(.top, 6)
                        .padding(.bottom, isPhone ? 14 : 10)
                }
                .frame(maxWidth: isPhone ? 320 : 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, isPhone ? 36 : 42)
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
            if isPhone {
                historyControls
                    .frame(height: 58)
            } else {
                historyControls
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .background(.black.opacity(0.001), in: Capsule())
                    .tint(.white)
            }
        }
    }

    private var primaryReaderControls: some View {
        HStack(spacing: isPhone ? 8 : 18) {
            if !isPhone {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "folder")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open PDF")
                if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                    Button { isShowingContents = true } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Contents")
                }
                Button { isShowingMetadata = true } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("PDF information")
                Menu {
                    Section("First Page") {
                        Button {
                            setFirstPageCover(true)
                        } label: {
                            layoutMenuLabel("First page alone", selected: treatsFirstPageAsCover)
                        }
                        Button {
                            setFirstPageCover(false)
                        } label: {
                            layoutMenuLabel("First page in spread", selected: !treatsFirstPageAsCover)
                        }
                    }
                    Section("Reading Direction") {
                        Button {
                            setReadingDirection(horizontal: false)
                        } label: {
                            layoutMenuLabel("Scroll vertically", selected: !readsHorizontally)
                        }
                        Button {
                            setReadingDirection(horizontal: true)
                        } label: {
                            layoutMenuLabel("Scroll horizontally", selected: readsHorizontally)
                        }
                    }
                } label: {
                    Image(systemName: treatsFirstPageAsCover ? "rectangle.split.2x1" : "rectangle")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Reader layout")
            } else {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "folder")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open PDF")
                Button {
                    presentSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Search")
                if selectedDocument?.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 > 0 {
                    Menu {
                        Button("Contents", systemImage: "list.bullet") { isShowingContents = true }
                        Button("PDF Information", systemImage: "info.circle") { isShowingMetadata = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More options")
                } else {
                    Button { isShowingMetadata = true } label: {
                        Image(systemName: "info.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("PDF information")
                }
            }
        }
        .padding(.horizontal, isPhone ? 4 : 16)
        .frame(height: 58)
        .background(.black.opacity(0.001), in: Capsule())
        .tint(.white)
        .foregroundStyle(.white)
        .font(.title3.weight(.medium))
    }

    private func bookmarkControls(visibleLimit: Int) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(visibleBookmarks.prefix(visibleLimit)), id: \.index) { bookmark in
                BookmarkSlotButton(
                    title: "\(visibleBookmarkNumber(for: bookmark.index))",
                    accessibilityLabel: "Bookmark \(visibleBookmarkNumber(for: bookmark.index))",
                    isSet: true,
                    thumbnail: bookmarkThumbnail(for: bookmark.pageIndex),
                    size: CGSize(width: 44, height: 62),
                    goToBookmark: { goToBookmark(at: bookmark.index) },
                    storeBookmark: { storeBookmark(at: bookmark.index) },
                    removeBookmark: { removeBookmark(at: bookmark.index) },
                    preview: { image in
                        bookmarkPreview = image.map {
                            BookmarkPreview(image: $0, pageIndex: bookmark.pageIndex)
                        }
                    }
                )
                .frame(width: 44, height: 62)
            }
            if visibleBookmarks.count > visibleLimit {
                Menu {
                    ForEach(Array(visibleBookmarks.dropFirst(visibleLimit)), id: \.index) { bookmark in
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
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More bookmarks")
            }
            BookmarkSlotButton(
                title: "+",
                accessibilityLabel: "Add Bookmark",
                isSet: false,
                thumbnail: nil,
                size: CGSize(width: 40, height: 40),
                goToBookmark: { },
                storeBookmark: addBookmark,
                removeBookmark: nil,
                preview: { _ in
                    bookmarkPreview = nil
                }
            )
            .frame(width: 40, height: 40)
        }
        .padding(8)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .tint(.white)
        .foregroundStyle(.white)
        .font(.title3.weight(.medium))
    }

    private var documentMenu: some View {
        Button {
            isShowingDocumentSwitcher = true
        } label: {
            Text("§")
                .font(.system(size: 27, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
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
            Button {
                focusSearchControl()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start search")

            TextField("Find in PDF", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
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
            if isSearchActive {
                Button(action: dismissSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(.black.opacity(isSearchActive ? 0.58 : 0.001), in: Capsule())
        .tint(.white)
        .foregroundStyle(.white)
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            if let document = selectedDocument {
                Button {
                    guard document.canNavigateBack else { return }
                    navigateBack(in: document)
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Back")
                .buttonStyle(.plain)
                .foregroundStyle(!document.canNavigateBack ? Color(white: 0.58) : .white)
                Button {
                    guard document.canNavigateForward else { return }
                    navigateForward(in: document)
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Forward")
                .buttonStyle(.plain)
                .foregroundStyle(!document.canNavigateForward ? Color(white: 0.58) : .white)
            }
        }
        // OpenDocument is a reference type.  Recreate these controls when its
        // navigation history changes so their enabled state cannot lag behind
        // the first scrub action.
        .id(navigationRevision)
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
                isSearchFieldFocused = false
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

    #if DEBUG
    private func installUITestFixture() {
        documents.forEach { $0.stopAccessingFile() }
        documents = []
        selectedDocumentID = nil
        guard let url = UITestPDF.makeFixture() else {
            errorMessage = "Downdraft couldn’t create its test PDF."
            return
        }
        let document = OpenDocument(
            url: url,
            bookmarkData: Data(),
            displayName: "Downdraft UI Fixture",
            originalURLString: url.absoluteString,
            isTransient: true,
            isAccessingFile: false
        )
        documents = [document]
        selectDocument(document.id)
    }
    #endif

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

        guard document.loadFileIfNeeded() else {
            document.stopAccessingFile()
            errorMessage = "Downdraft couldn’t open this PDF."
            return
        }

        let contentMatchingDocuments = documents.filter {
            $0.matches(url)
                || (document.readingStateIdentity != nil
                    && $0.readingStateIdentity == document.readingStateIdentity)
        }
        if let existingDocument = contentMatchingDocuments.first {
            document.stopAccessingFile()
            for duplicate in contentMatchingDocuments.dropFirst() {
                close(duplicate.id)
            }
            selectDocument(existingDocument.id)
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
        selectedDocumentID = id
        loadingMessage = "Opening PDF…"
        document.loadFileIfNeeded(progress: { message in
            loadingMessage = message
        }) { didLoad in
            guard selectedDocumentID == id else { return }
            guard didLoad else {
                errorMessage = "The PDF is no longer available in Files."
                return
            }
            finishSelecting(document)
        }
    }

    private func finishSelecting(_ document: OpenDocument) {
        restoreSharedReadingState(for: document)
        document.lastSelectedAt = Date()
        treatsFirstPageAsCover = document.displaysAsBook
        readsHorizontally = document.readsHorizontally
        scrubbedPageIndex = document.lastPageIndex
        pdfKitCurrentPageIndex = document.lastPageIndex
        requestedPageIndex = nil
        requestedPageRequestID = nil
        bookmarkPageIndices = document.bookmarkPageIndices
        selectedPDFText = nil
        recordRecentDocument(document, rendersThumbnail: false)
        scheduleRecentThumbnail(for: document.id)
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

    private func presentSearch() {
        if searchSelectedTextIfAvailable() {
            return
        }

        if isSearchPresented {
            isSearchFieldFocused = false
            isSearchPresented = false
        } else {
            isSearchPresented = true
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
    }

    private func focusSearchControl() {
        if searchSelectedTextIfAvailable() {
            return
        }
        isSearchFieldFocused = true
    }

    private func searchSelectedTextIfAvailable() -> Bool {
        let selectedText = selectedPDFText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedText, !selectedText.isEmpty {
            searchText = selectedText
            isSearchPresented = true
            performSearch()
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
            return true
        }
        return false
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

    private func dismissSearch() {
        searchText = ""
        clearSearch()
        isSearchFieldFocused = false
        if isPhone {
            isSearchPresented = false
        }
    }

    private func setFirstPageCover(_ value: Bool) {
        treatsFirstPageAsCover = value
        selectedDocument?.displaysAsBook = value
        saveDocuments()
    }

    private func setReadingDirection(horizontal: Bool) {
        readsHorizontally = horizontal
        selectedDocument?.readsHorizontally = horizontal
        saveDocuments()
    }

    private func layoutMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func goToBookmark(at index: Int) {
        guard let document = selectedDocument,
              document.bookmarkPageIndices.indices.contains(index),
              let pageIndex = document.bookmarkPageIndices[index] else { return }
        navigate(to: pageIndex)
    }

    private func storeBookmark(at index: Int) -> Bool {
        guard let document = selectedDocument,
              document.bookmarkPageIndices.indices.contains(index) else { return false }
        guard !document.bookmarkPageIndices.enumerated().contains(where: {
            $0.offset != index && $0.element == document.lastPageIndex
        }) else { return false }
        document.bookmarkPageIndices[index] = document.lastPageIndex
        bookmarkPageIndices[index] = document.lastPageIndex
        persistBookmark(document.lastPageIndex, at: index, in: document)
        return true
    }

    private func addBookmark() -> Bool {
        guard let document = selectedDocument else { return false }
        let pageIndex = pdfKitCurrentPageIndex ?? document.lastPageIndex
        guard !document.bookmarkPageIndices.contains(pageIndex) else { return false }
        document.bookmarkPageIndices.append(pageIndex)
        bookmarkPageIndices = document.bookmarkPageIndices
        let index = document.bookmarkPageIndices.index(before: document.bookmarkPageIndices.endIndex)
        persistBookmark(pageIndex, at: index, in: document)
        return true
    }

    private func removeBookmark(at index: Int) {
        guard let document = selectedDocument,
              document.bookmarkPageIndices.indices.contains(index) else { return }
        document.bookmarkPageIndices[index] = nil
        bookmarkPageIndices = document.bookmarkPageIndices
        persistBookmark(nil, at: index, in: document)
    }

    private func persistBookmark(_ pageIndex: Int?, at index: Int, in document: OpenDocument) {
        if let identity = document.readingStateIdentity {
            ReadingStateStore.saveBookmark(
                pageIndex,
                at: index,
                for: identity,
                fallbackPageIndex: document.lastPageIndex,
                fallbackBookmarks: document.bookmarkPageIndices,
                fallbackPageModifiedAt: document.lastPageModifiedAt
            )
        }
        saveDocuments()
    }

    private func visibleBookmarkNumber(for index: Int) -> Int {
        (bookmarkPageIndices[..<index].compactMap { $0 }.count) + 1
    }

    private func bookmarkThumbnail(for pageIndex: Int) -> UIImage? {
        guard let document = selectedDocument?.pdfDocument else { return nil }
        return BookmarkThumbnailCache.image(for: document, pageIndex: pageIndex)
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
        document.lastPageModifiedAt = Date()
        if let identity = document.readingStateIdentity {
            ReadingStateStore.savePage(
                pageIndex,
                for: identity,
                fallbackBookmarks: document.bookmarkPageIndices
            )
        }
        RecentDocumentStore.updateReadingPosition(
            bookmarkData: document.bookmarkData,
            pageIndex: pageIndex,
            pageCount: document.pdfDocument?.pageCount
        )
        if id == selectedDocumentID {
            document.lastSelectedAt = Date()
            scrubbedPageIndex = pageIndex
            requestedPageIndex = nil
            requestedPageRequestID = nil
        }
        saveDocuments()
    }

    private func navigate(to pageIndex: Int) {
        guard let document = selectedDocument else { return }
        recordNavigation(in: document, from: document.lastPageIndex, to: pageIndex)
        // Move the scrubber at once; PDFKit's page-change notification can
        // arrive late, or not at all for a request to the already-visible page.
        scrubbedPageIndex = pageIndex
        scrubberRevision += 1
        requestPage(pageIndex)
    }

    private func requestPage(_ pageIndex: Int) {
        requestedPageIndex = pageIndex
        requestedPageRequestID = UUID()
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
        requestPage(pageIndex)
    }

    private func navigateForward(in document: OpenDocument) {
        guard let pageIndex = document.navigateForward(from: document.lastPageIndex) else { return }
        navigationRevision += 1
        scrubbedPageIndex = pageIndex
        scrubberRevision += 1
        requestPage(pageIndex)
    }

    private func saveDocuments() {
        OpenDocument.save(documents, selectedDocumentID: selectedDocumentID)
    }

    private func recordRecentDocument(_ document: OpenDocument, rendersThumbnail: Bool) {
        RecentDocumentStore.record(
            id: document.id,
            name: document.displayName,
            bookmarkData: document.bookmarkData,
            document: document.pdfDocument,
            lastPageIndex: document.lastPageIndex,
            pageCount: document.pdfDocument?.pageCount,
            thumbnailCacheIdentity: document.readingStateIdentity,
            rendersThumbnail: rendersThumbnail
        )
    }

    private func scheduleRecentThumbnail(for documentID: OpenDocument.ID) {
        // Rendering a PDF page is intentionally kept on the main thread for
        // PDFKit stability, but it is not launch-critical. Defer it until the
        // reader has had time to become visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard selectedDocumentID == documentID,
                  let document = documents.first(where: { $0.id == documentID }) else {
                return
            }
            recordRecentDocument(document, rendersThumbnail: true)
        }
    }

    private func restoreSharedReadingState(for document: OpenDocument) {
        guard let identity = document.readingStateIdentity else { return }
        let state = ReadingStateStore.state(
            for: identity,
            fallbackPageIndex: document.lastPageIndex,
            fallbackBookmarks: document.bookmarkPageIndices,
            fallbackPageModifiedAt: document.lastPageModifiedAt
        )
        document.lastPageIndex = state.page.index
        document.lastPageModifiedAt = state.page.modifiedAt
        document.bookmarkPageIndices = OpenDocument.deduplicatedBookmarks(state.bookmarks.map(\.pageIndex))
    }

    private func refreshSharedReadingState() {
        guard let document = selectedDocument,
              let identity = document.readingStateIdentity else { return }
        let previousPage = document.lastPageIndex
        let state = ReadingStateStore.state(
            for: identity,
            fallbackPageIndex: previousPage,
            fallbackBookmarks: document.bookmarkPageIndices,
            fallbackPageModifiedAt: document.lastPageModifiedAt
        )
        document.lastPageIndex = state.page.index
        document.lastPageModifiedAt = state.page.modifiedAt
        document.bookmarkPageIndices = OpenDocument.deduplicatedBookmarks(state.bookmarks.map(\.pageIndex))
        bookmarkPageIndices = document.bookmarkPageIndices
        if state.page.index != previousPage {
            scrubbedPageIndex = state.page.index
            scrubberRevision += 1
            requestPage(state.page.index)
            RecentDocumentStore.updateReadingPosition(
                bookmarkData: document.bookmarkData,
                pageIndex: state.page.index,
                pageCount: document.pdfDocument?.pageCount
            )
        }
        saveDocuments()
    }
}

private struct PageScrubber: View {
    let pageIndex: Int
    let pageCount: Int
    let chapterPositions: [Double]
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

            CircularPageSlider(
                value: Binding(
                    get: { Double(pendingPageIndex ?? pageIndex) },
                    set: { newValue in
                        // Some slider interactions deliver their first value
                        // before `onEditingChanged(true)`. Capture the origin
                        // here as well, before asking PDFKit to change pages.
                        if pageIndexWhenScrubbingBegan == nil {
                            pageIndexWhenScrubbingBegan = pageIndex
                        }
                        let newPageIndex = Int(newValue.rounded())
                        pendingPageIndex = newPageIndex
                        seek(newPageIndex)
                    }
                ),
                range: 0...Double(max(pageCount - 1, 0)),
                onEditingChanged: { isEditing in
                    if isEditing {
                        if pageIndexWhenScrubbingBegan == nil {
                            pageIndexWhenScrubbingBegan = pageIndex
                        }
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
            .overlay {
                ChapterMarkers(
                    positions: chapterPositions,
                    currentPosition: Double(pendingPageIndex ?? pageIndex) / Double(max(pageCount - 1, 1))
                )
                    .allowsHitTesting(false)
            }
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

/// A UIKit slider gives the reader a precise, consistently circular thumb.
/// It otherwise preserves the standard slider interaction model.
private struct CircularPageSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.isContinuous = true
        // The SwiftUI layer beneath draws the glass track, progress, and
        // chapter ticks. UIKit supplies only the dependable drag behaviour
        // and the circular thumb above it.
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.setThumbImage(Self.circularThumb, for: .normal)
        slider.setThumbImage(Self.circularThumb, for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.beganEditing), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finishedEditing), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        // A page can change because of a link, contents entry, history action,
        // or normal reading. Never fight a finger which is currently dragging.
        if !slider.isTracking {
            slider.value = Float(value)
        }
    }

    final class Coordinator: NSObject {
        var parent: CircularPageSlider

        init(_ parent: CircularPageSlider) {
            self.parent = parent
        }

        @MainActor @objc func beganEditing() {
            parent.onEditingChanged(true)
        }

        @MainActor @objc func valueChanged(_ slider: UISlider) {
            parent.value = Double(slider.value.rounded())
        }

        @MainActor @objc func finishedEditing() {
            parent.onEditingChanged(false)
        }
    }

    private static let circularThumb: UIImage = {
        let diameter: CGFloat = 20
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
        return renderer.image { _ in
            let bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            UIColor.white.setFill()
            UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
    }()
}

/// Fine vertical ticks indicate the starts of top-level outline entries.
/// They deliberately do not act as controls: dragging or tapping continues
/// to have the unsurprising, standard slider behaviour.
private struct ChapterMarkers: View {
    let positions: [Double]
    let currentPosition: Double

    var body: some View {
        GeometryReader { geometry in
            let thumbRadius: CGFloat = 10
            let trackWidth = max(0, geometry.size.width - thumbRadius * 2)
            let xPosition = { (position: Double) in
                thumbRadius + CGFloat(position) * trackWidth
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.78))
                    .frame(width: max(0, xPosition(currentPosition) - thumbRadius), height: 6)
                    .offset(x: thumbRadius)

                ForEach(Array(positions.enumerated()), id: \.offset) { _, position in
                    Rectangle()
                        // On the filled side of the track, a dark tick remains
                        // visible without competing with the progress itself.
                        .fill(position <= currentPosition ? .black.opacity(0.58) : .white.opacity(0.7))
                        .frame(width: 1, height: 12)
                        .position(x: xPosition(position), y: geometry.size.height / 2)
                }

                // This is a lens over the track, not its background: the
                // progress and chapter marks remain visibly within the glass.
                glassTrack
                    .frame(height: 18)
                    .padding(.horizontal, thumbRadius)
            }
        }
    }

    @ViewBuilder
    private var glassTrack: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.white.opacity(0.26))
        }
    }
}

@MainActor
private enum BookmarkThumbnailCache {
    private static let images = NSCache<NSString, UIImage>()

    static func image(for document: PDFDocument, pageIndex: Int) -> UIImage? {
        let key = "\(ObjectIdentifier(document))-\(pageIndex)" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let page = document.page(at: pageIndex) else { return nil }
        // Cards are tiny, but a long press expands one into a useful preview.
        // Keep enough source detail for that magnification to remain sharp.
        let image = page.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox)
        images.setObject(image, forKey: key)
        return image
    }
}

private struct BookmarkSlotButton: UIViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let isSet: Bool
    let thumbnail: UIImage?
    var size: CGSize = CGSize(width: 36, height: 36)
    let goToBookmark: () -> Void
    let storeBookmark: () -> Bool
    let removeBookmark: (() -> Void)?
    let preview: (UIImage?) -> Void

    func makeUIView(context: Context) -> BookmarkSlotControl {
        BookmarkSlotControl(size: size)
    }

    func updateUIView(_ control: BookmarkSlotControl, context: Context) {
        control.configure(
            title: title,
            accessibilityLabel: accessibilityLabel,
            isSet: isSet,
            thumbnail: thumbnail,
            goToBookmark: goToBookmark,
            storeBookmark: storeBookmark,
            removeBookmark: removeBookmark,
            preview: preview
        )
    }
}

private final class BookmarkSlotControl: UIControl {
    private let label = UILabel()
    private let thumbnailView = UIImageView()
    private let holdProgressLayer = CAShapeLayer()
    private var goToBookmark: () -> Void = { }
    private var storeBookmark: () -> Bool = { false }
    private var removeBookmark: (() -> Void)?
    private var preview: (UIImage?) -> Void = { _ in }
    private var didStoreDuringTouch = false
    private var didRemoveDuringTouch = false
    private var isAddControl = false
    private var isThumbnailControl = false
    private var mutedColor = UIColor.clear
    private let size: CGSize

    override var intrinsicContentSize: CGSize {
        size
    }

    init(size: CGSize) {
        self.size = size
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        isEnabled = true
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.isUserInteractionEnabled = false
        thumbnailView.alpha = 0.94
        holdProgressLayer.fillColor = UIColor.clear.cgColor
        holdProgressLayer.lineWidth = 2.5
        holdProgressLayer.lineCap = .round
        holdProgressLayer.strokeEnd = 0
        holdProgressLayer.opacity = 0
        layer.addSublayer(holdProgressLayer)
        addSubview(thumbnailView)
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
        label.frame = bounds.offsetBy(
            dx: isAddControl ? 1 : 0,
            dy: isAddControl ? -1 : 0
        )
        let cornerRadius = isThumbnailControl ? 6 : bounds.height / 2
        layer.cornerRadius = cornerRadius
        thumbnailView.frame = bounds.insetBy(dx: 2, dy: 2)
        thumbnailView.layer.cornerRadius = isThumbnailControl ? 4 : thumbnailView.bounds.height / 2
        holdProgressLayer.frame = bounds
        let progressBounds = bounds.insetBy(dx: 3, dy: 3)
        holdProgressLayer.path = UIBezierPath(
            roundedRect: progressBounds,
            cornerRadius: isThumbnailControl ? 4 : progressBounds.height / 2
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
        thumbnail: UIImage?,
        goToBookmark: @escaping () -> Void,
        storeBookmark: @escaping () -> Bool,
        removeBookmark: (() -> Void)?,
        preview: @escaping (UIImage?) -> Void
    ) {
        self.goToBookmark = goToBookmark
        self.storeBookmark = storeBookmark
        self.removeBookmark = removeBookmark
        self.preview = preview
        label.text = title
        thumbnailView.image = thumbnail
        thumbnailView.isHidden = thumbnail == nil
        label.isHidden = thumbnail != nil
        isAddControl = title == "+"
        isThumbnailControl = isSet
        label.font = isAddControl
            ? .systemFont(ofSize: 24, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        let bookmarkBlue = UIColor.systemBlue
        holdProgressLayer.strokeColor = bookmarkBlue.cgColor
        mutedColor = isSet ? bookmarkBlue.withAlphaComponent(0.38) : .clear
        layer.borderWidth = isAddControl ? 1.5 : 0
        layer.borderColor = isAddControl ? UIColor.white.withAlphaComponent(0.78).cgColor : nil
        if !isHighlighted {
            backgroundColor = mutedColor
        }
        setNeedsLayout()
        self.accessibilityLabel = accessibilityLabel
        accessibilityHint = isSet
            ? "Double tap to go to its saved page. Press and hold to enlarge its preview. Drag left to remove it."
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
            self.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.62)
            if self.isAddControl {
                self.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
            }
        }
    }

    @objc private func pressCancelled() {
        releaseTension()
    }

    private func releaseTension(recorded: Bool = false) {
        preview(nil)
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
        layer.zPosition = 0
    }

    @objc private func tapped() {
        defer {
            didStoreDuringTouch = false
            didRemoveDuringTouch = false
        }
        guard !didStoreDuringTouch, !didRemoveDuringTouch else {
            if didStoreDuringTouch, !isAddControl {
                releaseTension()
            }
            return
        }
        releaseTension()
        goToBookmark()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        didStoreDuringTouch = true
        guard !isAddControl else {
            releaseTension(recorded: storeBookmark())
            return
        }

        // The enlarged card is hosted above the reader, rather than in the
        // rail, so its preview cannot be constrained by that small control.
        holdProgressLayer.removeAllAnimations()
        holdProgressLayer.opacity = 0
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.backgroundColor = self.mutedColor
            self.transform = .identity
        }
        preview(thumbnailView.image)
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
    let fileLocation: String
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
                    LabeledContent("File") {
                        Text(filename)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Location") {
                        Text(fileLocation)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
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

final class OpenDocument: Identifiable, @unchecked Sendable {
    let id = UUID()
    private(set) var url: URL?
    private(set) var pdfDocument: PDFDocument?
    private(set) var readingStateIdentity: String?
    let bookmarkData: Data
    let displayName: String
    let originalURLString: String
    var lastPageIndex: Int
    var displaysAsBook: Bool
    var readsHorizontally: Bool
    var bookmarkPageIndices: [Int?]
    var lastSelectedAt: Date
    var lastPageModifiedAt: Date
    /// Test-only documents are temporary files and must never become part of
    /// the normal restore list.
    let isTransient: Bool
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

    var fullFileName: String {
        if let url {
            return url.lastPathComponent
        }
        if let originalURL = URL(string: originalURLString), !originalURL.lastPathComponent.isEmpty {
            return originalURL.lastPathComponent
        }
        return displayName.hasSuffix(".pdf") ? displayName : "\(displayName).pdf"
    }

    var fullFileLocation: String {
        if let url {
            return url.path
        }
        if let originalURL = URL(string: originalURLString), !originalURL.path.isEmpty {
            return originalURL.path
        }
        return originalURLString
    }

    init(
        url: URL?,
        bookmarkData: Data,
        displayName: String,
        originalURLString: String,
        readingStateIdentity: String? = nil,
        lastPageIndex: Int = 0,
        displaysAsBook: Bool = true,
        readsHorizontally: Bool = false,
        bookmarkPageIndices: [Int?] = [],
        lastSelectedAt: Date = .distantPast,
        lastPageModifiedAt: Date = .distantPast,
        isTransient: Bool = false,
        isAccessingFile: Bool
    ) {
        self.url = url
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.originalURLString = originalURLString
        self.readingStateIdentity = readingStateIdentity
        self.lastPageIndex = lastPageIndex
        self.displaysAsBook = displaysAsBook
        self.readsHorizontally = readsHorizontally
        self.bookmarkPageIndices = Self.deduplicatedBookmarks(bookmarkPageIndices)
        self.lastSelectedAt = lastSelectedAt
        self.lastPageModifiedAt = lastPageModifiedAt
        self.isTransient = isTransient
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

    static func deduplicatedBookmarks(_ bookmarks: [Int?]) -> [Int?] {
        var seenPages = Set<Int>()
        return bookmarks.map { pageIndex in
            guard let pageIndex, seenPages.insert(pageIndex).inserted else { return nil }
            return pageIndex
        }
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

    /// Restoring a security-scoped, cloud-backed PDF can wait on its file
    /// provider for many seconds. Keep that wait off the reader's main thread
    /// so launch can show progress and remain interruptible.
    @MainActor
    func loadFileIfNeeded(
        progress: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        if pdfDocument != nil {
            completion(true)
            return
        }

        let existingURL = url
        let bookmarkData = bookmarkData
        let alreadyAccessingFile = isAccessingFile
        let existingIdentity = readingStateIdentity

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async {
                progress(existingURL == nil ? "Restoring PDF access…" : "Opening PDF…")
            }
            var resolvedURL = existingURL
            var startedAccessingFile = false

            if resolvedURL == nil {
                var isStale = false
                resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }

            guard let resolvedURL else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            if !alreadyAccessingFile {
                startedAccessingFile = resolvedURL.startAccessingSecurityScopedResource()
            }
            DispatchQueue.main.async {
                progress("Opening PDF…")
            }
            let loadedDocument = PDFDocument(url: resolvedURL)
            DispatchQueue.main.async {
                progress("Preparing reading state…")
            }
            let identity = existingIdentity ?? loadedDocument.flatMap {
                ReadingStateStore.identity(for: resolvedURL, document: $0)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, let loadedDocument else {
                    if startedAccessingFile {
                        resolvedURL.stopAccessingSecurityScopedResource()
                    }
                    completion(false)
                    return
                }
                self.url = resolvedURL
                self.isAccessingFile = alreadyAccessingFile || startedAccessingFile
                self.pdfDocument = loadedDocument
                self.readingStateIdentity = identity
                completion(true)
            }
        }
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
        let readingStateIdentity: String?
        let lastPageIndex: Int
        let displaysAsBook: Bool?
        let readsHorizontally: Bool?
        let bookmarkPageIndices: [Int?]?
        let lastSelectedAt: Date?
        let lastPageModifiedAt: Date?
    }

    private static let savedDocumentsKey = "openDocuments"
    private static let selectedDocumentKey = "selectedDocumentIdentity"

    static func save(_ documents: [OpenDocument], selectedDocumentID: OpenDocument.ID?) {
        let persistentDocuments = documents.filter { !$0.isTransient }
        let savedDocuments = persistentDocuments.map {
            SavedDocument(
                bookmarkData: $0.bookmarkData,
                displayName: $0.displayName,
                originalURLString: $0.originalURLString,
                readingStateIdentity: $0.readingStateIdentity,
                lastPageIndex: $0.lastPageIndex,
                displaysAsBook: $0.displaysAsBook,
                readsHorizontally: $0.readsHorizontally,
                bookmarkPageIndices: $0.bookmarkPageIndices,
                lastSelectedAt: $0.lastSelectedAt,
                lastPageModifiedAt: $0.lastPageModifiedAt
            )
        }
        guard let data = try? JSONEncoder().encode(savedDocuments) else { return }
        UserDefaults.standard.set(data, forKey: savedDocumentsKey)
        if let selectedDocument = persistentDocuments.first(where: { $0.id == selectedDocumentID }) {
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

        let restorableDocuments = savedDocuments.filter { !isLegacyUITestFixture($0) }
        if restorableDocuments.count != savedDocuments.count {
            if let data = try? JSONEncoder().encode(restorableDocuments) {
                UserDefaults.standard.set(data, forKey: savedDocumentsKey)
            }
            let removedIdentities = Set(savedDocuments
                .filter(isLegacyUITestFixture)
                .map { $0.originalURLString ?? "" })
            if let selectedIdentity = UserDefaults.standard.string(forKey: selectedDocumentKey),
               removedIdentities.contains(selectedIdentity) {
                UserDefaults.standard.removeObject(forKey: selectedDocumentKey)
            }
        }

        return restorableDocuments.map { savedDocument in
            OpenDocument(
                url: nil,
                bookmarkData: savedDocument.bookmarkData,
                displayName: savedDocument.displayName,
                originalURLString: savedDocument.originalURLString ?? "",
                readingStateIdentity: savedDocument.readingStateIdentity,
                lastPageIndex: savedDocument.lastPageIndex,
                displaysAsBook: savedDocument.displaysAsBook ?? true,
                readsHorizontally: savedDocument.readsHorizontally ?? false,
                bookmarkPageIndices: savedDocument.bookmarkPageIndices ?? [],
                lastSelectedAt: savedDocument.lastSelectedAt ?? .distantPast,
                lastPageModifiedAt: savedDocument.lastPageModifiedAt ?? savedDocument.lastSelectedAt ?? .distantPast,
                isAccessingFile: false
            )
        }
    }

    private static func isLegacyUITestFixture(_ document: SavedDocument) -> Bool {
        document.displayName == "Downdraft UI Fixture" && document.bookmarkData.isEmpty
    }
}

private struct DocumentSwitcherView: View {
    let documents: [OpenDocument]
    let selectedID: OpenDocument.ID?
    let select: (OpenDocument.ID) -> Void
    let openPDF: () -> Void
    let close: (OpenDocument.ID) -> Void
    @Environment(\.dismiss) private var dismiss

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

    private var documentsByRecency: [OpenDocument] {
        documents.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.lastSelectedAt != rhs.element.lastSelectedAt {
                    return lhs.element.lastSelectedAt > rhs.element.lastSelectedAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
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
                ForEach(documentsByRecency) { document in
                    let isSelected = document.id == selectedID
                    HStack(spacing: 12) {
                        Button {
                            select(document.id)
                        } label: {
                            HStack(spacing: 12) {
                                DocumentThumbnail(data: thumbnailData(for: document))
                                Text(document.displayName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .accessibilityLabel("Current document")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

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
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
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

#Preview {
    ContentView()
}
