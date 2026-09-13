import PDFKit
import UIKit
import XCTest
@testable import Downdraft

final class OpenDocumentTests: XCTestCase {
    func testFullFileNameKeepsExtensionAfterLazyRestore() {
        let document = OpenDocument(
            url: nil,
            bookmarkData: Data(),
            displayName: "A long document name",
            originalURLString: "file:///Documents/A%20long%20document%20name.pdf",
            isAccessingFile: false
        )

        XCTAssertEqual(document.fullFileName, "A long document name.pdf")
        XCTAssertEqual(document.fullFileLocation, "/Documents/A long document name.pdf")
    }

    func testDeletedOrInvalidBookmarkFailsGracefully() {
        let document = OpenDocument(
            url: nil,
            bookmarkData: Data("not a bookmark".utf8),
            displayName: "Missing",
            originalURLString: "",
            isAccessingFile: false
        )

        XCTAssertFalse(document.loadFileIfNeeded())
        XCTAssertNil(document.pdfDocument)
    }

    func testSamePDFAtTwoLocationsHasSameIdentity() throws {
        let source = try makePDF(named: "source.pdf", pageText: "same PDF")
        let copy = source.deletingLastPathComponent().appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: copy) }

        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let copyDocument = try XCTUnwrap(PDFDocument(url: copy))

        XCTAssertEqual(
            ReadingStateStore.identity(for: source, document: sourceDocument),
            ReadingStateStore.identity(for: copy, document: copyDocument)
        )
    }

    func testDifferentPDFsHaveDifferentIdentities() throws {
        let first = try makePDF(named: "first.pdf", pageText: "first PDF")
        let second = try makePDF(named: "second.pdf", pageText: "second PDF")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

        let firstDocument = try XCTUnwrap(PDFDocument(url: first))
        let secondDocument = try XCTUnwrap(PDFDocument(url: second))

        XCTAssertNotEqual(
            ReadingStateStore.identity(for: first, document: firstDocument),
            ReadingStateStore.identity(for: second, document: secondDocument)
        )
    }

    private func makePDF(named name: String, pageText: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            pageText.draw(
                in: CGRect(x: 48, y: 48, width: 500, height: 60),
                withAttributes: [.font: UIFont.systemFont(ofSize: 20)]
            )
        }
        return url
    }
}
