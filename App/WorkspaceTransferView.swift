import AssemblyLaneKit
import SwiftUI
import UniformTypeIdentifiers

/// Transfers start only from deliberate taps. Share sheet is user-controlled;
/// no account, telemetry, upload, or automatic background export.
struct WorkspaceTransferView: View {
    @Environment(StoreModel.self) private var model
    @State private var backupURL: URL?
    @State private var csvURL: URL?
    @State private var preview: WorkspaceTransfer.Preview?
    @State private var showImporter = false
    @State private var showPreview = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Your data") {
            Text("Backup includes project notes, steps, parts, event history and step photos. Anyone with the file can read them. Choose a private destination in the share sheet.")
                .font(.footnote)
            Button("Prepare JSON backup") {
                backupURL = prepare("AssemblyLane-Backup.json") { try WorkspaceTransfer.backup(from: $0) }
            }
            .accessibilityIdentifier("transfer.backup")
            if let backupURL {
                ShareLink("Share JSON backup", item: backupURL)
                    .accessibilityIdentifier("transfer.backup-share")
            }
            Button("Choose JSON backup to restore") { showImporter = true }
                .accessibilityIdentifier("transfer.restore")
            Button("Prepare CSV summary") {
                csvURL = prepare("AssemblyLane-Summary.csv") { try WorkspaceTransfer.csv(from: $0) }
            }
            .accessibilityIdentifier("transfer.csv")
            if let csvURL {
                ShareLink("Share CSV summary", item: csvURL)
                    .accessibilityIdentifier("transfer.csv-share")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let store = model.store else { return }
                preview = try WorkspaceTransfer.preview(Data(contentsOf: url), in: store)
                showPreview = true
            } catch { errorMessage = "Backup could not be previewed: \(error.localizedDescription)" }
        }
        .sheet(isPresented: $showPreview, onDismiss: { preview = nil }) {
            NavigationStack {
                Form {
                    if let preview {
                        Text("Replace all current projects with \(preview.projectCount) backup projects and \(preview.photoCount) photos?")
                        Text("Current projects not in this backup will be removed. Save a separate backup first if needed.")
                            .foregroundStyle(.red)
                        if !preview.conflictingTitles.isEmpty {
                            Text("Matching project IDs: \(preview.conflictingTitles.joined(separator: ", "))")
                        }
                    }
                }
                .navigationTitle("Preview restore")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showPreview = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Replace workspace", role: .destructive) {
                            guard let preview, let store = model.store else { return }
                            do {
                                try WorkspaceTransfer.restore(preview, into: store)
                                model.reload()
                                showPreview = false
                            } catch { errorMessage = "Restore failed: \(error.localizedDescription). Check local files before retrying." }
                        }
                        .accessibilityIdentifier("transfer.confirm-restore")
                    }
                }
            }
        }
        .alert("Transfer failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }

    private func prepare(_ name: String, content: (LocalProjectStore) throws -> Data) -> URL? {
        do {
            guard let store = model.store else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try content(store).write(to: url, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
            return url
        } catch { errorMessage = "Export could not be prepared: \(error.localizedDescription)"; return nil }
    }
}
