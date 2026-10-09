import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.check_runtime import (
    RuntimeErrorPin,
    capture_runtimes,
    required_runtime,
    runtime_available,
)

IDENT = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"


class RequiredRuntimeTests(unittest.TestCase):
    def toolchain(self, sdk):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "toolchain.json"
        path.write_text(json.dumps({"iphoneos_sdk": sdk}), encoding="utf-8")
        return path

    def test_exact_runtime_id_from_pinned_sdk(self):
        self.assertEqual(required_runtime(self.toolchain("26.0")), IDENT)

    def test_rejects_missing_sdk(self):
        with self.assertRaisesRegex(RuntimeErrorPin, "iphoneos_sdk"):
            required_runtime(self.toolchain(""))


class AvailabilityTests(unittest.TestCase):
    def test_exact_match_available_list_shape(self):
        payload = {"runtimes": [{"identifier": IDENT, "isAvailable": True}]}
        self.assertTrue(runtime_available(payload, IDENT))

    def test_exact_match_available_dict_shape(self):
        payload = {"runtimes": {IDENT: [{"identifier": IDENT, "isAvailable": True}]}}
        self.assertTrue(runtime_available(payload, IDENT))

    def test_prefix_runtime_never_satisfies_exact_pin(self):
        payload = {"runtimes": [{"identifier": IDENT + "-1", "isAvailable": True}]}
        self.assertFalse(runtime_available(payload, IDENT))

    def test_unavailable_entry_is_not_sufficient(self):
        payload = {"runtimes": [{"identifier": IDENT, "isAvailable": False}]}
        self.assertFalse(runtime_available(payload, IDENT))

    def test_unsupported_shape(self):
        self.assertFalse(runtime_available({"runtimes": "nonsense"}, IDENT))
        self.assertFalse(runtime_available({}, IDENT))


class CaptureTests(unittest.TestCase):
    def test_raw_capture_round_trips_to_exact_runtime_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "runtimes.json"
            raw = json.dumps({"runtimes": [{"identifier": IDENT, "isAvailable": True}]})

            def fake_runner(command, **kwargs):
                self.assertEqual(command, ["xcrun", "simctl", "list", "runtimes", "--json"])
                self.assertEqual(kwargs["timeout"], 60)
                self.assertEqual(kwargs["stderr"], subprocess.PIPE)
                return subprocess.CompletedProcess(command, 0, stdout=raw, stderr="")

            capture_runtimes(output, runner=fake_runner)
            self.assertEqual(output.read_text(), raw)
            self.assertTrue(runtime_available(json.loads(output.read_text()), IDENT))

    def test_capture_nonzero_exit_is_not_swallowed(self):
        def failing_runner(command, **kwargs):
            raise subprocess.CalledProcessError(1, command)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(subprocess.CalledProcessError):
                capture_runtimes(Path(directory) / "runtimes.json", runner=failing_runner)


if __name__ == "__main__":
    unittest.main()
