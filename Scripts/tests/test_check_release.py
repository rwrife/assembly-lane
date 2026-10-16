import shutil
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from Scripts.check_release import check_icon, main, png_properties


def png_bytes(width: int, height: int, color_type: int) -> bytes:
    """Minimal structurally-valid PNG (color type 2 = RGB, 6 = RGBA)."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    rows = b""
    stride = width * (3 if color_type == 2 else 4)
    for _ in range(height):
        rows += b"\x00" + bytes(range(stride % 256)) * (stride // 256 + 1)
    idat = zlib.compress(rows[: height * (stride + 1)])
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


class PngHeaderTests(unittest.TestCase):
    def test_reads_rgb_header(self):
        self.assertEqual(png_properties(png_bytes(4, 4, 2)), (4, 4, 8, 2))

    def test_rejects_non_png(self):
        with self.assertRaises(ValueError):
            png_properties(b"not a png at all, really")


class RepoGateTests(unittest.TestCase):
    def test_real_repo_passes(self):
        repo = Path(__file__).resolve().parents[2]
        self.assertEqual(_run(repo), 0)


def _run(repo: Path) -> int:
    import sys

    original = sys.argv
    sys.argv = ["check_release.py", "--repo", str(repo)]
    try:
        return main()
    finally:
        sys.argv = original


class IconGateTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo, True)
        (self.repo / "AppStore").mkdir()
        self.icon = self.repo / "AppStore" / "icon.png"

    def failures(self):
        failures: list[str] = []
        check_icon(self.repo, failures)
        return failures

    def test_missing_icon_fails(self):
        self.assertTrue(any("missing" in f for f in self.failures()))

    def test_transparent_rgba_icon_fails(self):
        self.icon.write_bytes(png_bytes(1024, 1024, 6))
        self.assertTrue(any("opaque RGB" in f for f in self.failures()))

    def test_wrong_size_fails(self):
        self.icon.write_bytes(png_bytes(512, 512, 2))
        self.assertTrue(any("1024x1024" in f for f in self.failures()))

    def test_catalog_divergence_fails(self):
        self.icon.write_bytes(png_bytes(1024, 1024, 2))
        catalog = self.repo / "App" / "Assets.xcassets" / "AppIcon.appiconset"
        catalog.mkdir(parents=True)
        (catalog / "AppIcon.png").write_bytes(png_bytes(1024, 1024, 2) + b"drift")
        self.assertTrue(any("differ" in f for f in self.failures()))


if __name__ == "__main__":
    unittest.main()
