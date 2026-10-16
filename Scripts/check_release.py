#!/usr/bin/env python3
"""Release-readiness checks that run on Linux CI and the macOS release job.

Verifies (issue #7 acceptance):
  * AppStore/icon.png exists, is a real 1024x1024 RGB (opaque, no alpha
    channel) PNG — no transparency, no baked border/corner radius possible
    from the format itself.
  * The exact same bytes are wired into the Xcode asset catalog as AppIcon.
  * The catalog Contents.json declares the single-size iOS icon.
  * project.pbxproj compiles the catalog (ASSETCATALOG_COMPILER_APPICON_NAME),
    declares iPhone-only (TARGETED_DEVICE_FAMILY = 1 only), uses the exact
    registered bundle id, and Release keeps signing enabled.
  * VERSION matches MARKETING_VERSION.

Exit 0 with a PASS summary, or exit 1 listing every failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

BUNDLE_ID = "com.infinityball.assemblylane"
ICON_SIZE = 1024


def png_properties(data: bytes) -> tuple[int, int, int, int]:
    """Return (width, height, bit_depth, color_type) for a PNG header."""
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG (bad signature)")
    if data[12:16] != b"IHDR":
        raise ValueError("not a PNG (missing IHDR)")
    width, height, bit_depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, bit_depth, color_type


def check_icon(repo: Path, failures: list[str]) -> None:
    icon = repo / "AppStore" / "icon.png"
    catalog_icon = repo / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
    if not icon.is_file():
        failures.append("AppStore/icon.png is missing (model-generated artwork required)")
        return
    data = icon.read_bytes()
    try:
        width, height, bit_depth, color_type = png_properties(data)
    except ValueError as error:
        failures.append(f"AppStore/icon.png: {error}")
        return
    if (width, height) != (ICON_SIZE, ICON_SIZE):
        failures.append(f"AppStore/icon.png must be {ICON_SIZE}x{ICON_SIZE}, observed {width}x{height}")
    if bit_depth != 8:
        failures.append(f"AppStore/icon.png must be 8-bit, observed {bit_depth}-bit")
    # Color types: 2 = RGB (opaque), 6 = RGBA (transparency — prohibited).
    if color_type != 2:
        failures.append(
            "AppStore/icon.png must be opaque RGB (PNG color type 2); "
            f"observed color type {color_type} (6 = RGBA transparency)"
        )
    if not catalog_icon.is_file():
        failures.append("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png is missing")
        return
    if hashlib.sha256(data).hexdigest() != hashlib.sha256(catalog_icon.read_bytes()).hexdigest():
        failures.append("App-store icon and Xcode asset-catalog icon differ; wire the same artwork")


def check_catalog(repo: Path, failures: list[str]) -> None:
    contents = repo / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json"
    if not contents.is_file():
        failures.append("AppIcon.appiconset/Contents.json is missing")
        return
    doc = json.loads(contents.read_text(encoding="utf-8"))
    images = doc.get("images", [])
    matching = [
        entry
        for entry in images
        if entry.get("size") == "1024x1024"
        and entry.get("idiom") == "universal"
        and entry.get("filename") == "AppIcon.png"
    ]
    if len(matching) != 1:
        failures.append("Contents.json must declare exactly one universal 1024x1024 AppIcon.png")
    if any("alpha" in str(entry).lower() for entry in images):
        failures.append("Contents.json must not reference alpha/icon files")


def check_project(repo: Path, failures: list[str]) -> None:
    pbxproj = repo / "AssemblyLane.xcodeproj" / "project.pbxproj"
    text = pbxproj.read_text(encoding="utf-8")
    if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" not in text:
        failures.append("project.pbxproj does not compile the AppIcon asset catalog")
    if "Assets.xcassets in Resources" not in text:
        failures.append("project.pbxproj does not include Assets.xcassets in app resources")
    bad_family = re.findall(r"TARGETED_DEVICE_FAMILY = ([^;]+);", text)
    if not bad_family or any(value.strip() != "1" for value in bad_family):
        failures.append(f"every TARGETED_DEVICE_FAMILY must be 1, observed {bad_family!r}")
    bundle_ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", text))
    if bundle_ids != {BUNDLE_ID, BUNDLE_ID + ".uitests"}:
        failures.append(f"bundle identifiers must be {BUNDLE_ID} (+ .uitests), observed {sorted(bundle_ids)}")
    # Release config for the app target must allow signing (archive path);
    # Debug may stay unsigned for simulator CI.
    release_blocks = re.findall(
        r"A10000000000000000000904.*?name = Release;", text, re.DOTALL
    )
    if not release_blocks or "CODE_SIGNING_ALLOWED = YES" not in release_blocks[0]:
        failures.append("app-target Release configuration must set CODE_SIGNING_ALLOWED = YES")
    marketing = re.search(r"MARKETING_VERSION = ([^;]+);", text)
    version_file = repo / "VERSION"
    if not version_file.is_file():
        failures.append("VERSION file is missing (release.yml tag gate depends on it)")
    elif marketing and marketing.group(1).strip() != version_file.read_text(encoding="utf-8").strip():
        failures.append(
            f"MARKETING_VERSION {marketing.group(1)} != VERSION file {version_file.read_text().strip()}"
        )


def check_listing(repo: Path, failures: list[str]) -> None:
    description = repo / "AppStore" / "description.txt"
    if not description.is_file():
        failures.append("AppStore/description.txt is missing")
        return
    text = description.read_text(encoding="utf-8")
    if "proposed" in text.lower():
        failures.append("listing copy still says 'proposed'; reconcile with shipped features")
    for phrase in ("certify structural safety", "manufacturer"):
        if phrase not in text.lower():
            failures.append(f"listing copy must keep the manufacturer/safety disclaimer ({phrase})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    failures: list[str] = []
    check_icon(args.repo, failures)
    check_catalog(args.repo, failures)
    check_project(args.repo, failures)
    check_listing(args.repo, failures)
    if failures:
        for failure in failures:
            print(f"::error::check_release: {failure}", file=sys.stderr)
        return 1
    print("check_release: PASS (real icon wired, iPhone-only, exact bundle id, signed release, listing reconciled)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
