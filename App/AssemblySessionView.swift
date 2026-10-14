import AssemblyLaneKit
import SwiftUI

/// One-thumb session: step controls and parts tray remain ordinary SwiftUI
/// controls so Dynamic Type, VoiceOver order and reduced motion are native.
///
/// Issue #6 seam: the sections below are rendered per
/// `AssemblyWorkspaceLayout` screen group. Today `current` is one
/// `.singleScreen` containing `.stepDiagram` and `.controlsTray`, so the
/// flow is an ordinary one-screen iPhone stack. A future iPhone Duo build
/// routes `.stepDiagram` to the persistent diagram surface and
/// `.controlsTray` to the control-deck surface by changing only this
/// presentation choice — never the event store, and never a fold SDK.
struct AssemblySessionView: View {
    @Environment(StoreModel.self) private var model
    let projectId: UUID
    @State private var sheet: SessionSheet?
    @State private var errorMessage: String?

    /// Single presentation seam (see AssemblyLaneKit.AssemblyWorkspaceLayout).
    private let workspace = AssemblyWorkspaceLayout.current

    private var record: LocalProjectStore.Record? {
        model.projects.first(where: { $0.project.id == projectId })
    }

    var body: some View {
        List {
            if let record, let store = model.store {
                Section {
                    Text("Follow the manufacturer's instructions. This app does not certify assembly or load-bearing safety.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("session.manual-notice")
                    if !record.project.notes.isEmpty { Text(record.project.notes) }
                    Button("Edit project", systemImage: "pencil") { sheet = .editProject }
                        .accessibilityIdentifier("project.edit")
                }
                // Present both surfaces in reading order on today's iPhone.
                // A future Duo presentation splits the same surface content.
                ForEach(workspace.screens.flatMap { $0 }, id: \.self) { surface in
                    switch surface {
                    case .stepDiagram:
                        Section("Steps") {
                            if record.steps.isEmpty {
                                Text("No steps yet. Add one from your manual.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(record.steps.sorted(by: {
                                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
                            })) { step in
                                stepCard(step, record: record, store: store)
                            }
                            Button("Add step", systemImage: "plus") { sheet = .addStep }
                                .accessibilityIdentifier("step.add")
                        }
                    case .controlsTray:
                        Section("Parts tray") {
                            if record.parts.isEmpty { Text("No parts yet.").foregroundStyle(.secondary) }
                            ForEach(record.parts) { part in
                                partRow(part, record: record, store: store)
                            }
                            Button("Add part", systemImage: "plus") { sheet = .addPart }
                                .accessibilityIdentifier("part.add")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(record?.project.title ?? "Assembly")
        .sheet(item: $sheet) { selection in
            if let store = model.store, let record {
                switch selection {
                case .editProject:
                    ProjectForm(title: "Edit project", initialTitle: record.project.title,
                                initialNotes: record.project.notes) { title, notes in
                        try ProjectSession(store: store).updateProject(
                            projectId: projectId, title: title, notes: notes
                        )
                        model.reload()
                    }
                case .addStep:
                    StepForm { title, instructions in
                        try ProjectSession(store: store).addStep(
                            projectId: projectId, title: title, instructions: instructions
                        )
                        model.reload()
                    }
                case .addPart:
                    PartForm { name, quantity in
                        try ProjectSession(store: store).addPart(
                            projectId: projectId, name: name, initialQuantity: quantity
                        )
                        model.reload()
                    }
                case let .reopen(stepId):
                    ReopenForm { reason in
                        try ProjectSession(store: store).reopenStep(
                            projectId: projectId, stepId: stepId, reason: reason
                        )
                        model.reload()
                    }
                }
            }
        }
        .alert("Could not save", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private func stepCard(_ step: Step, record: LocalProjectStore.Record, store: LocalProjectStore) -> some View {
        let status = (try? ProjectSession(store: store).projection(for: record))?.stepStatus(for: step.id) ?? .notStarted
        VStack(alignment: .leading, spacing: 12) {
            Text(step.title).font(.headline)
            if !step.instructions.isEmpty { Text(step.instructions) }
            Text(statusText(status))
                .font(.subheadline).foregroundStyle(status == .completed ? .green : .secondary)
                .accessibilityIdentifier("step.status")
            Group {
                switch status {
                case .notStarted, .reopened:
                    Button("Start") {
                        save { try ProjectSession(store: store).startStep(projectId: projectId, stepId: step.id) }
                    }
                    .accessibilityIdentifier("step.start")
                case .inProgress:
                    Button("Complete") {
                        save { try ProjectSession(store: store).completeStep(projectId: projectId, stepId: step.id) }
                    }
                    .accessibilityIdentifier("step.complete")
                case .completed:
                    Button("Reopen") { sheet = .reopen(step.id) }
                        .accessibilityIdentifier("step.reopen")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            ScopedPhotoImport(store: store, projectId: projectId, stepId: step.id) { _ in model.reload() }
        }
        .padding(.vertical, 12)
    }

    private func partRow(_ part: Part, record: LocalProjectStore.Record, store: LocalProjectStore) -> some View {
        let session = ProjectSession(store: store)
        let stock = (try? session.projection(for: record))?.partStock(for: part.id)
        let active = try? session.activeStep(in: record)
        return VStack(alignment: .leading, spacing: 8) {
            Text(part.name).font(.headline)
            Text(stockText(stock))
                .foregroundStyle(stock?.isOverspent == true ? .red : .secondary)
                .accessibilityIdentifier("part.stock")
            Button("Use one for \(active?.title ?? "a started step")") {
                guard let step = active else { return }
                save { try session.consumePart(projectId: projectId, partId: part.id, stepId: step.id, quantity: 1) }
            }
            .disabled(active == nil)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("part.use")
        }
        .padding(.vertical, 8)
    }

    private func save(_ action: () throws -> Void) {
        do { try action(); model.reload() }
        catch { errorMessage = "Changes could not be saved. Existing data was left untouched." }
    }

    private func statusText(_ status: StepStatus) -> String {
        switch status {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .reopened: "Reopened — needs attention"
        }
    }

    private func stockText(_ stock: PartStock?) -> String {
        guard let stock else { return "Count unavailable" }
        switch stock.remaining {
        case .unknown: return "Quantity unknown · \(stock.consumed) used"
        case let .known(remaining): return "\(remaining) remaining · \(stock.consumed) used"
        case let .conflict(expected, consumed): return "Count conflict: expected \(expected), used \(consumed)"
        }
    }
}

private enum SessionSheet: Identifiable {
    case editProject, addStep, addPart, reopen(UUID)
    var id: String {
        switch self {
        case .editProject: "editProject"
        case .addStep: "addStep"
        case .addPart: "addPart"
        case let .reopen(id): "reopen-\(id.uuidString)"
        }
    }
}

struct ProjectForm: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let save: @MainActor (String, String) throws -> Void
    @State private var name: String
    @State private var notes: String
    @State private var failed = false

    init(title: String, initialTitle: String = "", initialNotes: String = "",
         save: @escaping @MainActor (String, String) throws -> Void) {
        self.title = title
        self.save = save
        _name = State(initialValue: initialTitle)
        _notes = State(initialValue: initialNotes)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project name", text: $name).accessibilityIdentifier("project.name")
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .accessibilityIdentifier("project.notes")
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try save(name, notes); dismiss() }
                        catch { failed = true }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("project.save")
                }
            }
            .alert("Project could not be saved", isPresented: $failed) { Button("OK", role: .cancel) {} }
        }
    }
}

private struct StepForm: View {
    @Environment(\.dismiss) private var dismiss
    let save: @MainActor (String, String) throws -> Void
    @State private var title = ""
    @State private var instructions = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Step name", text: $title).accessibilityIdentifier("step.name")
                TextField("Instructions from manual (optional)", text: $instructions, axis: .vertical)
                    .accessibilityIdentifier("step.instructions")
            }
            .navigationTitle("New step")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try save(title, instructions); dismiss() }
                        catch { failed = true }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("step.save")
                }
            }
            .alert("Step could not be saved", isPresented: $failed) { Button("OK", role: .cancel) {} }
        }
    }
}

private struct PartForm: View {
    @Environment(\.dismiss) private var dismiss
    let save: @MainActor (String, PartQuantity) throws -> Void
    @State private var name = ""
    @State private var knownCount = false
    @State private var countText = ""
    @State private var failed = false

    private var quantity: PartQuantity? {
        if !knownCount { return .unknown }
        guard let value = Int(countText), value >= 0 else { return nil }
        return .known(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Part name", text: $name).accessibilityIdentifier("part.name")
                Toggle("I know the starting count", isOn: $knownCount)
                    .accessibilityIdentifier("part.count-known")
                if knownCount {
                    TextField("Starting count", text: $countText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("part.count")
                } else {
                    Text("Unknown stays unknown even after use.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New part")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let quantity else { return }
                        do { try save(name, quantity); dismiss() }
                        catch { failed = true }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quantity == nil)
                    .accessibilityIdentifier("part.save")
                }
            }
            .alert("Part could not be saved", isPresented: $failed) { Button("OK", role: .cancel) {} }
        }
    }
}

private struct ReopenForm: View {
    @Environment(\.dismiss) private var dismiss
    let save: @MainActor (String) throws -> Void
    @State private var reason = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Reason for reopening", text: $reason, axis: .vertical)
                    .accessibilityIdentifier("step.reopen-reason")
            }
            .navigationTitle("Reopen step")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reopen") {
                        do { try save(reason); dismiss() }
                        catch { failed = true }
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("step.reopen-save")
                }
            }
            .alert("Step could not be reopened", isPresented: $failed) { Button("OK", role: .cancel) {} }
        }
    }
}
