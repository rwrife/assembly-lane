import AssemblyLaneKit
import Observation
import SwiftUI

@main
struct AssemblyLaneApp: App {
    @State private var model = StoreModel()

    var body: some Scene {
        WindowGroup {
            BootstrapHomeView()
                .environment(model)
                .task { model.loadIfNeeded() }
        }
    }
}

/// Owns the app-local store. The store is created lazily on first use and
/// never re-reads corrupt data into memory; a failed open leaves existing
/// files untouched and surfaces a visible state instead of a silent wipe.
/// Mutated from the main actor only (SwiftUI view bodies and `.task`s).
@Observable
final class StoreModel {
    private(set) var store: LocalProjectStore?
    private(set) var projects: [LocalProjectStore.Record] = []
    private(set) var loadFailed = false

    init() {}

    func loadIfNeeded() {
        guard store == nil, !loadFailed else { return }
        do {
            let root = try Self.storeRoot()
            let opened = try LocalProjectStore(root: root)
            store = opened
            projects = opened.allProjects()
        } catch {
            loadFailed = true
        }
    }

    func reload() {
        projects = store?.allProjects() ?? []
    }

    nonisolated static func storeRoot() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileReadUnknown)
        }
        return support.appendingPathComponent("LocalStore", isDirectory: true)
    }
}
