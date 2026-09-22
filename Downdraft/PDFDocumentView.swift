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
    var requestedPageRequestID: UUID?
    var onPageChanged: (Int) -> Void = { _ in }
    var onPDFKitCurrentPageChanged: (Int) -> Void = { _ in }
    var onTextSelectionChanged: (String?) -> Void = { _ in }
    var onJumpToFirstPage: (Int, Int) -> Void = { _, _ in }
    var onCenterTap: () -> Void = { }
    var onLinkNavigation: (Int, Int) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        context.coordinator.startObservingPageChanges(in: view)
        context.coordinator.startObservingOrientationChanges()
        context.coordinator.startObservingSelectionChanges(in: view)
        context.coordinator.startObservingReaderTaps(in: view)
        context.coordinator.startObservingSearchHighlightDismissal(in: view)
        return view
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onPDFKitCurrentPageChanged = onPDFKitCurrentPageChanged
        context.coordinator.onTextSelectionChanged = onTextSelectionChanged
        context.coordinator.onJumpToFirstPage = onJumpToFirstPage
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
        context.coordinator.updateRequestedPage(
            requestedPageIndex,
            requestID: requestedPageRequestID,
            in: pdfView
        )
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
        var onTextSelectionChanged: (String?) -> Void = { _ in }
        var onJumpToFirstPage: (Int, Int) -> Void = { _, _ in }
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
        private var displayedRequestedPageRequestID: UUID?
        private weak var readerTapGesture: UITapGestureRecognizer?
        private weak var searchHighlightOverlay: SearchMatchOverlayView?
        private weak var observedPDFView: PDFView?
        private var observedMotionRecognizers = Set<ObjectIdentifier>()
        private var observedPinchRecognizers = Set<ObjectIdentifier>()
        private var protectedPageIndex: Int?
        private var layoutRestorePageIndex: Int?
        private var layoutRestoreToken: UUID?
        private var firstSpreadProtection: (pageIndex: Int, deadline: Date)?
        private var lastSettledPDFViewBounds: CGRect?
        private var orientationTransitionDeadline: Date?
        // PDFKit commonly exposes page zero while a newly assigned document
        // is still laying out. Never let that setup value replace a restored
        // reading position.
        private var initialRestorePageIndex: Int?
        private var expectedNavigationPageIndex: Int?
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

        private func expectNavigation(to pageIndex: Int) {
            expectedNavigationPageIndex = pageIndex
        }

        func install(_ document: PDFDocument, at pageIndex: Int, in pdfView: PDFView) {
            // Assigning a PDFDocument always makes PDFKit briefly announce its
            // first page, even when we immediately go to a saved page.  That
            // announcement is setup noise, not reader navigation.
            let transientChange = beginTransientPageChange()
            observedPDFView = pdfView
            let restoredPageIndex = validPageIndex(pageIndex, in: document) ?? 0
            lastKnownPageIndex = restoredPageIndex
            initialRestorePageIndex = restoredPageIndex
            lastSettledPDFViewBounds = pdfView.bounds
            pdfView.document = document
            if let page = document.page(at: restoredPageIndex) {
                pdfView.go(to: page)
            }
            loadedDocument = document
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startObservingSearchHighlightDismissal(in: pdfView)
                self.settleInitialRestore(
                    restoredPageIndex,
                    in: pdfView,
                    transientChange: transientChange
                )
            }
        }

        /// Reapply the target after the first layout passes. PDFKit sometimes
        /// has no final page-change notification, so confirmation comes from
        /// its actual current page rather than from a notification. Until
        /// then, `publishReadingPage` is deliberately a no-op.
        private func settleInitialRestore(
            _ pageIndex: Int,
            in pdfView: PDFView,
            transientChange: UUID,
            attemptsRemaining: Int = 2
        ) {
            guard initialRestorePageIndex == pageIndex,
                  let document = pdfView.document,
                  let page = document.page(at: pageIndex) else {
                endTransientPageChange(transientChange)
                return
            }

            pdfView.layoutIfNeeded()
            let currentPageIndex = pdfView.currentPage.map { document.index(for: $0) }
            if currentPageIndex != pageIndex {
                pdfView.go(to: page)
            }

            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                guard self.initialRestorePageIndex == pageIndex,
                      let document = pdfView.document else {
                    self.endTransientPageChange(transientChange)
                    return
                }

                if pdfView.currentPage.map({ document.index(for: $0) }) == pageIndex {
                    self.initialRestorePageIndex = nil
                    self.lastKnownPageIndex = pageIndex
                    self.noteSettledBounds(of: pdfView)
                    self.onPDFKitCurrentPageChanged(pageIndex)
                    self.endTransientPageChange(transientChange)
                } else if attemptsRemaining > 0 {
                    self.settleInitialRestore(
                        pageIndex,
                        in: pdfView,
                        transientChange: transientChange,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                } else {
                    // Do not publish an unconfirmed page. Keep the saved
                    // position as the source of truth and briefly protect it
                    // from any final PDFKit page-zero notification.
                    self.initialRestorePageIndex = nil
                    self.lastKnownPageIndex = pageIndex
                    self.protectedPageIndex = pageIndex
                    self.endTransientPageChange(transientChange)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.protectedPageIndex = nil
                    }
                }
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

        func startObservingOrientationChanges() {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(orientationChanged),
                name: UIDevice.orientationDidChangeNotification,
                object: UIDevice.current
            )
        }

        @objc private func orientationChanged(_ notification: Notification) {
            let orientation = UIDevice.current.orientation
            guard orientation.isPortrait || orientation.isLandscape else { return }
            // PDFKit can announce page zero before the SwiftUI view receives
            // its new bounds. Retain this signal briefly so that early
            // announcement cannot be mistaken for reader navigation.
            orientationTransitionDeadline = Date().addingTimeInterval(1.5)
            rotationTrace("orientation transition began: \(orientation.rawValue)")
        }

        private var isOrientationTransitionInProgress: Bool {
            guard let orientationTransitionDeadline else { return false }
            return orientationTransitionDeadline > Date()
        }

        func startObservingSelectionChanges(in pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            onTextSelectionChanged(text?.isEmpty == false ? text : nil)
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
            // A bounds change from device rotation is PDFKit's ordinary
            // layout work. Do not change its display mode at the same time:
            // that private rebuild is what can send the canvas to page one.
            // The only explicit layout choice remaining is reading direction.
            guard self.readsHorizontally != readsHorizontally else { return }
            self.isLandscape = isLandscape
            self.displaysAsBook = displaysAsBook
            self.readsHorizontally = readsHorizontally
            // PDFKit may temporarily report page zero while rebuilding its
            // private scroll view. The coordinator's last confirmed page is
            // the only trustworthy position during a layout transaction.
            let pageIndex = lastKnownPageIndex
            rotationTrace(
                "layout start target=\(pageIndex) bounds=\(pdfView.bounds.integral) landscape=\(isLandscape)"
            )
            layoutRestorePageIndex = pageIndex
            let layoutRestoreToken = UUID()
            self.layoutRestoreToken = layoutRestoreToken
            let transientChange = beginTransientPageChange()
            UIView.performWithoutAnimation {
                pdfView.displaysAsBook = false
                pdfView.displayDirection = readsHorizontally ? .horizontal : .vertical
                pdfView.displayMode = .singlePageContinuous
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
                    guard let self, let pdfView else { return }
                    self.settleLayoutRestore(
                        restoredPageIndex,
                        in: pdfView,
                        token: layoutRestoreToken,
                        transientChange: transientChange
                    )
                }
            }
        }

        /// A rotation is a view-layout transaction, not reading progress.
        /// PDFKit may expose page zero for several turns while rebuilding its
        /// scroll view. Reapply and confirm the known page, but never publish
        /// an intermediate layout result as a new saved position.
        private func settleLayoutRestore(
            _ pageIndex: Int,
            in pdfView: PDFView,
            token: UUID,
            transientChange: UUID,
            attemptsRemaining: Int = 2
        ) {
            guard layoutRestorePageIndex == pageIndex,
                  layoutRestoreToken == token,
                  let document = pdfView.document,
                  let page = document.page(at: pageIndex) else {
                endTransientPageChange(transientChange)
                return
            }

            pdfView.layoutIfNeeded()
            if pdfView.currentPage.map({ document.index(for: $0) }) != pageIndex {
                pdfView.go(to: page)
            }

            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView,
                      self.layoutRestorePageIndex == pageIndex,
                      self.layoutRestoreToken == token,
                      let document = pdfView.document else {
                    self?.endTransientPageChange(transientChange)
                    return
                }

                if pdfView.currentPage.map({ document.index(for: $0) }) == pageIndex {
                    self.finishLayoutRestore(
                        pageIndex,
                        in: pdfView,
                        token: token,
                        transientChange: transientChange
                    )
                } else if attemptsRemaining > 0 {
                    self.settleLayoutRestore(
                        pageIndex,
                        in: pdfView,
                        token: token,
                        transientChange: transientChange,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                } else {
                    // Preserve the existing page even if PDFKit has not
                    // settled yet; a short protection window rejects any
                    // final synthetic page-zero notification.
                    self.layoutRestorePageIndex = nil
                    self.layoutRestoreToken = nil
                    self.lastKnownPageIndex = pageIndex
                    self.protectedPageIndex = pageIndex
                    self.rotationTrace("layout failed to settle target=\(pageIndex) current=\(pdfView.currentPage.map { document.index(for: $0) } ?? -1)")
                    self.endTransientPageChange(transientChange)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.protectedPageIndex = nil
                    }
                }
            }
        }

        /// PDFKit may report the requested page before its internal scroll
        /// view completes the rotation. Reapply the destination after that
        /// final scroll pass, while transient notifications remain ignored.
        private func finishLayoutRestore(
            _ pageIndex: Int,
            in pdfView: PDFView,
            token: UUID,
            transientChange: UUID
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak pdfView] in
                guard let self,
                      let pdfView,
                      self.layoutRestorePageIndex == pageIndex,
                      self.layoutRestoreToken == token,
                      let document = pdfView.document,
                      let page = document.page(at: pageIndex) else {
                    self?.endTransientPageChange(transientChange)
                    return
                }
                pdfView.go(to: page)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak pdfView] in
                    guard let self,
                          let pdfView,
                          self.layoutRestorePageIndex == pageIndex,
                          self.layoutRestoreToken == token else {
                        self?.endTransientPageChange(transientChange)
                        return
                    }
                    self.layoutRestorePageIndex = nil
                    self.layoutRestoreToken = nil
                    self.lastKnownPageIndex = pageIndex
                    self.noteSettledBounds(of: pdfView)
                    self.firstSpreadProtection = (
                        pageIndex: pageIndex,
                        // PDFKit's final private scroll can be surprisingly
                        // late. A real pan clears this immediately, so the
                        // longer timeout does not interfere with reading.
                        deadline: Date().addingTimeInterval(5)
                    )
                    self.onPDFKitCurrentPageChanged(pageIndex)
                    self.rotationTrace("layout settled page=\(pageIndex) bounds=\(pdfView.bounds.integral)")
                    self.endTransientPageChange(transientChange)
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
                if let document = pdfView.document {
                    self.expectNavigation(to: document.index(for: page))
                }
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
                if let page = destination.page,
                   let document = pdfView.document {
                    expectNavigation(to: document.index(for: page))
                }
                pdfView.go(to: destination)
            }
        }

        func updateRequestedPage(_ pageIndex: Int?, requestID: UUID?, in pdfView: PDFView) {
            guard let pageIndex else {
                displayedRequestedPageRequestID = nil
                return
            }
            guard displayedRequestedPageRequestID != requestID else { return }
            displayedRequestedPageRequestID = requestID
            rotationTrace("explicit request page=\(pageIndex) id=\(requestID?.uuidString ?? "nil")")
            // `PDFView.go(to:)` can synchronously publish a page change. Do
            // not let that callback mutate SwiftUI state during this
            // representable's update pass; it is the source of intermittent
            // stale scrubber positions after bookmark jumps.
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self,
                      self.displayedRequestedPageRequestID == requestID,
                      let pdfView,
                      let page = pdfView.document?.page(at: pageIndex) else { return }
                self.expectNavigation(to: pageIndex)
                pdfView.go(to: page)
            }
        }

        @MainActor @objc private func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let currentPageIndex = document.index(for: page)
            let previousPageIndex = lastKnownPageIndex
            rotationTrace(
                "page changed current=\(currentPageIndex) previous=\(previousPageIndex) bounds=\(pdfView.bounds.integral) transient=\(ignoresTransientPageChanges) layout=\(layoutRestorePageIndex.map(String.init) ?? "nil") protected=\(protectedPageIndex.map(String.init) ?? "nil")"
            )
            hideSearchHighlight()

            // On rotation, PDFKit can announce page zero before SwiftUI has
            // delivered the new layout values to `updatePageLayout`. Catch
            // that earlier notification by comparing the view's settled size,
            // rather than allowing it to overwrite `lastKnownPageIndex`.
            if currentPageIndex == 0,
               previousPageIndex > 0,
               (hasUnsettledBoundsChange(in: pdfView) || isOrientationTransitionInProgress) {
                rotationTrace("ignored page zero during orientation/layout transition")
                return
            }

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

            // In two-up book mode, PDFKit can make one final private scroll
            // to its first spread (reported as page zero or one) after the
            // layout transaction has otherwise settled. It is neither a
            // deliberate reader move nor a valid restored position.
            if let firstSpreadProtection,
               firstSpreadProtection.deadline > Date(),
               firstSpreadProtection.pageIndex > 1,
               currentPageIndex <= 1,
               expectedNavigationPageIndex != currentPageIndex,
               let protectedPage = document.page(at: firstSpreadProtection.pageIndex) {
                rotationTrace("rejected late first-spread reset to \(currentPageIndex)")
                pdfView.go(to: protectedPage)
                return
            }

            let isExpectedNavigation = expectedNavigationPageIndex == currentPageIndex
            if isExpectedNavigation {
                expectedNavigationPageIndex = nil
            }
            // Tapping the system status area scrolls PDFKit's scroll view all
            // the way to its beginning. Treat that large, otherwise
            // unexplained move to page one as a real history event.
            if !isExpectedNavigation,
               currentPageIndex == 0,
               previousPageIndex > 1 {
                onJumpToFirstPage(previousPageIndex, currentPageIndex)
            }

            // PDFKit's `currentPage` is generally the page nearest the
            // viewport centre.  That is a poor bookmark target when several
            // short, wide pages fit on screen: it can skip the first page the
            // reader can see.  Use the leading page in reading order instead.
            publishReadingPage(in: pdfView, fallback: currentPageIndex)
            showPendingSearchHighlightIfReady(in: pdfView)
        }

        private func publishReadingPage(in pdfView: PDFView, fallback: Int? = nil) {
            // Initial PDFKit layout may briefly describe page zero, even after
            // `go(to:)` has been asked to restore a later page. It is not a
            // reader action and must never be persisted or synced.
            guard initialRestorePageIndex == nil else { return }
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
            noteSettledBounds(of: pdfView)
            rotationTrace("published page=\(readingPageIndex) fallback=\(fallback.map(String.init) ?? "nil")")
            onPageChanged(readingPageIndex)
        }

        private func rotationTrace(_ message: String) {
#if DEBUG
            let entry = "[Downdraft rotation] \(message)"
            print(entry)
            let traceURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("DowndraftRotationTrace.txt")
            let previous = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            let recent = String(previous.suffix(12_000))
            try? (recent + entry + "\n").write(to: traceURL, atomically: true, encoding: .utf8)
#endif
        }

        private func hasUnsettledBoundsChange(in pdfView: PDFView) -> Bool {
            guard let lastSettledPDFViewBounds else { return false }
            return abs(lastSettledPDFViewBounds.width - pdfView.bounds.width) > 1
                || abs(lastSettledPDFViewBounds.height - pdfView.bounds.height) > 1
        }

        private func noteSettledBounds(of pdfView: PDFView) {
            lastSettledPDFViewBounds = pdfView.bounds
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
                expectNavigation(to: document.index(for: destinationPage))
                pdfView.go(to: destination)
            } else if let url = annotation.url {
                UIApplication.shared.open(url)
            }
        }

        @objc private func readerMotionBegan(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            firstSpreadProtection = nil
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
