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
    var onPageChanged: (Int) -> Void = { _ in }
    var onCenterTap: () -> Void = { }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
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
        private var isLandscape = false
        private var displaysAsBook = false
        private var displayedSearchSelection: PDFSelection?
        private var displayedOutlineDestination: PDFDestination?
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
            tapGesture.cancelsTouchesInView = false
            tapGesture.delegate = self
            pdfView.addGestureRecognizer(tapGesture)
        }

        func updateReaderFocus(_ isFocused: Bool, isActive: Bool, in pdfView: PDFView) {
            guard isReaderFocused != isFocused || isActive else { return }
            isReaderFocused = isFocused
            guard isActive else { return }

            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView else { return }
                if isFocused {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
                } else {
                    pdfView.autoScales = true
                }
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

extension PDFDocumentView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tapGesture = gestureRecognizer as? UITapGestureRecognizer,
              let pdfView = tapGesture.view else { return false }
        let location = tapGesture.location(in: pdfView)
        return location.y <= pdfView.bounds.height * 0.25
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
