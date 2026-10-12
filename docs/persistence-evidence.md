# Issue #3 persistence evidence

Dated record of what the local project store actually verifies, where, and
what remains CI-only.

## What this slice adds

`Packages/AssemblyLaneKit/Sources/AssemblyLaneKit/LocalProjectStore.swift`:

- Versioned document envelope (`{"version": 2, "records": [...]}`) over the
  issue #2 `Project`/`Part`/`Step`/`AssemblyEvent` domain.
- **Migration**: a `Step` decoder default makes a v1 document (no
  `photoAttachmentIDs` key) decode to an empty attachment list; loading a v1
  file rewrites it as v2 atomically. A `version` above the supported maximum
  throws `StoreError.unsupportedVersion` and the on-disk bytes are left
  byte-identical (no silent wipe or downgrade).
- **Relaunch durability**: saves are atomic whole-document writes
  (`Data.write(options: .atomic)`); a fresh `LocalProjectStore` on the same
  root returns byte-equal records (identity, order and content preserved).
- **Project-scoped attachments**: photos live under
  `<root>/<projectId>/<attachmentId>.photo`, and the attachment ID is only
  addressable through a step of that same project. `photo(id:projectId:)`
  throws `unknownAttachment` for a foreign project or an unknown ID;
  `attachPhoto` refuses empty payloads and removes the written file if the
  index save then fails; `deletePhoto` removes file and ID, with a
  byte-restoring rollback if the index write fails after deletion.
- **Fail-closed validation** before any write or load:
  - every record's parts/steps/events must share the project's ID
    (`StoreError.invalidDocument`);
  - attachment IDs must be canonical UUID strings and globally unique across
    the whole store (a decoded document cannot claim one photo from two
    steps);
  - each record is re-folded through `AssemblyProjection`, so corrupt event
    data (duplicates, dangling refs, mixed projects…) is rejected at load
    and save time, not rendered.
- Corrupt JSON at load throws (decoding error) and preserves the file for
  recovery; the app surfaces a visible "Local data could not be opened"
  state instead of wiping user data.
- Privacy posture: store root is marked `isExcludedFromBackup` and files use
  `FileProtectionType.complete` on iOS; bytes enter only through explicit
  user selection (PhotosPicker/camera), never library enumeration. The store
  itself is Foundation-only — the zero-network gate stays an empty allowlist.

`App/AssemblyLaneApp.swift` + `App/BootstrapHomeView.swift`: the app now
opens the store lazily at launch into a `StoreModel` and shows store-ready /
load-failed state on the home screen (no silent failure).
`App/ScopedPhotoImport.swift`: deliberate-only import UI — `PhotosPicker`
(scoped picker, no `PHPhotoLibrary` enumeration or blanket permission),
camera behind `UIImagePickerController` gated on source availability, JPEG
recompression before it reaches the store. Camera purpose string added via
`INFOPLIST_KEY_NSCameraUsageDescription`; `PHPhotoLibrary` purpose strings
are intentionally absent because the scoped picker does not require them.

## Verification performed on 2026-10-12 (Linux executor)

- Docker `swift:6.2-noble`, `swift test --package-path
  Packages/AssemblyLaneKit -Xswiftc -warnings-as-errors`: **35 tests in
  3 suites passed** (26 pre-existing domain tests + 9 new
  `LocalProjectStoreTests`: relaunch durability, replace-in-place save, v1→v2
  migration with key-absence proof, future-version rejection with byte
  preservation, corrupt JSON + tampered project-ownership rejection, empty
  round-trip, photo attach/read/scope isolation, deletion + durability,
  duplicate attachment-ID rejection). Rollback code is not fault-injected by
  these tests.
- pbxproj object-ID closure check: 37 defined IDs, zero missing references,
  zero duplicate definitions.
- Zero-network gate: PASS (empty allowlist; PhotosUI/UIKit import only).
- Native-only gate: PASS.
- Python helper suite: 33 tests passed (`python3 -m unittest discover -s
  Scripts/tests`).

## Honest boundaries

- Store files are created with iOS-only attributes under `#if os(iOS)`;
  Linux tests exercise behavior, not Data Protection or backup-exclusion
  attributes. Those are Apple-CI/Device claims this slice does not make.
- `ScopedPhotoImport` compiles only against the iOS SDK; it is not covered
  by Linux tests. The exact-head macOS job builds the app target; no
  simulator UI journey exercises the picker yet (issue #4 owns the session
  UI and its journeys).
- Backup/restore preview and JSON/CSV export remain issue #5; nothing here
  claims user-facing export.
