import Foundation
import Testing

@testable import AssemblyLaneKit

/// Issue #5: versioned JSON backup (incl. photo bytes), previewed restore
/// with conflict reporting, and CSV summary. All local, zero network.
@Suite("WorkspaceTransfer backup/restore/export")
struct WorkspaceTransferTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblyLaneTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleRecord(projectId: UUID = UUID()) -> LocalProjectStore.Record {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(id: projectId, title: "Toolbox \"Steel\"", notes: "Notes, with comma",
                              createdAt: now, updatedAt: now)
        let part = Part(id: UUID(), projectId: projectId, name: "Brass screws", initialQuantity: .known(1))
        let step = Step(id: UUID(), projectId: projectId, orderIndex: 0, title: "Frame",
                        instructions: "", photoAttachmentIDs: [])
        let events = [
            AssemblyEvent.stepStarted(id: UUID(), projectId: projectId, timestamp: now, stepId: step.id),
            AssemblyEvent.partUsed(id: UUID(), projectId: projectId, timestamp: now,
                                   partId: part.id, stepId: step.id, quantity: 2),
        ]
        return LocalProjectStore.Record(project: project, parts: [part], steps: [step], events: events)
    }

    @Test("backup then restore into an empty store round-trips records and photos")
    func roundTrip() throws {
        let sourceRoot = try makeRoot()
        let targetRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }

        let source = try LocalProjectStore(root: sourceRoot)
        var record = sampleRecord()
        try source.save(record)
        let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x42])
        let photoID = try source.attachPhoto(photoBytes, projectId: record.project.id, stepId: record.steps[0].id)
        record = source.allProjects()[0]

        let data = try WorkspaceTransfer.backup(from: source)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\":1"))

        let target = try LocalProjectStore(root: targetRoot)
        let preview = try WorkspaceTransfer.preview(data, in: target)
        #expect(preview.projectCount == 1)
        #expect(preview.photoCount == 1)
        #expect(preview.conflictingTitles.isEmpty)
        try WorkspaceTransfer.restore(preview, into: target)

        let reopened = try LocalProjectStore(root: targetRoot)
        #expect(reopened.allProjects() == [record])
        #expect(try reopened.photo(id: photoID, projectId: record.project.id) == photoBytes)
    }

    @Test("restore preview reports matching project IDs as conflicts and replace wins")
    func previewConflictsAndReplace() throws {
        let sourceRoot = try makeRoot()
        let targetRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }

        let projectId = UUID()
        let source = try LocalProjectStore(root: sourceRoot)
        try source.save(sampleRecord(projectId: projectId))
        let data = try WorkspaceTransfer.backup(from: source)

        let target = try LocalProjectStore(root: targetRoot)
        var rival = sampleRecord(projectId: projectId)
        rival.project.title = "Local overwrite"
        try target.save(rival)
        try target.save(sampleRecord()) // project absent from the backup

        let preview = try WorkspaceTransfer.preview(data, in: target)
        #expect(preview.conflictingTitles == ["Toolbox \"Steel\""])
        try WorkspaceTransfer.restore(preview, into: target)
        let after = try LocalProjectStore(root: targetRoot)
        #expect(after.allProjects().count == 1)
        #expect(after.allProjects()[0].project.title == "Toolbox \"Steel\"")
    }

    @Test("restore refuses when the workspace changed after preview")
    func changedSincePreview() throws {
        let sourceRoot = try makeRoot()
        let targetRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }
        let source = try LocalProjectStore(root: sourceRoot)
        try source.save(sampleRecord())
        let data = try WorkspaceTransfer.backup(from: source)

        let target = try LocalProjectStore(root: targetRoot)
        let preview = try WorkspaceTransfer.preview(data, in: target)
        try target.save(sampleRecord()) // mutate after previewing
        #expect(throws: WorkspaceTransfer.TransferError.changedSincePreview) {
            try WorkspaceTransfer.restore(preview, into: target)
        }
        // Rejection left the new local project intact.
        #expect(try LocalProjectStore(root: targetRoot).allProjects().count == 1)
    }

    @Test("versions other than 1 are rejected without touching the store")
    func versionRejection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalProjectStore(root: root)
        for version in [0, 2, 99] {
            let payload = Data("{\"version\":\(version),\"records\":[],\"photos\":[]}".utf8)
            #expect(throws: WorkspaceTransfer.TransferError.unsupportedVersion(version)) {
                _ = try WorkspaceTransfer.preview(payload, in: store)
            }
        }
        #expect(store.allProjects().isEmpty)
    }

    @Test("malformed backups: junk JSON, missing or orphan photo payloads, broken projections")
    func malformedRejection() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalProjectStore(root: root)

        #expect(throws: (any Error).self) {
            _ = try WorkspaceTransfer.preview(Data("not json".utf8), in: store)
        }

        let record = sampleRecord()
        let attachment = UUID()
        var withPhoto = record
        withPhoto.steps[0].photoAttachmentIDs = [attachment.uuidString]

        struct Photo: Encodable { let id: UUID; let projectId: UUID; let bytes: Data }
        struct Backup: Encodable { let version: Int; let records: [LocalProjectStore.Record]; let photos: [Photo] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // Referenced attachment missing its payload.
        let missing = try encoder.encode(Backup(version: 1, records: [withPhoto], photos: []))
        #expect(throws: WorkspaceTransfer.TransferError.invalidBackup) {
            _ = try WorkspaceTransfer.preview(missing, in: store)
        }
        // Empty payload.
        let empty = try encoder.encode(Backup(version: 1, records: [withPhoto],
                                              photos: [Photo(id: attachment, projectId: record.project.id, bytes: Data())]))
        #expect(throws: WorkspaceTransfer.TransferError.invalidBackup) {
            _ = try WorkspaceTransfer.preview(empty, in: store)
        }
        // Orphan payload for an attachment no step references.
        let orphan = try encoder.encode(Backup(version: 1, records: [record],
                                               photos: [Photo(id: attachment, projectId: record.project.id, bytes: Data([1]))]))
        #expect(throws: WorkspaceTransfer.TransferError.invalidBackup) {
            _ = try WorkspaceTransfer.preview(orphan, in: store)
        }
        // Structurally broken record set fails shared store validation:
        // a step that lies about its project ownership (only constructable
        // by decoding, so hand-build it).
        var lying = record
        lying.steps[0] = Step(id: record.steps[0].id, projectId: UUID(), orderIndex: 0,
                              title: "Lies", instructions: "", photoAttachmentIDs: [])
        let broken = try encoder.encode(Backup(version: 1, records: [lying], photos: []))
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTransfer.preview(broken, in: store)
        }
        #expect(store.allProjects().isEmpty)
    }

    @Test("a restored workspace replaces old photos and keeps only backup bytes")
    func restoreReplacesPhotoTrees() throws {
        let sourceRoot = try makeRoot()
        let targetRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }

        let source = try LocalProjectStore(root: sourceRoot)
        let record = sampleRecord()
        try source.save(record)
        let kept = try source.attachPhoto(Data("kept".utf8),
                                          projectId: record.project.id, stepId: record.steps[0].id)
        let data = try WorkspaceTransfer.backup(from: source)

        let target = try LocalProjectStore(root: targetRoot)
        let doomed = LocalProjectStore.Record(
            project: Project(id: UUID(), title: "Old", notes: "",
                             createdAt: .distantPast, updatedAt: .distantPast)
        )
        try target.save(doomed)
        // Attach a photo to a fresh record with a step so the old tree exists.
        var withStep = doomed
        withStep.steps = [Step(id: UUID(), projectId: doomed.project.id, orderIndex: 0,
                               title: "Old step", instructions: "", photoAttachmentIDs: [])]
        try target.save(withStep)
        let doomedPhoto = try target.attachPhoto(Data("doomed".utf8),
                                                 projectId: doomed.project.id, stepId: withStep.steps[0].id)

        try WorkspaceTransfer.restore(try WorkspaceTransfer.preview(data, in: target), into: target)

        let reopened = try LocalProjectStore(root: targetRoot)
        #expect(reopened.allProjects().count == 1)
        #expect(try reopened.photo(id: kept, projectId: record.project.id) == Data("kept".utf8))
        #expect(throws: (any Error).self) {
            _ = try reopened.photo(id: doomedPhoto, projectId: doomed.project.id)
        }
        let oldTree = targetRoot.appendingPathComponent(doomed.project.id.uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: oldTree.path))
        // Only the live root and the staging directory ever appear; after the
        // swap no previous-*/restore-* sibling survives next to the root.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: targetRoot.deletingLastPathComponent().path)
        let leftovers = siblings.filter { $0.hasPrefix(targetRoot.lastPathComponent + ".previous-") }
        #expect(leftovers.isEmpty)
    }

    @Test("CSV quotes separators, reports conflicts and unknown counts verbatim")
    func csvSummary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalProjectStore(root: root)
        let record = sampleRecord()
        try store.save(record)

        let text = String(decoding: try WorkspaceTransfer.csv(from: store), as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.first == "project,kind,name,status,initial,used,remaining")
        #expect(lines.contains(#""Toolbox ""Steel""",step,Frame,in progress,,,"#))
        // Overspend: expected 1, used 2 -> conflict, never negative stock.
        #expect(lines.contains(#""Toolbox ""Steel""",part,Brass screws,count conflict,1,2,conflict"#))
    }
}
