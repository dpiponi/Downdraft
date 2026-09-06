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

    func makeUIView(context: Context) -> PDFView {
        let view = PagePreservingPDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        context.coordinator.startObservingPageChanges(in: view)
        context.coordinator.startObservingCenterTaps(in: view)
        return view
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.prioritizeCenterTap(in: pdfView)
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
        private var isReaderFocused = false
        private var appliedReaderFocus: Bool?
        private var isLandscape = false
        private var displaysAsBook = false
        private var displayedSearchSelection: PDFSelection?
        private var displayedOutlineDestination: PDFDestination?
        private var displayedRequestedPageIndex: Int?
        private weak var centerTapGesture: UITapGestureRecognizer?
        var lastKnownPageIndex = 0
        func startObservingPageChanges(in pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        func startObservingCenterTaps(in pdfView: PDFView) {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(centerTapped))
            tapGesture.cancelsTouchesInView = true
            tapGesture.delaysTouchesEnded = true
            tapGesture.delegate = self
            pdfView.addGestureRecognizer(tapGesture)
            centerTapGesture = tapGesture

            // PDFKit finishes creating some of its private page views on a
            // later run-loop turn.  Apply the failure relationship again
            // once those recognisers exist; otherwise its page-turn tap can
            // still receive the same touch as our reader-chrome tap.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                self.prioritizeCenterTap(in: pdfView)
            }
        }

        func prioritizeCenterTap(in pdfView: PDFView) {
            guard let centerTapGesture else { return }
            for recognizer in tapGestures(in: pdfView) where recognizer !== centerTapGesture {
                recognizer.require(toFail: centerTapGesture)
            }
        }

        private func tapGestures(in view: UIView) -> [UITapGestureRecognizer] {
            let localGestures = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            return localGestures + view.subviews.flatMap(tapGestures(in:))
        }

        func updateReaderFocus(_ isFocused: Bool, isActive: Bool, in pdfView: PDFView) {
            isReaderFocused = isFocused
            guard isActive, appliedReaderFocus != isFocused else { return }
            appliedReaderFocus = isFocused
            // PDFKit may temporarily report the next page as `currentPage`
            // while its continuous scroll view is settling.  The page-change
            // notification is the stable reading-position record.
            let pageIndex = lastKnownPageIndex

            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView,
                      let page = pdfView.document?.page(at: pageIndex) else { return }
                pdfView.layoutIfNeeded()
                if isFocused {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
                } else {
                    pdfView.autoScales = true
                }
                pdfView.go(to: PDFDestination(
                    page: page,
                    at: page.bounds(for: .mediaBox).origin
                ))
            }
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

        @objc private func centerTapped() {
            onCenterTap()
        }


        @MainActor @objc private func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let pageIndex = document.index(for: page)
            lastKnownPageIndex = pageIndex
            onPageChanged(pageIndex)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class PagePreservingPDFView: PDFView {
    private var previousBoundsSize = CGSize.zero

    override func layoutSubviews() {
        let pageBeforeLayout = currentPage
        let sizeChanged = previousBoundsSize != .zero && bounds.size != previousBoundsSize
        super.layoutSubviews()
        disableScrollToTop(in: self)
        previousBoundsSize = bounds.size

        // PDFKit can reset its scroll position while auto-scaling after an
        // unrelated SwiftUI layout change (for example, search focus). Keep
        // the page that was visible before the size change.
        guard sizeChanged, let pageBeforeLayout else { return }
        DispatchQueue.main.async { [weak self, weak pageBeforeLayout] in
            guard let self, let pageBeforeLayout else { return }
            // `currentPage` can remain correct while PDFKit's internal
            // scroll view jumps to its origin.  A page-only `go(to:)` is
            // then optimised away, so restore an explicit destination.
            let destination = PDFDestination(
                page: pageBeforeLayout,
                at: pageBeforeLayout.bounds(for: .mediaBox).origin
            )
            self.go(to: destination)
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
}

extension PDFDocumentView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tapGesture = gestureRecognizer as? UITapGestureRecognizer,
              let pdfView = tapGesture.view as? PDFView else { return false }
        let location = tapGesture.location(in: pdfView)
        let edgeZoneHeight = pdfView.bounds.height * 0.25
        guard location.y <= edgeZoneHeight
                || location.y >= pdfView.bounds.height - edgeZoneHeight else {
            return false
        }

        // PDFKit's link activation is itself tap-based.  Do not let our
        // chrome gesture recognize alongside a link, since revealing or
        // hiding the UI changes the PDF view's size before PDFKit resolves
        // the link destination.
        guard let page = pdfView.page(for: location, nearest: false) else { return false }
        let pointOnPage = pdfView.convert(location, to: page)
        return page.annotation(at: pointOnPage)?.type?.lowercased() != "link"
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
