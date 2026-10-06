# Issue #1 bootstrap evidence

Dated record of what was actually verified, where, and what remains CI-only.

## What this bootstrap adds

- `AssemblyLane.xcodeproj` with shared `AssemblyLane` scheme (app + UI-test targets),
  bundle id `com.infinityball.assemblylane`, `TARGETED_DEVICE_FAMILY = 1` in every
  build configuration, iOS 26.0 deployment target, Swift 6 language mode.
- `App/`: SwiftUI launch-only placeholder (`AssemblyLaneApp` + `BootstrapHomeView`)
  wired to `Packages/AssemblyLaneKit`.
- `Packages/AssemblyLaneKit`: pure Swift 6 package (Foundation only) with
  swift-testing placeholder tests proving the Linux lane works.
- `UITests/AssemblyLaneLaunchTests.swift`: simulator launch smoke test asserting
  the `bootstrap.home` accessibility identifier and home-screen copy.
- `Scripts/`: pinned toolchain selection (measured version/build/SDK match),
  simulator selection/boot helpers with bounded subprocess timeouts and a
  bounded one-shot retry for known hosted-runner boot/enumeration wedges,
  and the CI entrypoint `Scripts/ci.sh` (phase-tracked provenance on every exit).
- `scripts/check_zero_network.sh`: empty-allowlist scan of `App/`, `UITests/`,
  and `Packages/*/Sources/` for network APIs (`.build` dirs excluded).
- `scripts/check_native_only.sh`: rejection gate for Flutter, React Native, Expo,
  Kotlin Multiplatform, .NET MAUI, and Unity files or dependency manifests.
- `.github/workflows/ci.yml`: Linux package job (`swift:6.2-noble`) plus a
  macos-26 job with exact-head checkout, pinned-toolchain validation,
  simulator runtime installation fallback, and always-upload artifacts.

## Toolchain enforcement

`toolchain.json` pins Xcode 26.0.1 (17A400) / iPhoneOS SDK 26.0 / Swift 6 mode /
deployment target 26.0, exactly as the README and PLAN require. `Scripts/select_xcode.py`
measures `xcodebuild -version` and `xcrun --sdk iphoneos --show-sdk-version` for every
installation under `/Applications` and only accepts an actual version/build/SDK match;
a missing pin is a hard CI failure (`PinError`), never a silent fallback. The workflow
checks out `github.event.pull_request.head.sha` explicitly, so CI tests the exact PR
head commit, not a synthetic merge ref.

## iPhone-only and zero-network enforcement

`Scripts/ci.sh` enforces iPhone-only policy twice: an `iphone_only_pregrep` phase
fails before compiling unless every `TARGETED_DEVICE_FAMILY` setting in
`AssemblyLane.xcodeproj` is exactly `1` (any `1,2` or `2` fails), and after the build the
`device_family_guard` phase converts the built `AssemblyLane.app/Info.plist` to JSON and
fails unless `UIDeviceFamily == [1]` and `CFBundleIdentifier == com.infinityball.assemblylane`;
the JSON is uploaded as `app-info.json`.

The zero-network gate scans app sources, UI tests, and package sources against an
explicit EMPTY allowlist; any match on URLSession/Network.framework/CFNetwork/POSIX
socket vocabulary fails the run. The native-only gate rejects cross-platform/hybrid
manifests and dependencies. A signing-material gitignore probe asserts `*.p8`,
`*.p12`, `*.mobileprovision`, and `*.cer` cannot be committed.

All simulator subprocesses are bounded (30 s enumeration, 120 s boot, 180 s
bootstatus) with logs preserved in `build/ci-artifacts`, and the workflow uploads
artifacts with `if: always()` so failures keep their provenance
(`provenance.txt` records expected/actual SHA, phase, and exit status).

## Verification actually performed (Linux executor, no Swift/Xcode on host)

- `python3 -m unittest discover -s Scripts/tests` — 21 helper tests for bounded
  boot/timeout/exit-code behavior, simulator selection, and exact Xcode pin
  selection all pass locally.
- `bash scripts/check_zero_network.sh` — PASS (empty allowlist, no network API usage).
- `bash scripts/check_native_only.sh` — PASS (no prohibited framework traces).
- `swift test` for `Packages/AssemblyLaneKit` executed inside Docker (`swift:6.2-noble`),
  passing 3 tests matching the CI Linux job image.
- pbxproj object closure: 35 defined objects == 35 referenced objects; all 4
  configurations declare `TARGETED_DEVICE_FAMILY = 1` with no iPad family value;
  the two app-target configurations declare
  `PRODUCT_BUNDLE_IDENTIFIER = com.infinityball.assemblylane` (the UI-test
  configurations use the `…assemblylane.uitests` sub-namespace). The built-app
  `CFBundleIdentifier` itself is asserted only on Apple CI (`device_family_guard`).
- GitHub Actions workflow syntax validated via `docker run rhysd/actionlint:latest`.
