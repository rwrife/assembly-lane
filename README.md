# Assembly Lane

Offline iPhone assembly workspace for people building flat-pack furniture, hobby kits, and household fixtures: photograph your own step cards, count loose parts, and track reversibly checked steps without accounts or cloud.

## Why / who
Paper instructions separate the step diagram from the hardware pile; interruptions make it hard to remember which fasteners were used. Assembly Lane is for a solo builder who wants a private, one-handed assembly log. It is not an authoritative manual, hardware identifier, or safety certification.

## Intended workflow
Create a project and name its parts; photograph or write your own step cards (camera or Photos access only on explicit selection), enter expected part counts, mark steps started/completed/reopened, and log actual fastener use. See remaining counts with explicit unknown when starting quantities are omitted. Export a versioned JSON backup or human-readable CSV step/part summary via the system share sheet; preview any restore before replacing local data. The user must always consult the manufacturer's official instructions for safety-critical assembly and load limits. Do not import copyrighted manuals automatically or publish user photos.

## MVP and milestones
1. Native SwiftUI iPhone project and pure-Swift AssemblyLaneKit, with CI and iOS 26+ SDK pin.
2. Local project/step/part/event storage with migrations, reversible completion state and nonnegative-count tests.
3. Large one-thumb step cards and parts tray, offline photo attachment management and accessible controls.
4. Backup/export, privacy and restoration; native release evidence.

Current status: **documentation-only scaffold**. No app, Xcode project, icon, build, tests, archive, or TestFlight submission exists yet. AppStore/description.txt is proposed listing copy; reconcile it with shipped features before publishing. The real AppStore/icon.png must be generated with hermes-image-gen after reading the repo and description, then wired to the app icon catalog; never use a placeholder.

## Platform and dual-screen design
Standard **native Swift (SwiftUI/UIKit), iPhone-only** app; iOS 26 SDK or newer, pinned Xcode 26.0.1 (17A400), Swift 6. Set TARGETED_DEVICE_FAMILY = 1 in every app configuration and generator setting, verify built UIDeviceFamily = [1] on Apple CI. Native iPad support is disabled; iPad and Android require explicit opt-in. No Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity. No tablet screenshots/release tests. Future iPhone Duo layout: a persistent current-step diagram on one display and a large inventory/step-control tray on the other. AssemblyWorkspaceLayout is the single presentation seam; today it collapses to a standard one-screen iPhone flow. No dependency on unavailable fold APIs.

## Data and privacy
Project titles, user-created photos, counts and event ledger stay in app-local storage. No analytics, account, advertising, cloud service, or network requests. Camera/photos only on deliberate import, with scoped permissions; no background sensor or notification permissions. Export goes only where the user sends it. Backups may contain photographs and should be treated as private. Accessible labels, VoiceOver ordering, Dynamic Type, contrast, reduced-motion and large touch targets are release criteria.

## Development quickstart (planned)
After the skeleton issue lands: open the Xcode project with pinned Xcode 26.0.1, run the pure-Swift package tests with `swift test`, then build and test the iPhone simulator with `xcodebuild`. Linux source/config review is not an iOS build. Consult PLAN.md and toolchain.json for acceptance criteria.

## Signing and release
Bundle ID **com.infinityball.assemblylane** is registered in App Store Connect (`CREATED`). PRODUCT_BUNDLE_IDENTIFIER and Info.plist must match. Repository Actions secrets (names only): ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_TEAM_ID. The release issue must implement `.github/workflows/release.yml` ported from rwrife/cook-console: `v*` tag or manual dispatch on macos-26; enforce iOS 26+ SDK; archive and export signed IPA, upload through App Store Connect API, wait for processing and publish a GitHub release. No secret values in logs. Actual signed archive and TestFlight processing are future evidence gates.

## Non-goals
No network, automatic copyrighted manual ingestion, parts recognition, structural load certification, assembly safety advice, shared collaboration, subscription, Android, native iPad support, or Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity.
