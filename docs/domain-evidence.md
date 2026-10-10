# Issue #2 domain evidence

Dated record of what the event-based step and part-count domain actually
verifies, where, and what remains CI-only.

## What this slice adds

`Packages/AssemblyLaneKit/Sources/AssemblyLaneKit/Domain.swift`:

- `Project`, `Part`, `Step` entities. `Part.initialQuantity` is
  `PartQuantity.unknown` or `.known(Int)` — an unrecorded count is a first
  class state, never a silent zero.
- `AssemblyEvent`: one immutable, `Codable` fact (`stepStarted`,
  `stepCompleted`, `stepReopened`, `partUsed`).
- **Fail-closed trust boundary at decoding and construction**:
  - `partUsed` requires non-nil `partId`, positive `quantity` (`precondition`
    in-process, `DecodingError.dataCorrupted` on decode), and must not carry
    a `reason`.
  - `stepStarted` / `stepCompleted` must not carry `partId`, `quantity`, or
    `reason`.
  - `stepReopened` requires a non-empty `reason` and must not carry `partId`
    or `quantity`.
- `AssemblyProjection`: deterministic fold of the event log.
  - Replay order is `(timestamp, id)` independent of insertion order.
  - Step sort order is `(orderIndex, id)` deterministic across equal
    indices.
  - Throws `DomainError.invalidQuantity` on negative starting count.
  - Throws `DomainError.duplicateEntity` on duplicate part or step IDs
    before `Dictionary(uniqueKeysWithValues:)` can fatal-trap.
  - Throws `DomainError.duplicateEvent` on duplicate event IDs.
  - Throws `DomainError.mixedProjects` if entities or events reference
    different projects.
  - Throws `DomainError.danglingReference` if an event addresses a step or
    part missing from the projection.
  - Throws `DomainError.quantityOverflow` if per-part total consumption
    would wrap `Int`.
  - Throws `DomainError.invalidTimestamp` if an event's date is non-finite,
    before attempting to sort or replay it.
- Derived `PartStock`:
  - `partStock(for:)` returns `PartStock?` (`nil` for unknown parts, never
    masquerading as `.unknown` stock).
  - Consumption is tracked; `remaining` is `.unknown` for unknown starts,
    `.known(n)` while within expected count, and `.conflict(expected:consumed:)`
    on overspend — never negative stock.
  - `overspentBy` surfaces the exact overspend count for the UI.
- Derived `StepStatus`: `notStarted → inProgress → completed → reopened`,
  preserving full audit history via `stepEventHistory` and `stepReopenCount`.

## Verification performed on 2026-10-10 (Linux executor)

- Recovered the staged issue #2 worktree; earlier unrecorded verification
  claims are not treated as evidence.
- Docker `swift:6.2-noble`, `swift test --package-path
  Packages/AssemblyLaneKit -Xswiftc -warnings-as-errors`: **26 tests in
  2 suites passed**.
- Reviewer-driven regressions: non-finite timestamps failed before the
  projection validation fix; newline-only reopen reason failed before
  switching validation to `.whitespacesAndNewlines`. Both pass afterward.
- Shuffled lifecycle replay checks exact history, same-timestamp UUID ties,
  and status at each prefix through completion, reopen, resume and completion.
- Zero-network gate: PASS (`scripts/check_zero_network.sh`, empty allowlist).
- Native-only gate: PASS (`scripts/check_native_only.sh`).
- Python helper suite: **33 tests passed** (`python3 -m unittest discover
  -s Scripts/tests`).
- Apple exact-head simulator build and launch test remain a separate CI gate;
  Linux package tests do not establish an iOS build.

## Honest boundaries

- The app UI does not consume the projection yet — that is issue #4's
  build-session UI. The XCUITest launch smoke test still asserts only the
  skeleton home screen and is unchanged.
- Persistence, migrations and photo attachment scoping are issue #3; the
  versioned JSON backup codec ships with issue #5. Nothing here claims
  durability.
- Apple CI evidence for this commit is the exact-head `ios` job on the PR
  run; no device, signing, or TestFlight claims.
