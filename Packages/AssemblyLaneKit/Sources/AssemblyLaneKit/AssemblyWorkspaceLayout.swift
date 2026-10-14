import Foundation

/// Issue #6: the single presentation seam between assembly state and screens.
///
/// Today every device is `.singleScreen`: the step diagram and the controls
/// tray stack in one scrolling iPhone flow. A future iPhone Duo build maps
/// `.dualSurface` to two physical surfaces (persistent step diagram on one,
/// large inventory/step-control tray on the other) by changing ONLY the
/// presentation chosen here. No fold/hinge SDK is referenced anywhere; when
/// one exists, the app layer picks the presentation and nothing else moves.
///
/// Foundation only: no UI, no clock, no I/O, no network.
public enum WorkspaceSurface: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Current step title, instructions and photos.
    case stepDiagram
    /// Step controls plus the parts tray.
    case controlsTray
}

public enum WorkspacePresentation: Equatable, Hashable, Sendable {
    case singleScreen
    case dualSurface
}

public struct AssemblyWorkspaceLayout: Equatable, Sendable {
    public let presentation: WorkspacePresentation

    public init(presentation: WorkspacePresentation = .singleScreen) {
        self.presentation = presentation
    }

    /// The layout used by the shipping iPhone app.
    public static let current = AssemblyWorkspaceLayout()

    /// Surfaces grouped per physical screen, in reading order. Every
    /// surface appears exactly once in either presentation.
    public var screens: [[WorkspaceSurface]] {
        switch presentation {
        case .singleScreen: [[.stepDiagram, .controlsTray]]
        case .dualSurface: [[.stepDiagram], [.controlsTray]]
        }
    }
}

/// Navigation state that must survive fold/unfold and rotation. It holds no
/// assembly facts: step status and part stock are always re-derived from the
/// event log (`AssemblyProjection`), so a presentation change can never lose
/// or alter recorded work.
public struct AssemblyWorkspaceState: Equatable, Sendable {
    public private(set) var layout: AssemblyWorkspaceLayout
    public private(set) var focusedStepId: UUID?

    public init(layout: AssemblyWorkspaceLayout = .current, focusedStepId: UUID? = nil) {
        self.layout = layout
        self.focusedStepId = focusedStepId
    }

    public mutating func focus(stepId: UUID?) { focusedStepId = stepId }

    /// Fold/unfold: changes presentation only; focus is retained.
    public mutating func present(_ presentation: WorkspacePresentation) {
        layout = AssemblyWorkspaceLayout(presentation: presentation)
    }
}
