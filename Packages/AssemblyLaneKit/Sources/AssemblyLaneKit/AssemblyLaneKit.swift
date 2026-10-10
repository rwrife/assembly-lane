/// AssemblyLaneKit — pure-domain core for Assembly Lane.
///
/// Issue #1 shipped the skeleton namespace so CI has a real, testable target.
/// Issue #2 lands the domain layer: the append-only event ledger (Project,
/// Part, Step, immutable Event) and the deterministic projection engine
/// (step status, remaining counts with explicit unknown, visible overspend
/// conflicts, reopen history). The versioned JSON backup codec ships with
/// the backup/export slice (issue #5) and the local store with versioned
/// migrations is issue #3; both live outside this projection.
public enum AssemblyLaneKit {
    /// Namespace marker for the domain layer.
    public static let domain = "AssemblyLaneKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M1-domain"
}
