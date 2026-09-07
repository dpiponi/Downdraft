import PDFKit
import SwiftUI

struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    var initialPageIndex = 0
    var isReaderFocused = false
    var isLandscape = false
    var displaysAsBook = true
    var searchSelection: PDFSelection?
    var outlineDestination: PDFDestination?
    var requestedPageIndex: Int?
    var onPageChanged: (Int) -> Void = { _ in }
    var onCenterTap: () -> Void = { }
    var onLinkNavigation: (Int, Int) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        context.coordinator.startObservingPageChanges(in: view)
        context.coordinator.startObservingReaderTaps(in: view)
        context.coordinator.startObservingSearchHighlightDismissal(in: view)
        return view
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.onLinkNavigation = onLinkNavigation
        context.coordinator.disableDoubleTapZoom(in: pdfView)
        context.coordinator.disablePDFKitSingleTaps(in: pdfView)
        if context.coordinator.loadedDocument !== document {
            context.coordinator.install(
                document,
                at: initialPageIndex,
                in: pdfView
            )
        }
        context.coordinator.clearPDFKitSearchHighlights(in: pdfView)
        context.coordinator.updateSearchSelection(searchSelection, in: pdfView)
        context.coordinator.updateOutlineDestination(outlineDestination, in: pdfView)
        context.coordinator.updateRequestedPage(requestedPageIndex, in: pdfView)
        context.coordinator.updatePageLayout(
            isLandscape: isLandscape,
            displaysAsBook: displaysAsBook,
            in: pdfView
        )
        context.coordinator.updateReaderFocus(isReaderFocused)
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
        private var isLandscape = false
        private var displaysAsBook = false
        private var displayedSearchSelection: PDFSelection?
        private var pendingSearchSelection: PDFSelection?
        private var pendingSearchHighlight: PDFSelection?
        private var displayedOutlineDestination: PDFDestination?
        private var displayedRequestedPageIndex: Int?
        private weak var readerTapGesture: UITapGestureRecognizer?
        private weak var searchHighlightOverlay: SearchMatchOverlayView?
        private var observedMotionRecognizers = Set<ObjectIdentifier>()
        private var protectedPageIndex: Int?
        private var ignoresTransientPageChanges = false
        var lastKnownPageIndex = 0

        func install(_ document: PDFDocument, at pageIndex: Int, in pdfView: PDFView) {
            // Assigning a PDFDocument always makes PDFKit briefly announce its
            // first page, even when we immediately go to a saved page.  That
            // announcement is setup noise, not reader navigation.
            ignoresTransientPageChanges = true
            lastKnownPageIndex = pageIndex
            pdfView.document = document
            if let page = document.page(at: pageIndex) {
                pdfView.go(to: page)
            } else {
                pdfView.goToFirstPage(nil)
            }
            loadedDocument = document
            DispatchQueue.main.async { [weak self] in
                self?.ignoresTransientPageChanges = false
                self?.startObservingSearchHighlightDismissal(in: pdfView)
            }
        }
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

        func startObservingSearchHighlightDismissal(in pdfView: PDFView) {
            let recognizers = scrollViews(in: pdfView).map(\.panGestureRecognizer)
                + (pdfView.gestureRecognizers ?? []).compactMap { $0 as? UIPinchGestureRecognizer }
            for recognizer in recognizers where observedMotionRecognizers.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.addTarget(self, action: #selector(readerMotionBegan(_:)))
            }
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

        private func scrollViews(in view: UIView) -> [UIScrollView] {
            let local = view.subviews.compactMap { $0 as? UIScrollView }
            return local + view.subviews.flatMap(scrollViews(in:))
        }

        func updateReaderFocus(_ isFocused: Bool) {
            isReaderFocused = isFocused
            // Reader chrome is now a sibling overlay, so this state must not
            // cause a PDFKit resize or a compensating navigation.
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
            pendingSearchSelection = selection
            pendingSearchHighlight = selection
            if selection == nil {
                hideSearchHighlight()
            }
            guard let selection, let page = selection.pages.first else { return }

            // PDFKit's `go(to: PDFSelection)` can throw an Objective-C
            // exception while its highlighted-search layers are present.  A
            // normal page jump is stable and still takes the reader directly
            // to the page containing the selected match.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self,
                      let pdfView,
                      self.pendingSearchSelection === selection else { return }
                self.pendingSearchSelection = nil
                pdfView.go(to: page)
                self.showPendingSearchHighlightIfReady(in: pdfView)
            }
        }

        func clearPDFKitSearchHighlights(in pdfView: PDFView) {
            // On iPadOS 26, PDFKit can abort inside its private
            // `addSearchSelection` layer renderer (including while merely
            // changing pages).  Keep search navigation, but do not ask that
            // renderer to draw match highlights.
            if !(pdfView.highlightedSelections?.isEmpty ?? true) {
                pdfView.highlightedSelections = []
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
            hideSearchHighlight()

            // PDFKit reports page zero while it is rebuilding its private
            // scroll view for an otherwise non-navigational resize.  Keep the
            // reading position authoritative until that rebuild is complete.
            if ignoresTransientPageChanges {
                return
            }

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
            showPendingSearchHighlightIfReady(in: pdfView)
        }

        @objc private func readerTapped(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView = recognizer.view as? PDFView else { return }
            let location = recognizer.location(in: pdfView)
            pendingSearchHighlight = nil
            hideSearchHighlight()
            if pdfView.currentSelection != nil {
                pdfView.currentSelection = nil
                return
            }
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

        @objc private func readerMotionBegan(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            pendingSearchHighlight = nil
            hideSearchHighlight()
        }

        private func showPendingSearchHighlightIfReady(in pdfView: PDFView) {
            guard let selection = pendingSearchHighlight,
                  let targetPage = selection.pages.first,
                  pdfView.currentPage === targetPage else { return }
            pendingSearchHighlight = nil
            // PDFKit installs the page view at the end of its page-change
            // transaction.  Wait one run-loop turn before converting bounds.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      self.displayedSearchSelection === selection else { return }
                self.showSearchHighlight(for: selection, in: pdfView)
            }
        }

        private func showSearchHighlight(for selection: PDFSelection, in pdfView: PDFView) {
            guard let page = selection.pages.first else { return }
            let selectionBounds = selection.bounds(for: page)
            let rect = pdfView.convert(selectionBounds, from: page).insetBy(dx: -3, dy: -2)
            guard !rect.isNull, !rect.isEmpty else { return }

            hideSearchHighlight()
            let overlay = SearchMatchOverlayView(frame: pdfView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.show(rect: rect)
            pdfView.addSubview(overlay)
            searchHighlightOverlay = overlay
        }

        private func hideSearchHighlight() {
            searchHighlightOverlay?.removeFromSuperview()
            searchHighlightOverlay = nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

    }
}

private final class SearchMatchOverlayView: UIView {
    private let outlineLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        outlineLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.28).cgColor
        outlineLayer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.95).cgColor
        outlineLayer.lineWidth = 2
        layer.addSublayer(outlineLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:)")
    }

    func show(rect: CGRect) {
        outlineLayer.path = UIBezierPath(
            roundedRect: rect,
            cornerRadius: 4
        ).cgPath
    }
}

extension PDFDocumentView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer
    }
}
