import XCTest

@MainActor
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

    func testTopControlsRemainResponsiveAfterRepeatedMenus() {
        let app = launchFixture()

        app.buttons["PDF information"].tap()
        XCTAssertTrue(app.navigationBars["PDF Information"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        let layout = app.buttons["Reader layout"]
        layout.tap()
        XCTAssertTrue(app.buttons["Scroll horizontally"].waitForExistence(timeout: 3))
        app.buttons["Scroll horizontally"].tap()

        layout.tap()
        XCTAssertTrue(app.buttons["Scroll vertically"].waitForExistence(timeout: 3))
        app.buttons["Scroll vertically"].tap()

        app.buttons["Documents"].tap()
        XCTAssertTrue(app.staticTexts["Downdraft UI Fixture"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
    }

    func testHistoryBackWorksAfterTheFirstScrub() {
        let app = launchFixture()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))

        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 5))
    }

    func testBookmarkJumpUpdatesTheReaderAndScrubber() {
        let app = launchFixture()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))

        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 3))
        app.buttons["Add Bookmark"].press(forDuration: 1.1)
        let bookmark = app.buttons["Bookmark 1"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 3))

        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 3))
        bookmark.tap()
        XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 5))
    }
}
