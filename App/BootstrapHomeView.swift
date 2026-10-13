import AssemblyLaneKit
import SwiftUI

struct BootstrapHomeView: View {
    @Environment(StoreModel.self) private var model
    @State private var showNewProject = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A private, offline workspace for hands-on builds.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Follow the manufacturer's instructions. This app does not certify assembly or load-bearing safety.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.manual-notice")
                }
                if model.loadFailed {
                    Label(
                        "Local data could not be opened. Existing files were left untouched.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("store.load-failed")
                } else if model.store == nil {
                    ProgressView("Opening local projects")
                } else {
                    Section {
                        Label(
                            "Local storage ready — \(model.projects.count) saved \(model.projects.count == 1 ? "project" : "projects").",
                            systemImage: "checkmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("store.ready")
                    }
                    Section("Projects") {
                        ForEach(model.projects, id: \.project.id) { record in
                            NavigationLink(value: record.project.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.project.title).font(.headline)
                                    Text("\(record.steps.count) steps · \(record.parts.count) parts")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("project.row")
                        }
                        if model.projects.isEmpty {
                            Text("No projects yet. Tap New project to start one.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Assembly Lane")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewProject = true
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                    .accessibilityIdentifier("project.new")
                }
            }
            .navigationDestination(for: UUID.self) { projectId in
                AssemblySessionView(projectId: projectId)
            }
            .sheet(isPresented: $showNewProject) {
                ProjectForm(title: "New project") { title, notes in
                    guard let store = model.store else { return }
                    try ProjectSession(store: store).createProject(title: title, notes: notes)
                    model.reload()
                }
            }
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
