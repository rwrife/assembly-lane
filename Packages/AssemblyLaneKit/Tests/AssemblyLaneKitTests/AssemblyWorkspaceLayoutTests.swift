import Foundation
import Testing

@testable import AssemblyLaneKit

/// Issue #6: seam unit tests. Linux `swift test` runs these.
@Suite("AssemblyWorkspaceLayout seam")
struct AssemblyWorkspaceLayoutTests {
    @Test("shipping layout is a single standard iPhone screen")
    func currentIsSingleScreen() {
        #expect(AssemblyWorkspaceLayout.current.presentation == .singleScreen)
        #expect(AssemblyWorkspaceLayout.current.screens == [[.stepDiagram, .controlsTray]])
    }

    @Test("dual-surface splits diagram and controls onto separate screens")
    func dualSurfaceSplit() {
        let layout = AssemblyWorkspaceLayout(presentation: .dualSurface)
        #expect(layout.screens == [[.stepDiagram], [.controlsTray]])
    }

    @Test("every surface appears exactly once in every presentation")
    func surfacesCoveredOnce() {
        for presentation in [WorkspacePresentation.singleScreen, .dualSurface] {
            let flat = AssemblyWorkspaceLayout(presentation: presentation).screens.flatMap { $0 }
            #expect(Set(flat) == Set(WorkspaceSurface.allCases))
            #expect(flat.count == WorkspaceSurface.allCases.count)
        }
    }

    @Test("fold and unfold retain the focused step")
    func focusSurvivesPresentationChange() {
        let step = UUID()
        var state = AssemblyWorkspaceState(focusedStepId: step)
        state.present(.dualSurface)
        #expect(state.layout.presentation == .dualSurface)
        #expect(state.focusedStepId == step)
        state.present(.singleScreen)
        #expect(state.layout == .current)
        #expect(state.focusedStepId == step)
    }

    @Test("presentation change never alters projected event state")
    func eventStateIsPresentationIndependent() throws {
        let projectId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let step = Step(
            id: UUID(), projectId: projectId, orderIndex: 0, title: "Frame",
            instructions: "", photoAttachmentIDs: []
        )
        let part = Part(id: UUID(), projectId: projectId, name: "Bolts", initialQuantity: .known(2))
        let events = [
            AssemblyEvent.stepStarted(id: UUID(), projectId: projectId, timestamp: now, stepId: step.id),
            AssemblyEvent.partUsed(
                id: UUID(), projectId: projectId, timestamp: now.addingTimeInterval(1),
                partId: part.id, stepId: step.id, quantity: 1
            ),
        ]
        var state = AssemblyWorkspaceState(focusedStepId: step.id)
        let before = try AssemblyProjection(parts: [part], steps: [step], events: events)
        state.present(.dualSurface)
        state.present(.singleScreen)
        let after = try AssemblyProjection(parts: [part], steps: [step], events: events)

        #expect(before.stepStatus(for: step.id) == after.stepStatus(for: step.id))
        #expect(before.partStock(for: part.id) == after.partStock(for: part.id))
        #expect(after.stepStatus(for: step.id) == .inProgress)
        #expect(after.partStock(for: part.id)?.remaining == .known(1))
    }
}
