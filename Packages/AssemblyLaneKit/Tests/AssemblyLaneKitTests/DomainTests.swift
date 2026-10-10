import Foundation
import Testing
@testable import AssemblyLaneKit

@Suite("AssemblyLaneKit Domain & Event Projection")
struct DomainTests {
    @Test("milestone marker is M1-domain")
    func milestoneUpdated() {
        #expect(AssemblyLaneKit.milestone == "M1-domain")
    }

    @Test("Project holds metadata and stable identity")
    func projectBasics() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            id: id,
            title: "Model Engine",
            notes: "V-twin build",
            createdAt: now,
            updatedAt: now
        )
        #expect(project.id == id)
        #expect(project.title == "Model Engine")
        #expect(project.notes == "V-twin build")
    }

    @Test("Part with unknown initial quantity remains unknown after use")
    func unknownQuantityRemainsUnknown() throws {
        let partId = UUID()
        let stepId = UUID()
        let projectId = UUID()
        let part = Part(
            id: partId,
            projectId: projectId,
            name: "M3x8 Socket Cap Screw",
            initialQuantity: .unknown
        )
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])

        let events: [AssemblyEvent] = [
            .partUsed(
                id: UUID(),
                projectId: projectId,
                timestamp: Date(timeIntervalSince1970: 10),
                partId: partId,
                stepId: stepId,
                quantity: 4
            )
        ]

        let projection = try AssemblyProjection(
            parts: [part],
            steps: [step],
            events: events
        )

        let stock = try #require(projection.partStock(for: partId))
        #expect(stock.consumed == 4)
        #expect(stock.remaining == .unknown)
        #expect(stock.isOverspent == false)
    }

    @Test("Part with exact initial quantity decrements correctly")
    func exactQuantityDecrements() throws {
        let partId = UUID()
        let stepId = UUID()
        let projectId = UUID()
        let part = Part(
            id: partId,
            projectId: projectId,
            name: "M4 Washer",
            initialQuantity: .known(10)
        )
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])

        let events: [AssemblyEvent] = [
            .partUsed(
                id: UUID(),
                projectId: projectId,
                timestamp: Date(timeIntervalSince1970: 10),
                partId: partId,
                stepId: stepId,
                quantity: 3
            ),
            .partUsed(
                id: UUID(),
                projectId: projectId,
                timestamp: Date(timeIntervalSince1970: 20),
                partId: partId,
                stepId: stepId,
                quantity: 2
            )
        ]

        let projection = try AssemblyProjection(
            parts: [part],
            steps: [step],
            events: events
        )

        let stock = try #require(projection.partStock(for: partId))
        #expect(stock.consumed == 5)
        #expect(stock.remaining == .known(5))
        #expect(stock.isOverspent == false)
    }

    @Test("Overspend produces a visible conflict, never implicit negative stock")
    func overspendProducesVisibleConflict() throws {
        let partId = UUID()
        let stepId = UUID()
        let projectId = UUID()
        let part = Part(
            id: partId,
            projectId: projectId,
            name: "Bearing 608RS",
            initialQuantity: .known(2)
        )
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])

        let events: [AssemblyEvent] = [
            .partUsed(
                id: UUID(),
                projectId: projectId,
                timestamp: Date(timeIntervalSince1970: 10),
                partId: partId,
                stepId: stepId,
                quantity: 3
            )
        ]

        let projection = try AssemblyProjection(
            parts: [part],
            steps: [step],
            events: events
        )

        let stock = try #require(projection.partStock(for: partId))
        #expect(stock.consumed == 3)
        #expect(stock.remaining == .conflict(expected: 2, consumed: 3))
        #expect(stock.isOverspent == true)
        #expect(stock.overspentBy == 1)
    }

    @Test("Step state transitions from pending to in-progress to completed to reopened")
    func stepLifecycleTransitions() throws {
        let projectId = UUID()
        let stepId = UUID()
        let step = Step(
            id: stepId,
            projectId: projectId,
            orderIndex: 0,
            title: "Assemble Crankcase",
            instructions: "Clean surfaces first",
            photoAttachmentIDs: ["photo-1", "photo-2"]
        )

        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let t2 = Date(timeIntervalSince1970: 300)

        // 1. Initial state
        var proj = try AssemblyProjection(parts: [], steps: [step], events: [])
        #expect(proj.stepStatus(for: stepId) == .notStarted)

        // 2. Started
        proj = try AssemblyProjection(
            parts: [],
            steps: [step],
            events: [.stepStarted(id: UUID(), projectId: projectId, timestamp: t0, stepId: stepId)]
        )
        #expect(proj.stepStatus(for: stepId) == .inProgress)

        // 3. Completed
        proj = try AssemblyProjection(
            parts: [],
            steps: [step],
            events: [
                .stepStarted(id: UUID(), projectId: projectId, timestamp: t0, stepId: stepId),
                .stepCompleted(id: UUID(), projectId: projectId, timestamp: t1, stepId: stepId)
            ]
        )
        #expect(proj.stepStatus(for: stepId) == .completed)

        // 4. Reopened — preserves full audit history
        let reopenEvent = AssemblyEvent.stepReopened(
            id: UUID(),
            projectId: projectId,
            timestamp: t2,
            stepId: stepId,
            reason: "Bearing seated off-center"
        )
        proj = try AssemblyProjection(
            parts: [],
            steps: [step],
            events: [
                .stepStarted(id: UUID(), projectId: projectId, timestamp: t0, stepId: stepId),
                .stepCompleted(id: UUID(), projectId: projectId, timestamp: t1, stepId: stepId),
                reopenEvent
            ]
        )
        #expect(proj.stepStatus(for: stepId) == .reopened)
        let history = proj.stepEventHistory(for: stepId)
        #expect(history.count == 3)
        #expect(proj.stepReopenCount(for: stepId) == 1)
    }

    @Test("Event replay is strictly deterministic regardless of insertion order when sorted by timestamp")
    func deterministicReplay() throws {
        let projectId = UUID()
        let partId = UUID()
        let stepId = UUID()
        let part = Part(id: partId, projectId: projectId, name: "Screw", initialQuantity: .known(10))
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])

        let e1 = AssemblyEvent.partUsed(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 10), partId: partId, stepId: stepId, quantity: 2)
        let e2 = AssemblyEvent.partUsed(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 20), partId: partId, stepId: stepId, quantity: 3)
        let e3 = AssemblyEvent.stepStarted(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 5), stepId: stepId)

        let projA = try AssemblyProjection(parts: [part], steps: [step], events: [e1, e2, e3])
        let projB = try AssemblyProjection(parts: [part], steps: [step], events: [e3, e2, e1])

        let stockA = try #require(projA.partStock(for: partId))
        let stockB = try #require(projB.partStock(for: partId))
        #expect(stockA.consumed == stockB.consumed)
        #expect(stockA.remaining == stockB.remaining)
    }

    @Test("Negative starting quantities are rejected, not treated as stock")
    func negativeStartingQuantityRejected() {
        let part = Part(id: UUID(), projectId: UUID(), name: "Bolt", initialQuantity: .known(-1))
        #expect(throws: DomainError.invalidQuantity) {
            try AssemblyProjection(parts: [part], steps: [], events: [])
        }
    }

    @Test("Duplicate event IDs are rejected instead of consuming twice")
    func duplicateEventRejected() {
        let projectId = UUID(), partId = UUID(), stepId = UUID(), eventId = UUID()
        let part = Part(id: partId, projectId: projectId, name: "Bolt", initialQuantity: .known(4))
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let use = AssemblyEvent.partUsed(id: eventId, projectId: projectId, timestamp: Date(), partId: partId, stepId: stepId, quantity: 1)
        #expect(throws: DomainError.duplicateEvent) {
            try AssemblyProjection(parts: [part], steps: [step], events: [use, use])
        }
    }

    @Test("Consumption overflow is rejected instead of wrapping to negative stock")
    func consumptionOverflowRejected() throws {
        let projectId = UUID(), partId = UUID(), stepId = UUID()
        let part = Part(id: partId, projectId: projectId, name: "Bolt", initialQuantity: .known(Int.max))
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let uses: [AssemblyEvent] = [
            .partUsed(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 1), partId: partId, stepId: stepId, quantity: Int.max),
            .partUsed(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 2), partId: partId, stepId: stepId, quantity: 1)
        ]
        #expect(throws: DomainError.quantityOverflow) {
            try AssemblyProjection(parts: [part], steps: [step], events: uses)
        }
    }

    @Test("Malformed decoded event payload is rejected at the JSON boundary")
    func malformedEventRejected() throws {
        let event = AssemblyEvent.partUsed(id: UUID(), projectId: UUID(), timestamp: Date(), partId: UUID(), stepId: UUID(), quantity: 1)
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        json["quantity"] = -1
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AssemblyEvent.self, from: corrupt)
        }
    }

    @Test("Lifecycle events carrying a partId are rejected at the JSON boundary")
    func lifecycleWithPartIdRejected() throws {
        let event = AssemblyEvent.stepStarted(id: UUID(), projectId: UUID(), timestamp: Date(), stepId: UUID())
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        json["partId"] = UUID().uuidString
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AssemblyEvent.self, from: corrupt)
        }
    }

    @Test("Reopened events without a reason are rejected at the JSON boundary")
    func reopenedWithoutReasonRejected() throws {
        let event = AssemblyEvent.stepReopened(id: UUID(), projectId: UUID(), timestamp: Date(), stepId: UUID(), reason: "ok")
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
        json["reason"] = NSNull()
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AssemblyEvent.self, from: corrupt)
        }
    }

    @Test("Missing part is not reported as unknown stock")
    func missingPartDoesNotMasqueradeAsUnknown() throws {
        let projection = try AssemblyProjection(parts: [], steps: [], events: [])
        #expect(projection.partStock(for: UUID()) == nil)
    }

    @Test("Duplicate part IDs are rejected, not trapped by dictionary construction")
    func duplicatePartIDsRejected() {
        let projectId = UUID()
        let shared = UUID()
        let a = Part(id: shared, projectId: projectId, name: "Bolt", initialQuantity: .known(2))
        let b = Part(id: shared, projectId: projectId, name: "Nut", initialQuantity: .known(3))
        #expect(throws: DomainError.duplicateEntity) {
            try AssemblyProjection(parts: [a, b], steps: [], events: [])
        }
    }

    @Test("Duplicate step IDs cannot share one status")
    func duplicateStepIDsRejected() {
        let projectId = UUID()
        let shared = UUID()
        let a = Step(id: shared, projectId: projectId, orderIndex: 0, title: "A", instructions: "", photoAttachmentIDs: [])
        let b = Step(id: shared, projectId: projectId, orderIndex: 1, title: "B", instructions: "", photoAttachmentIDs: [])
        #expect(throws: DomainError.duplicateEntity) {
            try AssemblyProjection(parts: [], steps: [a, b], events: [])
        }
    }

    @Test("Events referencing entities from another project are rejected")
    func crossProjectEventsRejected() {
        let projectA = UUID(), projectB = UUID()
        let partId = UUID(), stepId = UUID()
        let part = Part(id: partId, projectId: projectA, name: "Bolt", initialQuantity: .known(4))
        let step = Step(id: stepId, projectId: projectA, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let foreign = AssemblyEvent.partUsed(
            id: UUID(), projectId: projectB, timestamp: Date(),
            partId: partId, stepId: stepId, quantity: 1
        )
        #expect(throws: DomainError.mixedProjects) {
            try AssemblyProjection(parts: [part], steps: [step], events: [foreign])
        }
    }

    @Test("Events referencing entities missing from the projection are rejected")
    func danglingReferencesRejected() {
        let projectId = UUID()
        let orphanPart = UUID()
        let step = Step(id: UUID(), projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let event = AssemblyEvent.partUsed(
            id: UUID(), projectId: projectId, timestamp: Date(),
            partId: orphanPart, stepId: step.id, quantity: 1
        )
        #expect(throws: DomainError.danglingReference) {
            try AssemblyProjection(parts: [], steps: [step], events: [event])
        }
    }

    @Test("Step ordering is deterministic when orderIndex ties")
    func stepOrderTiesAreDeterministic() throws {
        let projectId = UUID()
        let first = Step(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, projectId: projectId, orderIndex: 0, title: "A", instructions: "", photoAttachmentIDs: [])
        let second = Step(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, projectId: projectId, orderIndex: 0, title: "B", instructions: "", photoAttachmentIDs: [])

        let forward = try AssemblyProjection(parts: [], steps: [first, second], events: [])
        let reverse = try AssemblyProjection(parts: [], steps: [second, first], events: [])

        let forwardOrder = forward.stepStatuses().map(\.step.id)
        let reverseOrder = reverse.stepStatuses().map(\.step.id)
        #expect(forwardOrder == reverseOrder)
        #expect(forwardOrder == [first.id, second.id])
    }

    @Test("Non-finite event timestamps are rejected before sorting", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteTimestampRejected(seconds: Double) {
        let projectId = UUID(), stepId = UUID()
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let event = AssemblyEvent.stepStarted(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSinceReferenceDate: seconds), stepId: stepId)
        #expect(throws: (any Error).self) {
            try AssemblyProjection(parts: [], steps: [step], events: [event])
        }
    }

    @Test("Shuffled lifecycle replay preserves ordered history through reopen and resume")
    func shuffledLifecycleReplay() throws {
        let projectId = UUID(), stepId = UUID()
        let step = Step(id: stepId, projectId: projectId, orderIndex: 0, title: "S", instructions: "", photoAttachmentIDs: [])
        let ids = (1...5).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let events: [AssemblyEvent] = [
            .stepStarted(id: ids[0], projectId: projectId, timestamp: Date(timeIntervalSince1970: 10), stepId: stepId),
            .stepCompleted(id: ids[1], projectId: projectId, timestamp: Date(timeIntervalSince1970: 20), stepId: stepId),
            .stepReopened(id: ids[2], projectId: projectId, timestamp: Date(timeIntervalSince1970: 20), stepId: stepId, reason: "Check fit"),
            .stepStarted(id: ids[3], projectId: projectId, timestamp: Date(timeIntervalSince1970: 30), stepId: stepId),
            .stepCompleted(id: ids[4], projectId: projectId, timestamp: Date(timeIntervalSince1970: 40), stepId: stepId)
        ]
        for count in 1...events.count {
            let history = Array(events.prefix(count))
            let projection = try AssemblyProjection(parts: [], steps: [step], events: Array(history.reversed()))
            #expect(projection.stepEventHistory(for: stepId) == history)
            #expect(projection.stepStatus(for: stepId) == [.inProgress, .completed, .reopened, .inProgress, .completed][count - 1])
            #expect(projection.stepReopenCount(for: stepId) == (count >= 3 ? 1 : 0))
        }
    }

    @Test("Empty and blank reopen reasons are rejected on decode", arguments: ["", "   ", "\t", "\n"])
    func blankReopenReasonRejected(reason: String) throws {
        let event = AssemblyEvent.stepReopened(id: UUID(), projectId: UUID(), timestamp: Date(), stepId: UUID(), reason: "Check fit")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json["reason"] = reason
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AssemblyEvent.self, from: data)
        }
    }

    @Test("Event JSON serialization round-trips losslessly")
    func eventSerializationRoundTrip() throws {
        let projectId = UUID()
        let partId = UUID()
        let stepId = UUID()

        let original: [AssemblyEvent] = [
            .stepStarted(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 100), stepId: stepId),
            .partUsed(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 120), partId: partId, stepId: stepId, quantity: 4),
            .stepCompleted(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 150), stepId: stepId),
            .stepReopened(id: UUID(), projectId: projectId, timestamp: Date(timeIntervalSince1970: 180), stepId: stepId, reason: "Check seal")
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AssemblyEvent].self, from: data)

        #expect(decoded.count == original.count)
        for (orig, dec) in zip(original, decoded) {
            #expect(orig.id == dec.id)
            #expect(orig.projectId == dec.projectId)
            #expect(orig.kind == dec.kind)
        }
    }
}
