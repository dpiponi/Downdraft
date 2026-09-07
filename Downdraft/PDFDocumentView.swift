import PDFKit
import SwiftUI

struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    var initialPageIndex = 0
    var isActive = false
    var isReaderFocused = false
    var isLandscape = false
    var displaysAsBook = true
    var searchSelection: PDFSelection?
    var searchSelections: [PDFSelection] = []
    var outlineDestination: PDFDestination?
    var requestedPageIndex: Int?
    var onPageChanged: (Int) -> Void = { _ in }
    var onCenterTap: () -> Void = { }
    var onLinkNavigation: (Int, Int) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PDFView {
        let view = PagePreservingPDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        context.coordinator.startObservingPageChanges(in: view)
        context.coordinator.startObservingReaderTaps(in: view)
        return view
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.onLinkNavigation = onLinkNavigation
        context.coordinator.disableDoubleTapZoom(in: pdfView)
        context.coordinator.disablePDFKitSingleTaps(in: pdfView)
        if context.coordinator.loadedDocument !== document {
            pdfView.document = document
            if let page = pdfView.document?.page(at: initialPageIndex) {
                pdfView.go(to: page)
            } else {
                pdfView.goToFirstPage(nil)
            }
            context.coordinator.loadedDocument = document
            context.coordinator.lastKnownPageIndex = initialPageIndex
        }
        pdfView.highlightedSelections = searchSelections
        context.coordinator.updateSearchSelection(searchSelection, in: pdfView)
        context.coordinator.updateOutlineDestination(outlineDestination, in: pdfView)
        context.coordinator.updateRequestedPage(requestedPageIndex, in: pdfView)
        context.coordinator.updatePageLayout(
            isLandscape: isLandscape,
            displaysAsBook: displaysAsBook,
            in: pdfView
        )
        context.coordinator.updateReaderFocus(
            isReaderFocused,
            isActive: isActive,
            in: pdfView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject {
        var loadedDocument: PDFDocument?
        var onPageChanged: (Int) -> Void = { _ in }
        var onCenterTap: () -> Void = { }
        var onLinkNavigation: (Int, Int) -> Void = { _, _ in }
        private var isReaderFocused = false
        private var appliedReaderFocus: Bool?
        private var isLandscape = false
        private var displaysAsBook = false
        private var displayedSearchSelection: PDFSelection?
        private var displayedOutlineDestination: PDFDestination?
        private var displayedRequestedPageIndex: Int?
        private weak var readerTapGesture: UITapGestureRecognizer?
        private var protectedPageIndex: Int?
        var lastKnownPageIndex = 0
        func startObservingPageChanges(in pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        func startObservingReaderTaps(in pdfView: PDFView) {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(readerTapped(_:)))
            tapGesture.cancelsTouchesInView = true
            tapGesture.delegate = self
            pdfView.addGestureRecognizer(tapGesture)
            readerTapGesture = tapGesture
        }

        func disableDoubleTapZoom(in pdfView: PDFView) {
            for recognizer in tapGestures(in: pdfView)
            where recognizer.numberOfTapsRequired > 1 {
                recognizer.isEnabled = false
            }
        }

        func disablePDFKitSingleTaps(in pdfView: PDFView) {
            for recognizer in tapGestures(in: pdfView)
            where recognizer !== readerTapGesture && recognizer.numberOfTapsRequired == 1 {
                recognizer.isEnabled = false
            }
        }

        private func tapGestures(in view: UIView) -> [UITapGestureRecognizer] {
            let local = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            return local + view.subviews.flatMap(tapGestures(in:))
        }

        func updateReaderFocus(_ isFocused: Bool, isActive: Bool, in pdfView: PDFView) {
            isReaderFocused = isFocused
            guard isActive, appliedReaderFocus != isFocused else { return }
            appliedReaderFocus = isFocused
            (pdfView as? PagePreservingPDFView)?.preserveScrollPositionOnNextResize()
        }

        func updatePageLayout(isLandscape: Bool, displaysAsBook: Bool, in pdfView: PDFView) {
            guard self.isLandscape != isLandscape || self.displaysAsBook != displaysAsBook else { return }
            self.isLandscape = isLandscape
            self.displaysAsBook = displaysAsBook
            let pageIndex = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
                ?? lastKnownPageIndex
            UIView.performWithoutAnimation {
                pdfView.displaysAsBook = displaysAsBook
                pdfView.displayMode = isLandscape ? .twoUpContinuous : .singlePageContinuous
                pdfView.layoutIfNeeded()
            }
            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView,
                      let page = pdfView.document?.page(at: pageIndex) else { return }
                pdfView.layoutIfNeeded()
                if self.isReaderFocused {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
                } else {
                    pdfView.autoScales = true
                }
                pdfView.go(to: page)
            }
        }

        func updateSearchSelection(_ selection: PDFSelection?, in pdfView: PDFView) {
            guard displayedSearchSelection !== selection else { return }
            displayedSearchSelection = selection
            pdfView.currentSelection = selection
            if let selection {
                pdfView.go(to: selection)
            }
        }

        func updateOutlineDestination(_ destination: PDFDestination?, in pdfView: PDFView) {
            guard displayedOutlineDestination !== destination else { return }
            displayedOutlineDestination = destination
            if let destination {
                pdfView.go(to: destination)
            }
        }

        func updateRequestedPage(_ pageIndex: Int?, in pdfView: PDFView) {
            guard let pageIndex else {
                displayedRequestedPageIndex = nil
                return
            }
            guard displayedRequestedPageIndex != pageIndex,
                  let page = pdfView.document?.page(at: pageIndex) else { return }
            displayedRequestedPageIndex = pageIndex
            pdfView.go(to: page)
        }

        @MainActor @objc private func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let pageIndex = document.index(for: page)

            if let protectedPageIndex,
               pageIndex != protectedPageIndex,
               let protectedPage = document.page(at: protectedPageIndex) {
                // A chrome toggle must not become a navigation action. PDFKit
                // occasionally resets its rebuilt scroll view to page zero;
                // reject that synthetic page-change before publishing it.
                pdfView.go(to: PDFDestination(
                    page: protectedPage,
                    at: protectedPage.bounds(for: .mediaBox).origin
                ))
                return
            }
            lastKnownPageIndex = pageIndex
            onPageChanged(pageIndex)
        }

        @objc private func readerTapped(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView = recognizer.view as? PDFView else { return }
            let location = recognizer.location(in: pdfView)
            guard let page = pdfView.page(for: location, nearest: false) else {
                onCenterTap()
                return
            }
            let pointOnPage = pdfView.convert(location, to: page)
            guard let annotation = page.annotation(at: pointOnPage),
                  annotation.type?.lowercased() == "link" else {
                if let document = pdfView.document {
                    protectedPageIndex = document.index(for: page)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.protectedPageIndex = nil
                    }
                }
                onCenterTap()
                return
            }

            if let destination = annotation.destination,
               let destinationPage = destination.page,
               let document = pdfView.document {
                onLinkNavigation(document.index(for: page), document.index(for: destinationPage))
                pdfView.go(to: destination)
            } else if let url = annotation.url {
                UIApplication.shared.open(url)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

extension PDFDocumentView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer
    }
}

private final class PagePreservingPDFView: PDFView {
    private var previousBoundsSize = CGSize.zero
    private var shouldPreserveScrollPosition = false

    func preserveScrollPositionOnNextResize() {
        shouldPreserveScrollPosition = true
    }

    override func layoutSubviews() {
        let sizeChanged = previousBoundsSize != .zero && bounds.size != previousBoundsSize
        let offsets = shouldPreserveScrollPosition && sizeChanged
            ? scrollViews(in: self).map { ($0, $0.contentOffset) }
            : []
        super.layoutSubviews()
        disableScrollToTop(in: self)
        previousBoundsSize = bounds.size

        guard shouldPreserveScrollPosition, sizeChanged else { return }
        shouldPreserveScrollPosition = false
        DispatchQueue.main.async {
            for (scrollView, offset) in offsets {
                scrollView.setContentOffset(offset, animated: false)
            }
        }
    }

    private func disableScrollToTop(in view: UIView) {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                scrollView.scrollsToTop = false
            }
            disableScrollToTop(in: subview)
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let localScrollViews = view.subviews.compactMap { $0 as? UIScrollView }
        return localScrollViews + view.subviews.flatMap(scrollViews(in:))
    }
}
