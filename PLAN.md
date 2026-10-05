# Assembly Lane — implementation plan

## Scope and architecture
Native SwiftUI iPhone shell (iOS 26+ SDK; Xcode 26.0.1 build 17A400; Swift 6), pure-Swift AssemblyLaneKit for count/step event rules, local persistence with versioned migrations, PhotosPicker/camera only on demand, and Files/share-sheet exports. No network dependency. Standard iPhone app now; future iPhone Duo's persistent step illustration and part-bin control deck are mediated only by AssemblyWorkspaceLayout, not fold SDK calls. Native iPad support is disabled; no iPad-specific UI or release screenshots.

Data: Project, Part(name, optional expected quantity), Step(title, notes, ordered photo references), immutable Event(step_started, step_completed, step_reopened, part_used with quantity and step ID). Projection derives step status and remaining quantities from events. Unknown starting quantities remain unknown, never zero; insufficient stock produces a visible conflict and blocks implicit consumption; explicit correction events preserve history. Photo files are private and referenced by stable local IDs; deleting a project removes its attachments deliberately.

## Dependency-ordered milestones
M1 skeleton and CI; M2 pure domain/event projection tests; M3 durable store/photos migration tests; M4 build-session controls and accessible step cards; M5 export/restore previews and privacy audits; M6 dual-screen seam/UX regression tests; M7 generated real icon, reviewed listing and signed release workflow.

## Test strategy
Unit/property tests for empty/unknown counts, reopen cycles, overspend, event replay and migration. Sanitized fixtures and accessibility UI tests on iPhone simulators; larger Dynamic Type and VoiceOver traversal. Validate zero-network sources/entitlements in CI. Test previewed restore round trips and photo absence/corruption. Linux swift test for pure domain where supported; native build and built UIDeviceFamily = [1] checked only on Apple CI. Never claim device/dual-screen behavior from a Linux source check.

## Packaging and permissions
Bundle ID **com.infinityball.assemblylane** everywhere (PRODUCT_BUNDLE_IDENTIFIER, Info.plist, signing). TARGETED_DEVICE_FAMILY = 1 in every app build configuration and generator; no native iPad support without explicit opt-in. Camera and Photos selection permissions are contextual; no notification, background-location or network permission. AppStore/description.txt is planned-feature copy and must be checked against actual functionality. Generate AppStore/icon.png with hermes-image-gen from repo+description and wire to Xcode asset catalog, checking square/opaque/edge-to-edge without text, borders or baked corner radius.

Port `.github/workflows/release.yml` from rwrife/cook-console: `v*` tag or manual dispatch → macos-26 with iOS 26+ SDK gate → signed IPA archive/export → App Store Connect API TestFlight upload + processing poll → GitHub release. Use ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_TEAM_ID secret names (never values); no invented signing flow. App Store review and TestFlight proof remain future gates.

## Risks and explicit non-goals
Part-count mistakes must not suggest load-bearing safety; refer to official assembly manuals. Photos increase private backup size; export opt-in with explicit preview. Offline local data can be lost unless the user exports it. No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity; no Android, native iPad support, cloud accounts, shared project sync, automatic manual scraping, computer-vision recognition, structural certification or medical claims.
