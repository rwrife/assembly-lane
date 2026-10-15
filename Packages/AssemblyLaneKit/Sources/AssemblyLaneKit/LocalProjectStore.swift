import Foundation

/// Offline, app-container-only store. Each project owns its attachment IDs.
///
/// Concurrency contract: all methods assume one serial caller (normally the
/// main actor); there is no internal locking. `@unchecked Sendable` exists so
/// SwiftUI views can hand the reference to `Task`s without fighting strict
/// concurrency while that contract holds.
/// ponytail: ceiling = concurrent writers race on the JSON index. Upgrade
/// path: convert to an `actor` with async APIs when a second writer appears.
public final class LocalProjectStore: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var project: Project
        public var parts: [Part]
        public var steps: [Step]
        public var events: [AssemblyEvent]

        public init(project: Project, parts: [Part] = [], steps: [Step] = [], events: [AssemblyEvent] = []) {
            self.project = project
            self.parts = parts
            self.steps = steps
            self.events = events
        }
    }

    public enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidDocument
        case unknownProject
        case unknownAttachment
        case invalidImage
    }

    private struct Document: Codable {
        var version: Int
        var records: [Record]
    }

    private let root: URL
    private let index: URL
    private var records: [Record]

    /// Caller supplies Application Support URL, never Documents/shared storage.
    /// Corrupt or future-version data throws; existing bytes stay untouched.
    public init(root: URL) throws {
        self.root = root
        index = root.appendingPathComponent("projects.json", isDirectory: false)
        let fs = FileManager.default
        try fs.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
        try fs.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
        if fs.fileExists(atPath: index.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: index))
            guard document.version <= 2, document.version >= 1 else {
                throw StoreError.unsupportedVersion(document.version)
            }
            try Self.validate(document.records)
            records = document.records
            // v1 lacked attachment IDs; Step's v1 decoder supplies []. Upgrade only after validation.
            if document.version == 1 { try persist(document.records) }
        } else {
            records = []
        }
    }

    public func allProjects() -> [Record] { records }

    public func save(_ record: Record) throws {
        var updated = records
        if let position = updated.firstIndex(where: { $0.project.id == record.project.id }) {
            updated[position] = record
        } else {
            updated.append(record)
        }
        try Self.validate(updated)
        try persist(updated)
        records = updated
    }

    public func photo(id: UUID, projectId: UUID) throws -> Data {
        guard let record = records.first(where: { $0.project.id == projectId }) else {
            throw StoreError.unknownProject
        }
        guard record.steps.contains(where: { $0.photoAttachmentIDs.contains(id.uuidString) }) else {
            throw StoreError.unknownAttachment
        }
        return try Data(contentsOf: photoURL(id: id, projectId: projectId))
    }

    /// Bytes come only from user-selected photo input. No library enumeration.
    @discardableResult
    public func attachPhoto(_ bytes: Data, projectId: UUID, stepId: UUID) throws -> UUID {
        guard !bytes.isEmpty else { throw StoreError.invalidImage }
        guard let recordIndex = records.firstIndex(where: { $0.project.id == projectId }),
              let stepIndex = records[recordIndex].steps.firstIndex(where: { $0.id == stepId }) else {
            throw StoreError.unknownProject
        }
        let id = UUID()
        let directory = root.appendingPathComponent(projectId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = photoURL(id: id, projectId: projectId)
        try bytes.write(to: file, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        #endif
        var record = records[recordIndex]
        record.steps[stepIndex].photoAttachmentIDs.append(id.uuidString)
        do {
            try save(record)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return id
    }

    public func deletePhoto(id: UUID, projectId: UUID) throws {
        guard let recordIndex = records.firstIndex(where: { $0.project.id == projectId }) else {
            throw StoreError.unknownProject
        }
        var record = records[recordIndex]
        guard record.steps.contains(where: { $0.photoAttachmentIDs.contains(id.uuidString) }) else {
            throw StoreError.unknownAttachment
        }
        for index in record.steps.indices {
            record.steps[index].photoAttachmentIDs.removeAll { $0 == id.uuidString }
        }
        // Remove file first; on index write failure, rollback from retained bytes.
        let file = photoURL(id: id, projectId: projectId)
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        do { try save(record) }
        catch {
            try bytes.write(to: file, options: .atomic)
            throw error
        }
    }

    private func photoURL(id: UUID, projectId: UUID) -> URL {
        root.appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(id.uuidString + ".photo", isDirectory: false)
    }

    private func persist(_ value: [Record]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Document(version: 2, records: value)).write(to: index, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: index.path)
        #endif
    }

    /// Stage a complete workspace on the same volume, then swap directories.
    /// A failed stage leaves live bytes untouched. A failed final move rolls
    /// the old root back; never silently discard its only copy.
    public func replaceAll(
        _ newRecords: [Record], photos: [(projectId: UUID, id: UUID, bytes: Data)]
    ) throws {
        try Self.validate(newRecords)
        let fm = FileManager.default
        let token = UUID().uuidString
        let staging = root.appendingPathExtension("restore-\(token)")
        let oldRoot = root.appendingPathExtension("previous-\(token)")
        defer { try? fm.removeItem(at: staging) }
        let temporary = try LocalProjectStore(root: staging)
        for record in newRecords { try temporary.save(record) }
        for photo in photos {
            guard !photo.bytes.isEmpty else { throw StoreError.invalidImage }
            let directory = staging.appendingPathComponent(photo.projectId.uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(photo.id.uuidString + ".photo")
            try photo.bytes.write(to: file, options: .atomic)
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            #endif
        }
        try fm.moveItem(at: root, to: oldRoot)
        do { try fm.moveItem(at: staging, to: root) }
        catch {
            try fm.moveItem(at: oldRoot, to: root)
            throw error
        }
        records = newRecords
        // A failed cleanup is recoverable; live records are already durable.
        try? fm.removeItem(at: oldRoot)
    }

    static func validate(_ value: [Record]) throws {
        var projectIDs: Set<UUID> = []
        var attachmentIDs: Set<String> = []
        for record in value {
            let id = record.project.id
            guard projectIDs.insert(id).inserted,
                  record.parts.allSatisfy({ $0.projectId == id }),
                  record.steps.allSatisfy({ $0.projectId == id }),
                  record.events.allSatisfy({ $0.projectId == id }) else {
                throw StoreError.invalidDocument
            }
            for step in record.steps {
                for attachment in step.photoAttachmentIDs {
                    guard let uuid = UUID(uuidString: attachment), uuid.uuidString == attachment,
                          attachmentIDs.insert(attachment).inserted else {
                        throw StoreError.invalidDocument
                    }
                }
            }
            _ = try AssemblyProjection(parts: record.parts, steps: record.steps, events: record.events)
        }
    }
}
