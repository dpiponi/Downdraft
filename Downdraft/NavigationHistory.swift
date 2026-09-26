import Foundation

/// Local, per-document history for deliberate reader jumps.
///
/// The current page is supplied on Back and Forward because PDFKit can know
/// it a callback earlier than the persisted reading position. This type owns
/// only the ordered history and its cursor; it has no PDFKit or persistence
/// dependencies.
struct NavigationHistory: Equatable {
    private(set) var pages: [Int]
    private(set) var currentIndex: Int
    let maximumEntryCount: Int

    init(currentPage: Int, maximumEntryCount: Int = 100) {
        self.pages = [currentPage]
        self.currentIndex = 0
        self.maximumEntryCount = maximumEntryCount
    }

    var canNavigateBack: Bool {
        currentIndex > 0
    }

    var canNavigateForward: Bool {
        currentIndex < pages.count - 1
    }

    mutating func record(from source: Int, to destination: Int) {
        guard source != destination else { return }
        pages[currentIndex] = source
        pages.removeSubrange((currentIndex + 1)..<pages.count)
        pages.append(destination)
        if pages.count > maximumEntryCount {
            pages.removeFirst(pages.count - maximumEntryCount)
        }
        currentIndex = pages.count - 1
    }

    mutating func navigateBack(from currentPage: Int) -> Int? {
        guard canNavigateBack else { return nil }
        pages[currentIndex] = currentPage
        currentIndex -= 1
        return pages[currentIndex]
    }

    mutating func navigateForward(from currentPage: Int) -> Int? {
        guard canNavigateForward else { return nil }
        pages[currentIndex] = currentPage
        currentIndex += 1
        return pages[currentIndex]
    }
}
