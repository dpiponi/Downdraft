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
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(readerTapped))
            tapGesture.cancelsTouchesInView = true
            tapGesture.delegate = self
            pdfView.addGestureRecognizer(tapGesture)
        }

        func disableDoubleTapZoom(in pdfView: PDFView) {
            for recognizer in tapGestures(in: pdfView)
            where recognizer.numberOfTapsRequired > 1 {
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
            lastKnownPageIndex = pageIndex
            onPageChanged(pageIndex)
        }

        @objc private func readerTapped() {
            onCenterTap()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

extension PDFDocumentView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tapGesture = gestureRecognizer as? UITapGestureRecognizer,
              let pdfView = tapGesture.view as? PDFView else { return false }

        // Let PDFKit handle an annotation link normally; every other
        // stationary single tap is a reader-chrome toggle.
        let location = tapGesture.location(in: pdfView)
        guard let page = pdfView.page(for: location, nearest: false) else { return true }
        let pointOnPage = pdfView.convert(location, to: page)
        guard let annotation = page.annotation(at: pointOnPage),
              annotation.type?.lowercased() == "link" else {
            return true
        }

        if let destinationPage = annotation.destination?.page,
           let document = pdfView.document {
            onLinkNavigation(document.index(for: page), document.index(for: destinationPage))
        }
        return false
    }
}

private final class PagePreservingPDFView: PDFView {
    override func layoutSubviews() {
        super.layoutSubviews()
        disableScrollToTop(in: self)
    }

    private func disableScrollToTop(in view: UIView) {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView {
                scrollView.scrollsToTop = false
            }
            disableScrollToTop(in: subview)
        }
    }
}
