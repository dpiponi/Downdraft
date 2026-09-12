import PDFKit
import SwiftUI
import UIKit

struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    var initialPageIndex = 0
    var isReaderFocused = false
    var isLandscape = false
    var displaysAsBook = true
    var readsHorizontally = false
    var searchSelection: PDFSelection?
    var outlineDestination: PDFDestination?
    var requestedPageIndex: Int?
    var onPageChanged: (Int) -> Void = { _ in }
    var onPDFKitCurrentPageChanged: (Int) -> Void = { _ in }
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
        context.coordinator.onPDFKitCurrentPageChanged = onPDFKitCurrentPageChanged
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
            readsHorizontally: readsHorizontally,
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
        var onPDFKitCurrentPageChanged: (Int) -> Void = { _ in }
        var onCenterTap: () -> Void = { }
        var onLinkNavigation: (Int, Int) -> Void = { _, _ in }
        private var isReaderFocused = false
        private var isLandscape = false
        private var displaysAsBook = false
        private var readsHorizontally = false
        private var displayedSearchSelection: PDFSelection?
        private var pendingSearchSelection: PDFSelection?
        private var pendingSearchHighlight: PDFSelection?
        private var displayedOutlineDestination: PDFDestination?
        private var displayedRequestedPageIndex: Int?
        private weak var readerTapGesture: UITapGestureRecognizer?
        private weak var searchHighlightOverlay: SearchMatchOverlayView?
        private weak var observedPDFView: PDFView?
        private var observedMotionRecognizers = Set<ObjectIdentifier>()
        private var observedPinchRecognizers = Set<ObjectIdentifier>()
        private var protectedPageIndex: Int?
        private var transientPageChangeTokens = Set<UUID>()
        var lastKnownPageIndex = 0

        private var ignoresTransientPageChanges: Bool {
            !transientPageChangeTokens.isEmpty
        }

        private func beginTransientPageChange() -> UUID {
            let token = UUID()
            transientPageChangeTokens.insert(token)
            return token
        }

        private func endTransientPageChange(_ token: UUID) {
            transientPageChangeTokens.remove(token)
        }

        private func validPageIndex(_ pageIndex: Int, in document: PDFDocument) -> Int? {
            guard document.pageCount > 0 else { return nil }
            return min(max(pageIndex, 0), document.pageCount - 1)
        }

        func install(_ document: PDFDocument, at pageIndex: Int, in pdfView: PDFView) {
            // Assigning a PDFDocument always makes PDFKit briefly announce its
            // first page, even when we immediately go to a saved page.  That
            // announcement is setup noise, not reader navigation.
            let transientChange = beginTransientPageChange()
            observedPDFView = pdfView
            let restoredPageIndex = validPageIndex(pageIndex, in: document) ?? 0
            lastKnownPageIndex = restoredPageIndex
            pdfView.document = document
            if let page = document.page(at: restoredPageIndex) {
                pdfView.go(to: page)
            }
            loadedDocument = document
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.endTransientPageChange(transientChange)
                // PDFKit can finish its initial layout without a final
                // page-change notification. Publish the settled visible page
                // explicitly so a newly opened wide document can bookmark
                // its first visible page immediately.
                self.publishReadingPage(in: pdfView)
                self.startObservingSearchHighlightDismissal(in: pdfView)
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
            for recognizer in pinchGestures(in: pdfView)
            where observedPinchRecognizers.insert(ObjectIdentifier(recognizer)).inserted {
                recognizer.addTarget(self, action: #selector(pinchEnded(_:)))
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

        private func pinchGestures(in view: UIView) -> [UIPinchGestureRecognizer] {
            let local = (view.gestureRecognizers ?? []).compactMap { $0 as? UIPinchGestureRecognizer }
            return local + view.subviews.flatMap(pinchGestures(in:))
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

        func updatePageLayout(
            isLandscape: Bool,
            displaysAsBook: Bool,
            readsHorizontally: Bool,
            in pdfView: PDFView
        ) {
            guard self.isLandscape != isLandscape
                    || self.displaysAsBook != displaysAsBook
                    || self.readsHorizontally != readsHorizontally else { return }
            self.isLandscape = isLandscape
            self.displaysAsBook = displaysAsBook
            self.readsHorizontally = readsHorizontally
            // PDFKit may temporarily report page zero while rebuilding its
            // private scroll view. The coordinator's last confirmed page is
            // the only trustworthy position during a layout transaction.
            let pageIndex = lastKnownPageIndex
            let transientChange = beginTransientPageChange()
            UIView.performWithoutAnimation {
                pdfView.displaysAsBook = displaysAsBook
                pdfView.displayDirection = readsHorizontally ? .horizontal : .vertical
                pdfView.displayMode = isLandscape ? .twoUpContinuous : .singlePageContinuous
                pdfView.layoutIfNeeded()
            }
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      let document = pdfView.document,
                      let restoredPageIndex = self.validPageIndex(pageIndex, in: document),
                      let page = document.page(at: restoredPageIndex) else {
                    self?.endTransientPageChange(transientChange)
                    return
                }
                pdfView.layoutIfNeeded()
                if self.isReaderFocused {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
                } else {
                    pdfView.autoScales = true
                }
                pdfView.go(to: page)
                DispatchQueue.main.async { [weak self, weak pdfView] in
                    guard let self else { return }
                    self.endTransientPageChange(transientChange)
                    if let pdfView {
                        self.publishReadingPage(in: pdfView, fallback: restoredPageIndex)
                    }
                }
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
            let currentPageIndex = document.index(for: page)
            hideSearchHighlight()

            // PDFKit reports page zero while it is rebuilding its private
            // scroll view for an otherwise non-navigational resize.  Keep the
            // reading position authoritative until that rebuild is complete.
            if ignoresTransientPageChanges {
                return
            }

            if let protectedPageIndex,
               currentPageIndex != protectedPageIndex,
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

            // PDFKit's `currentPage` is generally the page nearest the
            // viewport centre.  That is a poor bookmark target when several
            // short, wide pages fit on screen: it can skip the first page the
            // reader can see.  Use the leading page in reading order instead.
            publishReadingPage(in: pdfView, fallback: currentPageIndex)
            showPendingSearchHighlightIfReady(in: pdfView)
        }

        private func publishReadingPage(in pdfView: PDFView, fallback: Int? = nil) {
            guard let document = pdfView.document else { return }
            if let currentPage = pdfView.currentPage {
                onPDFKitCurrentPageChanged(document.index(for: currentPage))
            }
            let visiblePageFrames = pdfView.visiblePages.map { page in
                (
                    index: document.index(for: page),
                    frame: pdfView.convert(page.bounds(for: .cropBox), from: page)
                )
            }
            // Prefer the first page whose leading edge actually begins in
            // the viewport. A page with only its final few points visible
            // before that edge should not become the bookmark target.
            let firstPageStartingInView: Int? = visiblePageFrames
                .filter {
                    let leadingEdge = readsHorizontally ? $0.frame.minX : $0.frame.minY
                    let viewportStart = readsHorizontally ? pdfView.bounds.minX : pdfView.bounds.minY
                    let viewportEnd = readsHorizontally ? pdfView.bounds.maxX : pdfView.bounds.maxY
                    return leadingEdge >= viewportStart - 1 && leadingEdge < viewportEnd
                }
                .min {
                    let leftLeadingEdge = readsHorizontally ? $0.frame.minX : $0.frame.minY
                    let rightLeadingEdge = readsHorizontally ? $1.frame.minX : $1.frame.minY
                    if abs(leftLeadingEdge - rightLeadingEdge) > 1 {
                        return leftLeadingEdge < rightLeadingEdge
                    }
                    let leftCrossEdge = readsHorizontally ? $0.frame.minY : $0.frame.minX
                    let rightCrossEdge = readsHorizontally ? $1.frame.minY : $1.frame.minX
                    return leftCrossEdge < rightCrossEdge
                }
                .map(\.index)
            let readingPageIndex = firstPageStartingInView
                ?? visiblePageFrames.map(\.index).min()
                ?? fallback ?? pdfView.currentPage.map { document.index(for: $0) }
                ?? lastKnownPageIndex
            lastKnownPageIndex = readingPageIndex
            onPageChanged(readingPageIndex)
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

        @objc private func pinchEnded(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended,
                  let pdfView = observedPDFView else { return }
            // PDFKit settles its scroll view at the end of a pinch.  Measure
            // on the following turn, then only snap when the reader has
            // already landed close to fitting the page width.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView, self.observedPDFView === pdfView else { return }
                self.snapToFitWidthIfClose(in: pdfView)
            }
        }

        private func snapToFitWidthIfClose(in pdfView: PDFView) {
            guard let page = pdfView.currentPage else { return }
            let pageFrame = pdfView.convert(page.bounds(for: .cropBox), from: page)
            guard pageFrame.width > 0, pdfView.bounds.width > 0 else { return }

            let idealScale = pdfView.scaleFactor * (pdfView.bounds.width / pageFrame.width)
            let fitWidthScale = min(max(idealScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            let distance = abs(pdfView.scaleFactor - fitWidthScale) / fitWidthScale
            guard distance <= 0.075, distance > 0.002 else { return }

            pdfView.autoScales = false
            UIView.performWithoutAnimation {
                pdfView.scaleFactor = fitWidthScale
                pdfView.layoutIfNeeded()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
