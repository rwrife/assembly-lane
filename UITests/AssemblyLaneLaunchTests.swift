import XCTest

final class AssemblyLaneLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Assembly Lane"].exists)
        XCTAssertTrue(app.staticTexts["Projects, step cards and the parts tray arrive in the next milestones."].exists)
    }
}
