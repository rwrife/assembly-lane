import Foundation
import XCTest

@testable import AssemblyLaneKit

/// Issue #4: session operations are append-only, resume-safe and never
/// fabricate quantities or consume without an explicit event.
final class ProjectSessionTests: XCTestCase {
    private var root: URL!
    private var store: LocalProjectStore!
    private var session: ProjectSession!
    private var projectId: UUID!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        store = try LocalProjectStore(root: root)
        session = ProjectSession(store: store)
        projectId = try session.createProject(title: "Bookshelf")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func reloadedSession() throws -> ProjectSession {
        ProjectSession(store: try LocalProjectStore(root: root))
    }

    // MARK: - Creation and edit

    func testCreateAndEditProjectTrimsAndRejectsEmpty() throws {
        var record = try session.record(projectId: projectId)
        XCTAssertEqual(record.project.title, "Bookshelf")
        try session.updateProject(projectId: projectId, title: "  Wall Shelf ", notes: "  oak ", at: t0)
        record = try session.record(projectId: projectId)
        XCTAssertEqual(record.project.title, "Wall Shelf")
        XCTAssertEqual(record.project.notes, "oak")
        XCTAssertThrowsError(try session.createProject(title: "   ")) {
            XCTAssertEqual($0 as? SessionError, .emptyTitle)
        }
        XCTAssertThrowsError(try session.updateProject(projectId: projectId, title: "", notes: "")) {
            XCTAssertEqual($0 as? SessionError, .emptyTitle)
        }
    }

    func testAddStepsGetDeterministicOrderIndex() throws {
        _ = try session.addStep(projectId: projectId, title: "Sort hardware")
        _ = try session.addStep(projectId: projectId, title: "Attach rails")
        let record = try session.record(projectId: projectId)
        XCTAssertEqual(record.steps.map(\.orderIndex), [0, 1])
        XCTAssertEqual(try session.projection(for: record).stepStatuses().map(\.step.title),
                       ["Sort hardware", "Attach rails"])
    }

    // MARK: - Step lifecycle

    func testStartCompleteReopenAppendsEventsAndSurvivesReload() throws {
        let stepId = try session.addStep(projectId: projectId, title: "Drill pilot holes")
        try session.startStep(projectId: projectId, stepId: stepId, at: t0)
        try session.completeStep(projectId: projectId, stepId: stepId, at: t0.addingTimeInterval(60))
        try session.reopenStep(projectId: projectId, stepId: stepId, reason: "Cam lock stripped",
                               at: t0.addingTimeInterval(120))

        // Fresh store from disk: state resumes purely from the event log.
        let resumed = try reloadedSession()
        let record = try resumed.record(projectId: projectId)
        XCTAssertEqual(record.events.count, 3)
        XCTAssertEqual(record.events.map(\.kind), [.stepStarted, .stepCompleted, .stepReopened])
        let projection = try resumed.projection(for: record)
        XCTAssertEqual(projection.stepStatus(for: stepId), .reopened)
        XCTAssertEqual(projection.stepReopenCount(for: stepId), 1)
        XCTAssertEqual(projection.stepEventHistory(for: stepId).count, 3)
    }

    func testReopenRequiresReason() throws {
        let stepId = try session.addStep(projectId: projectId, title: "Set shelf level")
        XCTAssertThrowsError(try session.reopenStep(projectId: projectId, stepId: stepId, reason: "  ")) {
            XCTAssertEqual($0 as? SessionError, .emptyReopenReason)
        }
    }

    func testLifecycleRejectsForeignStep() throws {
        let other = try session.createProject(title: "Desk")
        let otherStep = try session.addStep(projectId: other, title: "Foreign step")
        XCTAssertThrowsError(try session.startStep(projectId: projectId, stepId: otherStep)) {
            XCTAssertEqual($0 as? SessionError, .unknownStep)
        }
        XCTAssertThrowsError(try session.completeStep(projectId: other, stepId: UUID())) {
            XCTAssertEqual($0 as? SessionError, .unknownStep)
        }
    }

    // MARK: - Explicit consumption

    func testConsumeAttributesToStepAndCountsUp() throws {
        let stepId = try session.addStep(projectId: projectId, title: "Drive screws")
        let partId = try session.addPart(projectId: projectId, name: "#8 screws",
                                         initialQuantity: .known(4))
        try session.consumePart(projectId: projectId, partId: partId, stepId: stepId,
                                quantity: 3, at: t0)
        var record = try session.record(projectId: projectId)
        XCTAssertEqual(try session.projection(for: record).partStock(for: partId)?.consumed, 3)

        try session.consumePart(projectId: projectId, partId: partId, stepId: stepId,
                                quantity: 1, at: t0.addingTimeInterval(10))
        record = try session.record(projectId: projectId)
        XCTAssertEqual(try session.projection(for: record).partStock(for: partId)?.remaining, .known(0))
    }

    func testOverspendStaysVisibleConflictAndUnknownStaysUnknown() throws {
        let stepId = try session.addStep(projectId: projectId, title: "Attach back panel")
        let counted = try session.addPart(projectId: projectId, name: "Cam locks",
                                          initialQuantity: .known(2))
        let mystery = try session.addPart(projectId: projectId, name: "Spare dowels",
                                          initialQuantity: .unknown)
        try session.consumePart(projectId: projectId, partId: counted, stepId: stepId, quantity: 5)
        try session.consumePart(projectId: projectId, partId: mystery, stepId: stepId, quantity: 3)
        let projection = try session.projection(for: try session.record(projectId: projectId))
        XCTAssertEqual(projection.partStock(for: counted)?.remaining, .conflict(expected: 2, consumed: 5))
        XCTAssertEqual(projection.partStock(for: counted)?.overspentBy, 3)
        let stock = try XCTUnwrap(projection.partStock(for: mystery))
        XCTAssertEqual(stock.consumed, 3)
        XCTAssertEqual(stock.remaining, .unknown)
    }

    func testConsumeValidatesQuantityAndEntities() throws {
        let stepId = try session.addStep(projectId: projectId, title: "Insert dowels")
        let partId = try session.addPart(projectId: projectId, name: "Dowels",
                                         initialQuantity: .known(8))
        for bad in [0, -1] {
            XCTAssertThrowsError(
                try session.consumePart(projectId: projectId, partId: partId, stepId: stepId, quantity: bad)
            ) { XCTAssertEqual($0 as? SessionError, .invalidQuantity) }
        }
        XCTAssertThrowsError(
            try session.consumePart(projectId: projectId, partId: UUID(), stepId: stepId, quantity: 1)
        ) { XCTAssertEqual($0 as? SessionError, .unknownPart) }
        XCTAssertThrowsError(
            try session.consumePart(projectId: projectId, partId: partId, stepId: UUID(), quantity: 1)
        ) { XCTAssertEqual($0 as? SessionError, .unknownStep) }
    }

    // MARK: - Active step (implicit-consumption guard the UI relies on)

    func testActiveStepTracksLatestOpenLifecycle() throws {
        let first = try session.addStep(projectId: projectId, title: "Unpack")
        let second = try session.addStep(projectId: projectId, title: "Assemble frame")
        XCTAssertNil(try session.activeStep(in: try session.record(projectId: projectId)))

        try session.startStep(projectId: projectId, stepId: first, at: t0)
        try session.startStep(projectId: projectId, stepId: second, at: t0.addingTimeInterval(10))
        XCTAssertEqual(try session.activeStep(in: try session.record(projectId: projectId))?.id, second)

        try session.completeStep(projectId: projectId, stepId: second, at: t0.addingTimeInterval(20))
        XCTAssertEqual(try session.activeStep(in: try session.record(projectId: projectId))?.id, first)

        try session.reopenStep(projectId: projectId, stepId: second, reason: "Frame racked",
                               at: t0.addingTimeInterval(30))
        XCTAssertEqual(try session.activeStep(in: try session.record(projectId: projectId))?.id, second)

        try session.completeStep(projectId: projectId, stepId: first, at: t0.addingTimeInterval(40))
        try session.completeStep(projectId: projectId, stepId: second, at: t0.addingTimeInterval(50))
        XCTAssertNil(try session.activeStep(in: try session.record(projectId: projectId)))
    }

    func testUnknownProjectAndEntitiesRejected() throws {
        let foreign = UUID()
        XCTAssertThrowsError(try session.record(projectId: foreign)) {
            XCTAssertEqual($0 as? SessionError, .unknownProject)
        }
        XCTAssertThrowsError(try session.addStep(projectId: foreign, title: "Ghost")) {
            XCTAssertEqual($0 as? SessionError, .unknownProject)
        }
    }

    func testPartRejectsNegativeKnownQuantity() throws {
        XCTAssertThrowsError(
            try session.addPart(projectId: projectId, name: "Bad", initialQuantity: .known(-1))
        ) { XCTAssertEqual($0 as? SessionError, .invalidQuantity) }
    }
}
