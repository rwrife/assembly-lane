import Foundation

/// Issue #4 session operations: the explicit user actions over one project's
/// record (create/edit, step lifecycle, part consumption). Every mutation is
/// an append to the event ledger plus entity updates, persisted through
/// `LocalProjectStore`, so an interrupted session resumes from disk.
///
/// Concurrency follows the store contract: one serial caller (main actor).
public enum SessionError: Error, Equatable {
    case unknownProject
    case unknownStep
    case unknownPart
    case emptyTitle
    case emptyReopenReason
    case invalidQuantity
}

public struct ProjectSession {
    private let store: LocalProjectStore

    public init(store: LocalProjectStore) {
        self.store = store
    }

    public func record(projectId: UUID) throws -> LocalProjectStore.Record {
        guard let record = store.allProjects().first(where: { $0.project.id == projectId }) else {
            throw SessionError.unknownProject
        }
        return record
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(title: String, notes: String = "", at date: Date = Date()) throws -> UUID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyTitle }
        let id = UUID()
        try store.save(LocalProjectStore.Record(
            project: Project(
                id: id, title: trimmed,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: date, updatedAt: date
            )
        ))
        return id
    }

    public func updateProject(projectId: UUID, title: String, notes: String, at date: Date = Date()) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyTitle }
        var record = try record(projectId: projectId)
        record.project.title = trimmed
        record.project.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.project.updatedAt = date
        try store.save(record)
    }

    // MARK: - Steps and parts (entities)

    @discardableResult
    public func addStep(
        projectId: UUID, title: String, instructions: String = "", at date: Date = Date()
    ) throws -> UUID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyTitle }
        var record = try record(projectId: projectId)
        let (nextIndex, overflow) = (record.steps.map(\.orderIndex).max() ?? -1).addingReportingOverflow(1)
        guard !overflow else { throw SessionError.invalidQuantity }
        record.steps.append(Step(
            id: UUID(), projectId: projectId, orderIndex: nextIndex,
            title: trimmed,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            photoAttachmentIDs: []
        ))
        record.project.updatedAt = date
        try store.save(record)
        return record.steps[record.steps.count - 1].id
    }

    @discardableResult
    public func addPart(
        projectId: UUID, name: String, initialQuantity: PartQuantity, at date: Date = Date()
    ) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyTitle }
        if case let .known(value) = initialQuantity, value < 0 { throw SessionError.invalidQuantity }
        var record = try record(projectId: projectId)
        let id = UUID()
        record.parts.append(Part(id: id, projectId: projectId, name: trimmed, initialQuantity: initialQuantity))
        record.project.updatedAt = date
        try store.save(record)
        return id
    }

    // MARK: - Explicit step lifecycle (append-only events)

    public func startStep(projectId: UUID, stepId: UUID, at date: Date = Date()) throws {
        try append(
            .stepStarted(id: UUID(), projectId: projectId, timestamp: date, stepId: requireStep(projectId: projectId, stepId: stepId)),
            projectId: projectId, at: date
        )
    }

    public func completeStep(projectId: UUID, stepId: UUID, at date: Date = Date()) throws {
        try append(
            .stepCompleted(id: UUID(), projectId: projectId, timestamp: date, stepId: requireStep(projectId: projectId, stepId: stepId)),
            projectId: projectId, at: date
        )
    }

    public func reopenStep(projectId: UUID, stepId: UUID, reason: String, at date: Date = Date()) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionError.emptyReopenReason }
        try append(
            .stepReopened(id: UUID(), projectId: projectId, timestamp: date, stepId: requireStep(projectId: projectId, stepId: stepId), reason: trimmed),
            projectId: projectId, at: date
        )
    }

    public func consumePart(
        projectId: UUID, partId: UUID, stepId: UUID, quantity: Int, at date: Date = Date()
    ) throws {
        guard quantity > 0 else { throw SessionError.invalidQuantity }
        let step = try requireStep(projectId: projectId, stepId: stepId)
        var record = try record(projectId: projectId)
        guard record.parts.contains(where: { $0.id == partId }) else { throw SessionError.unknownPart }
        record.events.append(.partUsed(
            id: UUID(), projectId: projectId, timestamp: date, partId: partId, stepId: step, quantity: quantity
        ))
        record.project.updatedAt = date
        try store.save(record)
    }

    // MARK: - Derived state

    public func projection(for record: LocalProjectStore.Record) throws -> AssemblyProjection {
        try AssemblyProjection(parts: record.parts, steps: record.steps, events: record.events)
    }

    /// The step consumption should be attributed to: the step most recently
    /// started or reopened that is not completed. `nil` when none is active,
    /// which is how the UI blocks implicit consumption without an open step.
    public func activeStep(in record: LocalProjectStore.Record) throws -> Step? {
        let projection = try projection(for: record)
        let openStatuses: [StepStatus] = [.inProgress, .reopened]
        let openSteps = projection.stepStatuses().filter { openStatuses.contains($0.status) }.map(\.step)
        guard !openSteps.isEmpty else { return nil }
        // Latest lifecycle event wins; deterministic tie-break by UUID string.
        return openSteps.max { lhs, rhs in
            (lastLifecycleTimestamp(lhs.id, in: record), lhs.id.uuidString)
                < (lastLifecycleTimestamp(rhs.id, in: record), rhs.id.uuidString)
        }
    }

    private func lastLifecycleTimestamp(_ stepId: UUID, in record: LocalProjectStore.Record) -> Date {
        record.events
            .filter { $0.stepId == stepId && $0.kind != .partUsed }
            .map(\.timestamp)
            .max() ?? .distantPast
    }

    // MARK: - Internals

    private func requireStep(projectId: UUID, stepId: UUID) throws -> UUID {
        let record = try record(projectId: projectId)
        guard record.steps.contains(where: { $0.id == stepId }) else { throw SessionError.unknownStep }
        return stepId
    }

    private func append(_ event: AssemblyEvent, projectId: UUID, at date: Date) throws {
        var record = try record(projectId: projectId)
        record.events.append(event)
        record.project.updatedAt = date
        try store.save(record)
    }
}
