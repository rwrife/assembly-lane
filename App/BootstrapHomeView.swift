import AssemblyLaneKit
import SwiftUI

struct BootstrapHomeView: View {
    @Environment(StoreModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Assembly Lane")
                        .font(.largeTitle.bold())
                    Text("A private, offline workspace for hands-on builds.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Native app foundation is ready", systemImage: "checkmark.circle")
                        Text("Projects, step cards and the parts tray arrive in the next milestones.")
                            .foregroundStyle(.secondary)
                        Text("Domain core milestone: \(AssemblyLaneKit.milestone).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if model.loadFailed {
                            Label(
                                "Local data could not be opened. Existing files were left untouched.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("store.load-failed")
                        } else if model.store != nil {
                            Label(
                                "Local storage ready — \(model.projects.count) saved \(model.projects.count == 1 ? "project" : "projects").",
                                systemImage: "checkmark.circle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("store.ready")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .navigationTitle("Home")
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
