import XCTest

final class DowndraftUITests: XCTestCase {
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Documents"].waitForExistence(timeout: 5))
        return app
    }

    func testDocumentSwitcherShowsFixtureAndCanDismiss() {
        let app = launchFixture()
        app.buttons["Documents"].tap()
        XCTAssertTrue(app.staticTexts["Downdraft UI Fixture"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Documents"].waitForExistence(timeout: 3))
    }

    func testSearchCanFocusFindAndDismiss() {
        let app = launchFixture()
        if app.buttons["Search"].exists {
            app.buttons["Search"].tap()
        } else {
            app.buttons["Start search"].tap()
        }

        let field = app.textFields["Find in PDF"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("needle")
        XCTAssertTrue(app.buttons["Dismiss search"].waitForExistence(timeout: 3))
        app.buttons["Dismiss search"].tap()
        XCTAssertFalse(app.buttons["Dismiss search"].exists)
    }

    func testReaderSurvivesRotationAndKeepsItsScrubber() {
        let app = launchFixture()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
    }
}
