#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_sha="${1:-}"
if [[ -z "$expected_sha" ]]; then
  echo "usage: Scripts/ci.sh <expected-commit-sha>" >&2
  exit 2
fi

artifact_root="${ASSEMBLYLANE_ARTIFACT_DIR:-$repo_root/build/ci-artifacts}"
mkdir -p "$artifact_root" "$repo_root/build"
artifact_dir="$(mktemp -d "$artifact_root/run.XXXXXX")"
derived_data="$(mktemp -d "$repo_root/build/DerivedData.XXXXXX")"
phase="initialization"

write_provenance() {
  local result=$?
  {
    echo "expected_sha=$expected_sha"
    echo "actual_sha=$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "runner_os=${RUNNER_OS:-unknown}"
    echo "runner_arch=${RUNNER_ARCH:-unknown}"
    echo "developer_dir=${DEVELOPER_DIR:-unselected}"
    echo "simulator_udid=${simulator_udid:-unselected}"
    echo "phase=$phase"
    echo "exit_status=$result"
  } > "$artifact_dir/provenance.txt"
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/xcode-version.txt" \
      -- xcodebuild -version || true
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/iphoneos-sdk-version.txt" \
      -- xcrun --sdk iphoneos --show-sdk-version || true
    python3 Scripts/boot_simulator.py capture \
      --timeout 20 --output "$artifact_dir/simulator-devices-exit.log" \
      -- xcrun simctl list devices available --json || true
  fi
}
trap write_provenance EXIT

actual_sha="$(git rev-parse HEAD)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Checked out SHA $actual_sha does not equal requested SHA $expected_sha" >&2
  exit 1
fi

phase="helper_tests"
python3 -m unittest discover -s Scripts/tests -v 2>&1 | tee "$artifact_dir/helper-tests.log"

phase="zero_network_gate"
bash scripts/check_zero_network.sh 2>&1 | tee "$artifact_dir/zero-network-gate.log"

phase="native_only_gate"
bash scripts/check_native_only.sh 2>&1 | tee "$artifact_dir/native-only-gate.log"

phase="signing_material_gitignore_check"
# Secret material (ASC_KEY_P8 etc.) must never be committable.
for f in fake.p8 fake.p12 fake.mobileprovision fake.cer; do
  touch "$f"
  git check-ignore -q "$f" || { echo "FAIL: $f is not gitignored"; rm -f "$f"; exit 1; }
  rm -f "$f"
done
echo "Signing-material gitignore check: PASS" | tee "$artifact_dir/gitignore-check.log"

phase="iphone_only_pregrep"
# Binding directive: iPhone-only in every build configuration. Fail before
# compiling if any configuration declares iPad (family 2) in any form.
grep -q "TARGETED_DEVICE_FAMILY = 1;" AssemblyLane.xcodeproj/project.pbxproj \
  || { echo "::error::TARGETED_DEVICE_FAMILY = 1 missing from project"; exit 1; }
grep -E "TARGETED_DEVICE_FAMILY = (1,2|2);" AssemblyLane.xcodeproj/project.pbxproj \
  && { echo "::error::iPad device family found — iPhone-only directive violated"; exit 1; } || true
# Every explicit TARGETED_DEVICE_FAMILY setting must be exactly 1.
bad=$(grep -E "TARGETED_DEVICE_FAMILY = [^1;]" AssemblyLane.xcodeproj/project.pbxproj || true)
if [ -n "$bad" ]; then
  echo "::error::Non-iPhone TARGETED_DEVICE_FAMILY values found:"
  echo "$bad"
  exit 1
fi
count=$(grep -c "TARGETED_DEVICE_FAMILY = 1;" AssemblyLane.xcodeproj/project.pbxproj)
echo "iPhone-only pre-build grep: PASS ($count configurations declare family 1 only)" \
  | tee "$artifact_dir/iphone-only-pregrep.log"

phase="toolchain_selection"
python3 Scripts/select_xcode.py \
  --toolchain toolchain.json \
  > "$artifact_dir/developer-dir.txt" \
  2> >(tee "$artifact_dir/toolchain-selection.log" >&2)
export DEVELOPER_DIR
DEVELOPER_DIR="$(<"$artifact_dir/developer-dir.txt")"

phase="simulator_runtime"
# Ported from the proven cook-console-family macos-26 runtime mitigation.
# Keep the selected Xcode pin; install its matching platform, not a newer SDK.
# Exact-identifier + availability matching (Scripts/check_runtime.py), never
# substring grep: iOS-26-0 must not be satisfied by iOS-26-0-1 or an
# unavailable entry.
check_runtime() {
  python3 Scripts/check_runtime.py check \
    --toolchain toolchain.json \
    --runtimes-json "$1"
}
capture_runtime_json() {
  python3 Scripts/check_runtime.py capture \
    --runtimes-json "$1" || true
}
capture_runtime_json "$artifact_dir/runtimes-before.json"
if ! check_runtime "$artifact_dir/runtimes-before.json"; then
  echo "Pinned simulator runtime missing — downloading the pinned Xcode's own platform build (bounded 20 min)"
  python3 Scripts/boot_simulator.py capture \
    --timeout 1200 --output "$artifact_dir/runtime-download.log" \
    -- xcodebuild -downloadPlatform iOS -architectureVariant universal
fi
capture_runtime_json "$artifact_dir/runtimes-after.json"
check_runtime "$artifact_dir/runtimes-after.json" || {
  echo "::error::ACCEPTANCE BLOCKER: pinned iOS simulator runtime unavailable after download attempt (see runtimes-after.json)" >&2
  exit 1
}

phase="simulator_selection"
sdk_version="$(python3 -c 'import json; print(json.load(open("toolchain.json", encoding="utf-8"))["iphoneos_sdk"])')"
simulator_udid="$(python3 Scripts/select_simulator.py \
  --sdk "$sdk_version" \
  --devices-json-out "$artifact_dir/simulator-devices.json")"
echo "platform=iOS Simulator,id=$simulator_udid" > "$artifact_dir/destination.txt"

phase="simulator_boot"
python3 Scripts/boot_simulator.py boot \
  --udid "$simulator_udid" \
  --devices-json "$artifact_dir/simulator-devices.json" \
  --log "$artifact_dir/simulator-boot.log" \
  --boot-timeout 120 \
  --bootstatus-timeout 180 \
  2> >(tee -a "$artifact_dir/simulator-boot.log" >&2)

phase="domain_tests"
xcrun swift test \
  --package-path Packages/AssemblyLaneKit \
  2>&1 | tee "$artifact_dir/domain-tests.log"

phase="app_build"
xcodebuild build \
  -project AssemblyLane.xcodeproj \
  -scheme AssemblyLane \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-build.log"

phase="device_family_guard"
app_plist="$derived_data/Build/Products/Debug-iphonesimulator/AssemblyLane.app/Info.plist"
if [[ ! -f "$app_plist" ]]; then
  echo "Built app Info.plist missing at $app_plist" >&2
  exit 1
fi
plutil -convert json -o "$artifact_dir/app-info.json" "$app_plist"
python3 - "$artifact_dir/app-info.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    info = json.load(handle)
family = info.get("UIDeviceFamily")
if family != [1]:
    raise SystemExit(f"Built app UIDeviceFamily must be [1], observed {family!r}")
print("Verified built app UIDeviceFamily == [1] (iPhone only)")
bundle_id = info.get("CFBundleIdentifier")
if bundle_id != "com.infinityball.assemblylane":
    raise SystemExit(f"Built app CFBundleIdentifier must be com.infinityball.assemblylane, observed {bundle_id!r}")
print("Verified built app CFBundleIdentifier == com.infinityball.assemblylane")
PYTHON

phase="ui_tests"
xcodebuild test \
  -project AssemblyLane.xcodeproj \
  -scheme AssemblyLane \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-test.log"

phase="complete"
