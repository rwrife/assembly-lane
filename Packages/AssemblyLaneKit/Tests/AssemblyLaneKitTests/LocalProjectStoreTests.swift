import Foundation
import Testing

@testable import AssemblyLaneKit

/// Issue #3: versioned migration, relaunch durability, project-scoped
/// attachments, and corrupt-file handling for `LocalProjectStore`.
/// All runs target a fresh temporary directory; nothing touches the network.
@Suite("LocalProjectStore persistence")
struct LocalProjectStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblyLaneStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleRecord(projectId: UUID = UUID()) throws -> LocalProjectStore.Record {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(id: projectId, title: "Bookshelf", notes: "", createdAt: now, updatedAt: now)
        let part = Part(id: UUID(), projectId: projectId, name: "Cam bolts", initialQuantity: .known(12))
        let step = Step(
            id: UUID(), projectId: projectId, orderIndex: 0, title: "Frame",
            instructions: "", photoAttachmentIDs: []
        )
        let event = AssemblyEvent.stepStarted(
            id: UUID(), projectId: projectId, timestamp: now, stepId: step.id
        )
        return LocalProjectStore.Record(project: project, parts: [part], steps: [step], events: [event])
    }

    @Test("save then reopen in a new store instance returns identical records")
    func relaunchDurability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try sampleRecord()

        let first = try LocalProjectStore(root: root)
        try first.save(record)
        #expect(first.allProjects() == [record])

        let relaunched = try LocalProjectStore(root: root)
        #expect(relaunched.allProjects() == [record])
    }

    @Test("saving the same project id replaces the record instead of duplicating")
    func saveReplacesInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try sampleRecord()

        let store = try LocalProjectStore(root: root)
        try store.save(record)
        record.project.title = "Bookshelf v2"
        try store.save(record)

        let reopened = try LocalProjectStore(root: root)
        #expect(reopened.allProjects().count == 1)
        #expect(reopened.allProjects().first?.project.title == "Bookshelf v2")
    }

    @Test("v1 documents without photoAttachmentIDs decode and migrate to v2")
    func versionedMigration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try sampleRecord()

        // Hand-craft a v1 document: no photoAttachmentIDs key anywhere.
        struct V1Step: Codable {
            var id: UUID
            var projectId: UUID
            var orderIndex: Int
            var title: String
            var instructions: String
        }
        struct V1Record: Codable {
            var project: Project
            var parts: [Part]
            var steps: [V1Step]
            var events: [AssemblyEvent]
        }
        struct V1Document: Codable { var version: Int; var records: [V1Record] }
        let v1Step = V1Step(
            id: record.steps[0].id,
            projectId: record.steps[0].projectId,
            orderIndex: record.steps[0].orderIndex,
            title: record.steps[0].title,
            instructions: record.steps[0].instructions
        )
        let v1 = V1Document(
            version: 1,
            records: [V1Record(
                project: record.project, parts: record.parts,
                steps: [v1Step], events: record.events
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let v1Data = try encoder.encode(v1)
        // Prove the v1 payload really lacks the v2 key.
        let v1Text = String(decoding: v1Data, as: UTF8.self)
        #expect(!v1Text.contains("photoAttachmentIDs"))
        try v1Data.write(to: root.appendingPathComponent("projects.json"))

        let migrated = try LocalProjectStore(root: root)
        #expect(migrated.allProjects() == [record])
        #expect(migrated.allProjects().first?.steps.first?.photoAttachmentIDs == [])

        // The store rewrote itself as v2 on load.
        let stored = try Data(contentsOf: root.appendingPathComponent("projects.json"))
        let text = String(decoding: stored, as: UTF8.self)
        #expect(text.contains("\"version\":2"))
        #expect(text.contains("photoAttachmentIDs"))
    }

    @Test("a future document version throws and leaves the file untouched")
    func futureVersionRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(#"{"version":99,"records":[]}"#.utf8)
        let url = root.appendingPathComponent("projects.json")
        try payload.write(to: url)

        #expect(throws: LocalProjectStore.StoreError.unsupportedVersion(99)) {
            _ = try LocalProjectStore(root: root)
        }
        // Rejected bytes preserved for recovery, never silently overwritten.
        let preserved = try Data(contentsOf: url)
        #expect(preserved == payload)
    }

    @Test("corrupt JSON and structurally invalid documents throw instead of wiping")
    func corruptFileHandling() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("projects.json")

        let junk = Data("not json at all".utf8)
        try junk.write(to: url)
        #expect(throws: (any Error).self) { _ = try LocalProjectStore(root: root) }
        #expect(try Data(contentsOf: url) == junk)

        // Version 2 with a step that lies about its project ownership.
        let record = try sampleRecord()
        let recordData = try JSONEncoder().encode(record)
        var recordJSON = try JSONSerialization.jsonObject(with: recordData) as! [String: Any]
        var stepsJSON = recordJSON["steps"] as! [[String: Any]]
        stepsJSON[0]["projectId"] = UUID().uuidString
        recordJSON["steps"] = stepsJSON
        let document: [String: Any] = ["version": 2, "records": [recordJSON]]
        let tampered = try JSONSerialization.data(withJSONObject: document)
        try tampered.write(to: url)
        #expect(throws: LocalProjectStore.StoreError.invalidDocument) {
            _ = try LocalProjectStore(root: root)
        }
    }

    @Test("empty store round-trips and stays empty across relaunch")
    func emptyStoreRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalProjectStore(root: root)
        #expect(store.allProjects().isEmpty)
        let reopened = try LocalProjectStore(root: root)
        #expect(reopened.allProjects().isEmpty)
    }

    @Test("photos attach, read back byte-identical, and scope to one project")
    func photoAttachAndScope() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try sampleRecord()
        let other = try sampleRecord()
        let store = try LocalProjectStore(root: root)
        try store.save(record)
        try store.save(other)

        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let photoID = try store.attachPhoto(bytes, projectId: record.project.id, stepId: record.steps[0].id)
        #expect(try store.photo(id: photoID, projectId: record.project.id) == bytes)

        // The other project cannot address this attachment at all.
        #expect(throws: LocalProjectStore.StoreError.unknownAttachment) {
            _ = try store.photo(id: photoID, projectId: other.project.id)
        }
        // Empty payloads are refused outright.
        #expect(throws: LocalProjectStore.StoreError.invalidImage) {
            _ = try store.attachPhoto(Data(), projectId: record.project.id, stepId: record.steps[0].id)
        }
    }

    @Test("attachment IDs survive relaunch and deletion removes file plus ID")
    func photoDeletionAndDurability() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try sampleRecord()
        let store = try LocalProjectStore(root: root)
        try store.save(record)
        let bytes = Data("photo-bytes".utf8)
        let photoID = try store.attachPhoto(bytes, projectId: record.project.id, stepId: record.steps[0].id)

        let reopened = try LocalProjectStore(root: root)
        #expect(try reopened.photo(id: photoID, projectId: record.project.id) == bytes)
        let fileURL = root
            .appendingPathComponent(record.project.id.uuidString, isDirectory: true)
            .appendingPathComponent(photoID.uuidString + ".photo")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try reopened.deletePhoto(id: photoID, projectId: record.project.id)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(throws: LocalProjectStore.StoreError.unknownAttachment) {
            _ = try reopened.photo(id: photoID, projectId: record.project.id)
        }
        let again = try LocalProjectStore(root: root)
        #expect(again.allProjects().first?.steps.first?.photoAttachmentIDs.isEmpty == true)

        // Deleting a never-known photo fails without touching anything.
        #expect(throws: LocalProjectStore.StoreError.unknownAttachment) {
            try again.deletePhoto(id: UUID(), projectId: record.project.id)
        }
    }

    @Test("a document where two steps claim one attachment ID is rejected")
    func duplicateAttachmentIDsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try sampleRecord()
        let photoID = UUID().uuidString

        // Two steps of the same project claiming the same attachment ID is
        // only constructable through decoding (attachPhoto appends unique
        // UUIDs), so build the record by hand and feed it to save().
        record.steps[0].photoAttachmentIDs = [photoID]
        record.steps.append(Step(
            id: UUID(), projectId: record.project.id, orderIndex: 1, title: "Shelves",
            instructions: "", photoAttachmentIDs: [photoID]
        ))

        let store = try LocalProjectStore(root: root)
        #expect(throws: LocalProjectStore.StoreError.invalidDocument) {
            try store.save(record)
        }
        // Nothing was written for the rejected document.
        let reopened = try LocalProjectStore(root: root)
        #expect(reopened.allProjects().isEmpty)
    }
}
