"""Structural gate for .github/workflows/release.yml (issue #7 follow-up).

Stdlib-only on purpose: the release job runs `unittest discover` on the macOS
runner, whose system Python has no PyYAML. Line scanning is enough here.
"""

import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "release.yml"


def release_step_block() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    marker = "- name: Create GitHub release"
    start = text.index(marker)
    rest = text[start + len(marker) :]
    end = rest.find("\n      - name: ")
    return rest if end == -1 else rest[:end]


class ReleaseTagTests(unittest.TestCase):
    def test_release_step_targets_resolved_release_tag(self):
        block = release_step_block()
        # Manual dispatch runs on a branch, so GITHUB_REF_NAME would create a
        # release named "main"; the resolved RELEASE_TAG is the only safe ref.
        self.assertNotIn("$GITHUB_REF_NAME", block)
        self.assertIn('gh release create "$RELEASE_TAG"', block)
        self.assertIn('--target "$GITHUB_SHA"', block)
        self.assertIn("Verified GitHub release", block)

    def test_version_step_exports_release_tag(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('echo "RELEASE_TAG=$TAG"', text)


if __name__ == "__main__":
    unittest.main()
