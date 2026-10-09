#!/usr/bin/env python3
"""Pin-check the iOS simulator runtime required by toolchain.json.

Subcommands:
  capture  Run `xcrun simctl list runtimes --json` with a bounded timeout and
           write RAW stdout to --runtimes-json. Command headers and stderr
           never enter the JSON file (the boot_simulator.py `capture` helper
           prefixes a `$ cmd` log line, which json.loads would reject).
  check    Parse --runtimes-json and require the exact pinned runtime
           identifier with isAvailable true. Exact-identifier matching only:
           iOS-26-0 must never match iOS-26-0-1, and unavailable entries
           never satisfy the pin. Accepts both shapes `simctl list runtimes
           --json` has shipped: runtimes as a list of objects or a dict
           keyed by runtime identifier.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

CAPTURE_TIMEOUT_SECONDS = 60


class RuntimeErrorPin(ValueError):
    pass


def required_runtime(toolchain_path: Path) -> str:
    try:
        pins = json.loads(toolchain_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeErrorPin(f"Cannot read toolchain pins from {toolchain_path}: {error}") from error
    sdk = pins.get("iphoneos_sdk")
    if not isinstance(sdk, str) or not sdk:
        raise RuntimeErrorPin("toolchain.json must pin a string iphoneos_sdk")
    return f"com.apple.CoreSimulator.SimRuntime.iOS-{sdk.replace('.', '-')}"


def runtime_available(payload: dict, identifier: str) -> bool:
    runtimes = payload.get("runtimes")
    if isinstance(runtimes, dict):
        entries = runtimes.get(identifier, [])
    elif isinstance(runtimes, list):
        entries = [r for r in runtimes if isinstance(r, dict) and r.get("identifier") == identifier]
    else:
        return False
    if isinstance(entries, dict):
        entries = [entries]
    return any(
        isinstance(entry, dict) and entry.get("identifier") == identifier and entry.get("isAvailable") is True
        for entry in entries
    )


def capture_runtimes(output: Path, *, runner=subprocess.run, timeout: int = CAPTURE_TIMEOUT_SECONDS) -> None:
    """Write raw simctl stdout only; stderr goes to our stderr, not the file.

    Raises OSError/SubprocessError on failure without writing invalid output.
    """
    result = runner(
        ["xcrun", "simctl", "list", "runtimes", "--json"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    output.write_text(result.stdout, encoding="utf-8")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--runtimes-json", type=Path, required=True)

    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("--toolchain", type=Path, default=Path("toolchain.json"))
    check_parser.add_argument("--runtimes-json", type=Path, required=True)

    args = parser.parse_args()
    if args.action == "capture":
        try:
            capture_runtimes(args.runtimes_json)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Simulator runtime capture failed: {error}", file=sys.stderr)
            return 1
        return 0

    try:
        identifier = required_runtime(args.toolchain)
        try:
            payload = json.loads(args.runtimes_json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Simulator runtimes unavailable ({error}); treating as missing", file=sys.stderr)
            return 1
        if not isinstance(payload, dict) or not runtime_available(payload, identifier):
            print(f"Exact runtime {identifier} not installed/available", file=sys.stderr)
            return 1
    except RuntimeErrorPin as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Simulator runtime present and available: {identifier}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
