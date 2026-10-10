import Foundation

/// Issue #2 domain layer: Project / Part / Step entities, immutable events
/// and the deterministic projection engine.
///
/// Design rules (binding):
/// - Unknown starting quantities stay `.unknown` forever; consumption is
///   tracked but never fabricates a remaining count.
/// - Overspend is a visible `.conflict`, never negative stock.
/// - Projection is deterministic: events and steps are ordered
///   independently of caller insertion order.
/// - Construction of a projection validates every input, because decoded
///   JSON is an untrusted path into this type.
/// - Foundation only: no clock, no I/O, no network.

// MARK: - Errors

public enum DomainError: Error, Equatable, Sendable {
    case invalidQuantity
    case duplicateEvent
    case duplicateEntity
    case mixedProjects
    case danglingReference
    case quantityOverflow
    case invalidTimestamp
}

// MARK: - Quantities

/// A part's starting quantity as recorded by the user.
public enum PartQuantity: Equatable, Hashable, Codable, Sendable {
    /// The user never entered a count. Consumption is tracked but no
    /// remaining count may ever be derived from this.
    case unknown
    /// An explicit non-negative count.
    case known(Int)
}

/// Derived remaining stock. Never negative: overspend is a conflict.
public enum RemainingCount: Equatable, Hashable, Sendable {
    case unknown
    case known(Int)
    /// Consumed more than the recorded expected count. Both numbers are
    /// surfaced so the UI can show the exact discrepancy.
    case conflict(expected: Int, consumed: Int)
}

/// Derived consumption state for one part.
public struct PartStock: Equatable, Sendable {
    public let consumed: Int
    public let remaining: RemainingCount

    public var isOverspent: Bool {
        if case .conflict = remaining { return true }
        return false
    }

    /// How many units beyond the expected count were consumed, when overspent.
    public var overspentBy: Int? {
        if case let .conflict(expected, consumed) = remaining { return consumed - expected }
        return nil
    }
}

// MARK: - Entities

public struct Project: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var notes: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        notes: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Part: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectId: UUID
    public var name: String
    public var initialQuantity: PartQuantity

    public init(id: UUID, projectId: UUID, name: String, initialQuantity: PartQuantity) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.initialQuantity = initialQuantity
    }
}

public struct Step: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectId: UUID
    public var orderIndex: Int
    public var title: String
    public var instructions: String
    public var photoAttachmentIDs: [String]

    public init(
        id: UUID,
        projectId: UUID,
        orderIndex: Int,
        title: String,
        instructions: String,
        photoAttachmentIDs: [String]
    ) {
        self.id = id
        self.projectId = projectId
        self.orderIndex = orderIndex
        self.title = title
        self.instructions = instructions
        self.photoAttachmentIDs = photoAttachmentIDs
    }
}

// MARK: - Events

public enum EventKind: String, Codable, Sendable {
    case stepStarted
    case stepCompleted
    case stepReopened
    case partUsed
}

/// One immutable fact about the assembly. Events are append-only: the
/// projection replays them, nothing ever rewrites history.
///
/// The static factories make a mismatched payload unconstructable in-process;
/// `init(from:)` is the only other entry point and re-validates the exact
/// same payload contract, so decoded JSON cannot smuggle an event the
/// factories would have refused.
public struct AssemblyEvent: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectId: UUID
    public let timestamp: Date
    public let kind: EventKind
    public let stepId: UUID
    public let partId: UUID?
    public let quantity: Int?
    public let reason: String?

    private init(
        id: UUID,
        projectId: UUID,
        timestamp: Date,
        kind: EventKind,
        stepId: UUID,
        partId: UUID? = nil,
        quantity: Int? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.timestamp = timestamp
        self.kind = kind
        self.stepId = stepId
        self.partId = partId
        self.quantity = quantity
        self.reason = reason
    }

    public static func stepStarted(
        id: UUID, projectId: UUID, timestamp: Date, stepId: UUID
    ) -> AssemblyEvent {
        Self(id: id, projectId: projectId, timestamp: timestamp, kind: .stepStarted, stepId: stepId)
    }

    public static func stepCompleted(
        id: UUID, projectId: UUID, timestamp: Date, stepId: UUID
    ) -> AssemblyEvent {
        Self(id: id, projectId: projectId, timestamp: timestamp, kind: .stepCompleted, stepId: stepId)
    }

    public static func stepReopened(
        id: UUID, projectId: UUID, timestamp: Date, stepId: UUID, reason: String
    ) -> AssemblyEvent {
        precondition(
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "stepReopened reason must not be empty"
        )
        return Self(
            id: id, projectId: projectId, timestamp: timestamp, kind: .stepReopened,
            stepId: stepId, reason: reason
        )
    }

    public static func partUsed(
        id: UUID, projectId: UUID, timestamp: Date, partId: UUID, stepId: UUID, quantity: Int
    ) -> AssemblyEvent {
        // In-process invariant: consuming zero or fewer units is meaningless.
        precondition(quantity > 0, "partUsed quantity must be positive")
        return Self(
            id: id, projectId: projectId, timestamp: timestamp, kind: .partUsed,
            stepId: stepId, partId: partId, quantity: quantity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, timestamp, kind, stepId, partId, quantity, reason
    }

    /// Throws `DecodingError.dataCorrupted` for payloads the factories reject.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(EventKind.self, forKey: .kind)
        let partId = try container.decodeIfPresent(UUID.self, forKey: .partId)
        let quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
        let reason = try container.decodeIfPresent(String.self, forKey: .reason)

        func reject(_ message: String) throws -> Never {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: message
                )
            )
        }

        // Full payload-shape contract per kind: exactly what the factories
        // can construct — nothing more, nothing less.
        switch kind {
        case .partUsed:
            guard partId != nil else { try reject("partUsed requires partId") }
            guard let quantity, quantity > 0 else {
                try reject("partUsed requires a positive quantity")
            }
            guard reason == nil else { try reject("partUsed must not carry a reason") }
        case .stepStarted, .stepCompleted:
            guard partId == nil else { try reject("\(kind.rawValue) must not carry a partId") }
            guard quantity == nil else { try reject("\(kind.rawValue) must not carry a quantity") }
            guard reason == nil else { try reject("\(kind.rawValue) must not carry a reason") }
        case .stepReopened:
            guard partId == nil else { try reject("stepReopened must not carry a partId") }
            guard quantity == nil else { try reject("stepReopened must not carry a quantity") }
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try reject("stepReopened requires a non-empty reason")
            }
        }

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            projectId: try container.decode(UUID.self, forKey: .projectId),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            kind: kind,
            stepId: try container.decode(UUID.self, forKey: .stepId),
            partId: partId,
            quantity: quantity,
            reason: reason
        )
    }
}

// MARK: - Projection

public enum StepStatus: Equatable, Sendable {
    case notStarted
    case inProgress
    case completed
    /// Completed once and then explicitly reopened; history is preserved.
    case reopened
}

/// Deterministic fold of the event log into derived state.
public struct AssemblyProjection: Sendable {
    private let partsByID: [UUID: Part]
    private let steps: [Step]
    private let orderedEvents: [AssemblyEvent]

    /// Validating factory. Every input that arrived from disk or a decoded
    /// backup enters here, so bad data fails loudly instead of projecting
    /// a plausible-but-wrong state.
    public init(parts: [Part], steps: [Step], events: [AssemblyEvent]) throws {
        guard events.allSatisfy({ $0.timestamp.timeIntervalSinceReferenceDate.isFinite }) else {
            throw DomainError.invalidTimestamp
        }
        for part in parts {
            if case let .known(value) = part.initialQuantity, value < 0 {
                throw DomainError.invalidQuantity
            }
        }

        // Entity uniqueness: duplicate part/step IDs must throw, never
        // trap inside Dictionary(uniqueKeysWithValues:) nor silently share
        // one derived status between two entities.
        var seenPartIDs: Set<UUID> = []
        for part in parts where !seenPartIDs.insert(part.id).inserted {
            throw DomainError.duplicateEntity
        }
        var seenStepIDs: Set<UUID> = []
        for step in steps where !seenStepIDs.insert(step.id).inserted {
            throw DomainError.duplicateEntity
        }

        var seenEventIDs: Set<UUID> = []
        for event in events where !seenEventIDs.insert(event.id).inserted {
            throw DomainError.duplicateEvent
        }

        // Project ownership: one projection folds exactly one project's
        // ledger. A foreign-project part/step/event must never move
        // another project's stock or step status.
        let projectIDs = Set(
            parts.map(\.projectId) + steps.map(\.projectId) + events.map(\.projectId)
        )
        if projectIDs.count > 1 {
            throw DomainError.mixedProjects
        }

        // Reference integrity: every event must address entities that
        // exist in this projection; dangling references would otherwise
        // project silent wrong state (stock or status for entities the
        // caller never provided).
        for event in events where !seenStepIDs.contains(event.stepId) {
            throw DomainError.danglingReference
        }
        for event in events where event.kind == .partUsed {
            guard let partId = event.partId, seenPartIDs.contains(partId) else {
                throw DomainError.danglingReference
            }
        }

        // Absurd decoded quantities must not wrap into negative stock:
        // validate each part's total consumption at the trust boundary.
        var totals: [UUID: Int] = [:]
        for event in events where event.kind == .partUsed {
            guard let partId = event.partId else { continue }
            let (sum, overflow) = (totals[partId] ?? 0).addingReportingOverflow(event.quantity ?? 0)
            if overflow { throw DomainError.quantityOverflow }
            totals[partId] = sum
        }

        self.partsByID = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0) })

        // Deterministic step order: orderIndex primary, id tie-breaker, so
        // equal orderIndex never leaves output dependent on insertion order.
        self.steps = steps.sorted {
            ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
        }

        // Deterministic replay order independent of insertion order.
        // (ponytail: same-timestamp ties break by UUID string. Upgrade path:
        // a monotonic per-project sequence number if logs are ever merged.)
        self.orderedEvents = events.sorted {
            ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString)
        }
    }

    /// Derived stock for a known part; `nil` when the projection has no
    /// such part — callers must not mistake an unknown ID for the
    /// `.unknown` stock of a real part.
    public func partStock(for partId: UUID) -> PartStock? {
        guard let part = partsByID[partId] else { return nil }
        var consumed = 0
        for event in orderedEvents where event.kind == .partUsed && event.partId == partId {
            // Overflow was already rejected in init's per-part validation.
            consumed += event.quantity ?? 0
        }
        switch part.initialQuantity {
        case .unknown:
            // Unknown stays unknown — consumption is tracked, never invented.
            return PartStock(consumed: consumed, remaining: .unknown)
        case let .known(expected):
            if consumed > expected {
                return PartStock(
                    consumed: consumed,
                    remaining: .conflict(expected: expected, consumed: consumed)
                )
            }
            return PartStock(consumed: consumed, remaining: .known(expected - consumed))
        }
    }

    public func stepStatus(for stepId: UUID) -> StepStatus {
        var status: StepStatus = .notStarted
        for event in orderedEvents where event.stepId == stepId {
            switch event.kind {
            case .stepStarted: status = .inProgress
            case .stepCompleted: status = .completed
            case .stepReopened: status = .reopened
            case .partUsed: break
            }
        }
        return status
    }

    /// Derived status for every step, in step order — the shape #4's step
    /// cards and #6's layout seam consume.
    public func stepStatuses() -> [(step: Step, status: StepStatus)] {
        steps.map { (step: $0, status: stepStatus(for: $0.id)) }
    }

    /// Full audit history for one step (lifecycle events, replay order).
    public func stepEventHistory(for stepId: UUID) -> [AssemblyEvent] {
        orderedEvents.filter { $0.stepId == stepId && $0.kind != .partUsed }
    }

    public func stepReopenCount(for stepId: UUID) -> Int {
        orderedEvents.filter { $0.stepId == stepId && $0.kind == .stepReopened }.count
    }
}
