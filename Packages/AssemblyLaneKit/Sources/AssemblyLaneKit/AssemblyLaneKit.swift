/// AssemblyLaneKit — pure-domain core for Assembly Lane.
///
/// Issue #1 ships only the skeleton namespace so CI has a real, testable
/// target. Issue #2 (domain) lands the append-only event ledger (Project,
/// Part, Step, immutable Event), the deterministic projection engine (step
/// status, remaining counts with explicit unknown, visible overspend
/// conflicts, reopen history) and the versioned backup codec here. The
/// local store with versioned migrations is issue #3 and lives outside
/// this package.
public enum AssemblyLaneKit {
    /// Namespace marker for the domain layer.
    public static let domain = "AssemblyLaneKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M0-skeleton"
}
