# Dual-screen seam and responsive iPhone states (issue #6)

Standard iPhone is the only shipping target. `TARGETED_DEVICE_FAMILY = 1`;
no native iPad UI, no iPad screenshots.

## The seam

`AssemblyWorkspaceLayout` (`Packages/AssemblyLaneKit`) is the one place that
decides how the two workspace surfaces map to physical screens:

| Presentation   | Screen 1                  | Screen 2        |
|----------------|---------------------------|-----------------|
| `.singleScreen` (shipping) | step diagram + controls tray | —       |
| `.dualSurface` (future iPhone Duo) | step diagram (persistent) | controls tray (parts bin + step controls) |

`AssemblySessionView` renders surfaces by iterating
`AssemblyWorkspaceLayout.current.screens`. Switching to a two-surface device
means providing a different presentation to that one value; the event store,
domain and projection are untouched.

## No fold SDK

No unavailable fold/hinge API is imported or referenced. `scripts/check_zero_network.sh`
and `scripts/check_native_only.sh` keep running unchanged. A future fold signal
would only call `AssemblyWorkspaceState.present(_:)`.

## Continuity

`AssemblyWorkspaceState` keeps only presentation and the focused step id.
Step status and part stock are always re-derived from the append-only event
log, so folding, unfolding or rotating cannot lose or alter recorded work.

## Evidence tiers

- Linux `swift test` (pure Swift): `AssemblyWorkspaceLayoutTests` — screen
  grouping, surface coverage, focus retention across `present(_:)`, and
  identical projection before/after presentation changes.
- Apple simulator (iPhone, CI): `testRotationRetainsStepAndPartState` rotates
  landscape and back and asserts step state persists. This is a stand-in for
  fold continuity; no dual-screen device test exists or is claimed.
