import Foundation

/// User-initiated local backup. Photo bytes live in the JSON as base64 Data;
/// no file paths from imported data are ever interpreted as filesystem paths.
public enum WorkspaceTransfer {
    public enum TransferError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidBackup
        case changedSincePreview
    }

    public struct Preview {
        public let data: Data
        public let projectCount: Int
        public let photoCount: Int
        public let conflictingTitles: [String]
        fileprivate let existing: [LocalProjectStore.Record]
    }

    private struct Photo: Codable {
        let id: UUID
        let projectId: UUID
        let bytes: Data
    }

    private struct Backup: Codable {
        let version: Int
        let records: [LocalProjectStore.Record]
        let photos: [Photo]
    }

    private struct Header: Decodable { let version: Int }

    public static func backup(from store: LocalProjectStore) throws -> Data {
        let records = store.allProjects()
        var photos: [Photo] = []
        for record in records {
            for step in record.steps {
                for id in step.photoAttachmentIDs {
                    guard let uuid = UUID(uuidString: id) else { throw TransferError.invalidBackup }
                    photos.append(Photo(id: uuid, projectId: record.project.id,
                                        bytes: try store.photo(id: uuid, projectId: record.project.id)))
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Backup(version: 1, records: records, photos: photos))
    }

    public static func preview(_ data: Data, in store: LocalProjectStore) throws -> Preview {
        let backup = try decode(data)
        let current = store.allProjects()
        let ids = Set(current.map { $0.project.id })
        return Preview(data: data, projectCount: backup.records.count,
                       photoCount: backup.photos.count,
                       conflictingTitles: backup.records.filter { ids.contains($0.project.id) }
                           .map { $0.project.title }, existing: current)
    }

    /// Full replacement only after explicit user confirmation. No partial merge.
    /// Restore stages complete records and photos before moving live bytes;
    /// rollback restores old directory if final move fails.
    public static func restore(_ preview: Preview, into store: LocalProjectStore) throws {
        guard store.allProjects() == preview.existing else { throw TransferError.changedSincePreview }
        let backup = try decode(preview.data)
        try store.replaceAll(backup.records,
                             photos: backup.photos.map { ($0.projectId, $0.id, $0.bytes) })
    }

    private static func decode(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).version
        guard version == 1 else { throw TransferError.unsupportedVersion(version) }
        let backup = try decoder.decode(Backup.self, from: data)
        try LocalProjectStore.validate(backup.records)
        var expected: Set<String> = []
        for record in backup.records {
            for step in record.steps {
                for id in step.photoAttachmentIDs {
                    expected.insert(record.project.id.uuidString + "/" + id)
                }
            }
        }
        var found: Set<String> = []
        for photo in backup.photos {
            let key = photo.projectId.uuidString + "/" + photo.id.uuidString
            guard !photo.bytes.isEmpty, expected.contains(key), found.insert(key).inserted else {
                throw TransferError.invalidBackup
            }
        }
        guard found == expected else { throw TransferError.invalidBackup }
        return backup
    }

    public static func csv(from store: LocalProjectStore) throws -> Data {
        func field(_ value: String) -> String {
            // RFC 4180: quote only when the value contains a separator,
            // quote, or line break.
            if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        var rows = ["project,kind,name,status,initial,used,remaining"]
        for record in store.allProjects() {
            let projection = try AssemblyProjection(parts: record.parts, steps: record.steps, events: record.events)
            for step in record.steps.sorted(by: { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }) {
                let status: String
                switch projection.stepStatus(for: step.id) {
                case .notStarted: status = "not started"
                case .inProgress: status = "in progress"
                case .completed: status = "completed"
                case .reopened: status = "reopened"
                }
                rows.append([record.project.title, "step", step.title, status, "", "", ""].map(field).joined(separator: ","))
            }
            for part in record.parts {
                guard let stock = projection.partStock(for: part.id) else { throw TransferError.invalidBackup }
                let initial: String
                switch part.initialQuantity {
                case .unknown: initial = "unknown"
                case let .known(value): initial = String(value)
                }
                let remaining: String
                switch stock.remaining {
                case .unknown: remaining = "unknown"
                case let .known(value): remaining = String(value)
                case .conflict: remaining = "conflict"
                }
                rows.append([record.project.title, "part", part.name,
                             stock.isOverspent ? "count conflict" : "", initial,
                             String(stock.consumed), remaining].map(field).joined(separator: ","))
            }
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
