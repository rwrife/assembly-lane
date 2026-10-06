import Testing
@testable import AssemblyLaneKit

@Suite("Skeleton placeholder")
struct AssemblyLaneKitTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(AssemblyLaneKit.domain == "AssemblyLaneKit")
    }

    @Test("milestone marker is set for M0")
    func milestoneMarker() {
        #expect(AssemblyLaneKit.milestone == "M0-skeleton")
    }

    @Test("skeleton exposes no stored state beyond constants")
    func constantsAreStable() {
        // Guards the contract later issues depend on: these markers exist
        // and are pure constants (no clock, no I/O) in the M0 skeleton.
        let first = (AssemblyLaneKit.domain, AssemblyLaneKit.milestone)
        let second = (AssemblyLaneKit.domain, AssemblyLaneKit.milestone)
        #expect(first == second)
    }
}
