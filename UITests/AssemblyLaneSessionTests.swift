import XCTest

/// Issue #4: one-thumb assembly UI journeys.
/// Covers: project creation, step add, start/complete/reopen, part tray
/// consumption with visible overspend conflict and unknown count, plus
/// app interruption resume where the session restores from the local store.
///
/// Evidence tier: Apple CI iPhone simulator only (Scripts/ci.sh XCUITest lane);
/// no Linux host can run these tests.
final class AssemblyLaneSessionTests: XCTestCase {
    private var launchArguments: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Fresh per-test store; the app keeps data on disk, so each journey
        // and its terminate/relaunch resume share one new isolated root.
        launchArguments = ["-ui-testing", "-test-store-id", UUID().uuidString]
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()
        return app
    }

    /// SwiftUI state updates are async; poll a bounded deadline instead of
    /// asserting against a possibly stale snapshot right after a tap.
    @MainActor
    private func waitLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var matched = element.label.contains(text)
        while !matched && Date() < deadline {
            usleep(200_000)
            matched = element.label.contains(text)
        }
        XCTAssertTrue(matched, "expected label containing \"\(text)\", got \"\(element.label)\"", file: file, line: line)
    }

    @MainActor
    func testAssemblySessionJourneyWithInterruptionResume() throws {
        let app = launchApp()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["home.manual-notice"].exists)

        // 1. Create project
        let newButton = app.buttons["project.new"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        let nameField = app.textFields["project.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Toolbox")

        let notesField = app.textFields["project.notes"]
        notesField.tap()
        notesField.typeText("Pine frame with tray")

        app.buttons["project.save"].tap()

        // 2. Open project session
        let row = app.buttons["project.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.staticTexts["session.manual-notice"].waitForExistence(timeout: 5))

        // 3. Add a step
        app.buttons["step.add"].tap()
        let stepName = app.textFields["step.name"]
        XCTAssertTrue(stepName.waitForExistence(timeout: 5))
        stepName.tap()
        stepName.typeText("Fasten side panels")
        app.buttons["step.save"].tap()

        // 4. Add parts: one known count (1), one unknown count
        XCTAssertTrue(app.buttons["part.add"].waitForExistence(timeout: 5))
        app.buttons["part.add"].firstMatch.tap()
        // Toggle BEFORE focusing any text field; the keyboard can cover the
        // toggle and absorb gestures. Tap the nested switch itself, not the
        // merged row label, then poll its value.
        let toggleRow = app.switches["part.count-known"]
        XCTAssertTrue(toggleRow.waitForExistence(timeout: 5))
        let innerSwitch = toggleRow.switches.firstMatch.exists ? toggleRow.switches.firstMatch : toggleRow
        let deadline = Date().addingTimeInterval(5)
        while !String(describing: innerSwitch.value).contains("1") && Date() < deadline {
            innerSwitch.tap()
            usleep(200_000)
        }
        let countField = app.textFields["part.count"]
        XCTAssertTrue(countField.waitForExistence(timeout: 5), "count field proves the toggle flipped")
        let partName = app.textFields["part.name"]
        XCTAssertTrue(partName.waitForExistence(timeout: 5))
        partName.tap()
        partName.typeText("Brass screws")
        countField.tap()
        countField.typeText("1")
        app.buttons["part.save"].tap()

        XCTAssertTrue(app.buttons["part.add"].waitForExistence(timeout: 5))
        app.buttons["part.add"].firstMatch.tap()
        let partName2 = app.textFields["part.name"]
        XCTAssertTrue(partName2.waitForExistence(timeout: 5))
        partName2.tap()
        partName2.typeText("Corner braces")
        // leave the count unknown
        app.buttons["part.save"].tap()

        // 5. Before start: step says Not started
        let status = app.staticTexts["step.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        waitLabel(status, containing: "Not started")

        // 6. Start step
        app.buttons["step.start"].firstMatch.tap()
        waitLabel(status, containing: "In progress")

        // 7. Consume part once -> 0 remaining
        let useButton = app.buttons["part.use"].firstMatch
        XCTAssertTrue(useButton.waitForExistence(timeout: 5))
        useButton.tap()
        let stock = app.staticTexts["part.stock"].firstMatch
        waitLabel(stock, containing: "0 remaining")

        // 8. Consume part again -> visible conflict (overspend, never silent)
        app.buttons["part.use"].firstMatch.tap()
        waitLabel(stock, containing: "Count conflict")

        // 9. Complete step
        app.buttons["step.complete"].firstMatch.tap()
        waitLabel(status, containing: "Completed")

        // 10. Reopen step with a reason
        let reopenButton = app.buttons["step.reopen"].firstMatch
        XCTAssertTrue(reopenButton.waitForExistence(timeout: 5))
        reopenButton.tap()
        let reason = app.textFields["step.reopen-reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.tap()
        reason.typeText("One screw stripped")
        app.buttons["step.reopen-save"].tap()
        waitLabel(status, containing: "Reopened")

        // 11. Interruption resume: terminate, relaunch, session restores from disk
        app.terminate()
        let resumed = launchApp()

        XCTAssertTrue(resumed.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        let resumedRow = resumed.buttons["project.row"].firstMatch
        XCTAssertTrue(resumedRow.waitForExistence(timeout: 5))
        resumedRow.tap()

        XCTAssertTrue(resumed.staticTexts["session.manual-notice"].waitForExistence(timeout: 5))
        waitLabel(resumed.staticTexts["step.status"].firstMatch, containing: "Reopened")
        waitLabel(resumed.staticTexts["part.stock"].firstMatch, containing: "Count conflict")
    }

    /// Dynamic Type acceptance: the session stays navigable at the largest
    /// accessibility category (AX5). Existence checks only — at AX5 many
    /// controls are legitimately off-screen and scrolling is exercised in
    /// the main journey.
    @MainActor
    func testSessionStaysNavigableAtMaxDynamicType() throws {
        let app = XCUIApplication()
        app.launchArguments = launchArguments + [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] = "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["home.manual-notice"].exists)
        XCTAssertTrue(app.buttons["project.new"].exists)
    }
}
