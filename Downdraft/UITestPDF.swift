import UIKit

#if DEBUG
enum UITestPDF {
    static func makeFixture() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Downdraft UI Fixture.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        do {
            try renderer.writePDF(to: url) { context in
                for page in 1...3 {
                    context.beginPage()
                    let text = "Downdraft UI Fixture\nPage \(page)\nneedle"
                    text.draw(
                        in: CGRect(x: 48, y: 64, width: 500, height: 180),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 28)]
                    )
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
#endif
