# Issue #4 evidence — accessible one-thumb assembly session

Date: 2026-10-13 · Branch: `feat/issue-4-assembly-session`

## What shipped

- `ProjectSession` (AssemblyLaneKit): explicit session operations over the
  append-only ledger — create/edit project (trimmed, never empty), add step
  (deterministic `orderIndex`, overflow-checked), add part (known or unknown
  count, never negative), `start`/`complete`/`reopen(reason)`/`consumePart`.
  Every mutation is an event append + persisted record, so an interrupted
  session resumes purely from disk. `activeStep` exposes the open step the UI
  uses to gate consumption: parts cannot be spent without an explicit open
  step. Unknown counts stay unknown; overspend surfaces as a visible
  `conflict(expected:consumed:)`, never silent negative stock.
- Session UI (`App/AssemblySessionView.swift` + home list in
  `BootstrapHomeView.swift`): project rows, step cards with large bordered
  controls, parts tray with stock and "Use one for <active step>" (disabled
  when no step is active), reopen-reason sheet, manual-consultation
  disclaimer on home and in-session. All controls are plain SwiftUI
  controls/buttons so VoiceOver order, Dynamic Type and reduced motion stay
  system-managed; every interactive element carries a stable
  `accessibilityIdentifier`.
- `StoreModel.storeRoot` honours `-test-store-id <uuid>` under `-ui-testing`
  so simulator journeys get isolated on-disk stores (terminate/relaunch
  resume stays real; existing simulator data is untouched).
- Tests: `ProjectSessionTests` (11 XCTest cases) and
  `UITests/AssemblyLaneSessionTests` (full journey incl. interruption resume +
  AX5 Dynamic Type probe).

## Verification actually run (Linux host)

- `docker run swift:6.2-noble swift test` in `Packages/AssemblyLaneKit`:
  **35 tests in 3 suites passed** — includes the new `ProjectSessionTests`
  suite (11/11 passed, seen in `swift test` output).
- `bash scripts/check_zero_network.sh` → PASS (empty allowlist, no network API).
- `bash scripts/check_native_only.sh` → PASS (no cross-platform traces).
- `python3 -m unittest discover -s Scripts/tests` → 33 tests OK.
- `swiftc -frontend -parse` on every changed/new Swift file → clean.
  ⚠ Parse is not typecheck: App-target SwiftUI and XCUITest files compile
  only on the Apple runner.

## Evidence tiers (not conflated)

- **Linux pure-Swift:** domain/session logic + persistence (above) — real.
- **Apple simulator build + XCUITest:** `Pinned iOS CI` on this PR's head SHA
  (pinned Xcode 26.0.1 / 17A400) — recorded in the PR checks, not here.
- **Device / VoiceOver audio / real Dynamic Type eyeball:** NOT run; no
  device in the pipeline. AX5 launch probe exercises layout, not spoken
  order; VoiceOver labels rely on plain controls + system labels.

## Known limits

- Part consumption is one-per-tap through the active step; multi-quantity
  entry is deferred (append-only ledger already supports `quantity > 1`).
- Overspend conflict and unknown counts render as text rows; #6's layout seam
  will reposition them for the two-surface future.
