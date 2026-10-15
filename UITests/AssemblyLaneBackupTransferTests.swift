import XCTest

final class AssemblyLaneBackupTransferTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTransferControlsOnlyAppearWhenStoreReady() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-test-store-id", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["store.ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["transfer.backup"].exists)
        XCTAssertTrue(app.buttons["transfer.restore"].exists)
        XCTAssertTrue(app.buttons["transfer.csv"].exists)
    }

    @MainActor
    func testBackupAndCsvPreparePrivateShareItems() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-test-store-id", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["transfer.backup"].waitForExistence(timeout: 10))

        app.buttons["transfer.backup"].tap()
        XCTAssertTrue(app.buttons["transfer.backup-share"].waitForExistence(timeout: 10))
        app.buttons["transfer.csv"].tap()
        XCTAssertTrue(app.buttons["transfer.csv-share"].waitForExistence(timeout: 10))
    }
}
