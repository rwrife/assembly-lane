import XCTest

final class AssemblyLaneLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-test-store-id", UUID().uuidString]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.manual-notice"].exists)
        XCTAssertTrue(app.staticTexts["A private, offline workspace for hands-on builds."].exists)
        XCTAssertTrue(app.buttons["project.new"].exists)
    }
}
