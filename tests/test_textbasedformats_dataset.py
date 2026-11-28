"""Integrity checks for the EPUB, KEPUB, and MOBI regression fixtures."""

import hashlib
import io
import shutil
import struct
import subprocess
import unittest
import zipfile
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).parent / "dataset-mangas" / "dataset-textbasedformats"
PAGES = ("00.png", "01.png", "02.png")
EPUB_ENTRIES = (
    "OEBPS/Images/kcc-0007-kcc-x.jpg",
    "OEBPS/Images/kcc-0008-kcc-x.jpg",
    "OEBPS/Images/kcc-0011-kcc-x.jpg",
)


def pixel_digest(data: bytes) -> tuple[tuple[int, int], bytes]:
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        return image.size, hashlib.sha256(image.convert("L").tobytes()).digest()


def mobi_jpeg_records(data: bytes):
    """Yield JPEG PalmDB records from a Mobipocket file."""
    if len(data) < 78:
        return
    record_count = struct.unpack_from(">H", data, 76)[0]
    table_end = 78 + record_count * 8
    if table_end > len(data):
        return
    offsets = [struct.unpack_from(">I", data, 78 + index * 8)[0] for index in range(record_count)]
    offsets.append(len(data))
    for start, end in zip(offsets, offsets[1:]):
        record = data[start:end]
        if record.startswith(b"\xff\xd8\xff"):
            yield record


class TextBasedFormatDatasetTest(unittest.TestCase):
    def fixture_digests(self, format_name: str):
        directory = ROOT / f"Bloom_Into_You_Vol_8_{format_name}"
        return [pixel_digest((directory / page).read_bytes()) for page in PAGES]

    def test_preview_images_decode_to_identical_pixels(self):
        expected = self.fixture_digests("EPUB")
        self.assertEqual(expected, self.fixture_digests("KEPUB"))
        self.assertEqual(expected, self.fixture_digests("MOBI"))

    def test_private_sources_are_ignored_but_previews_are_public(self):
        if not shutil.which("git"):
            self.skipTest("git is unavailable")
        directory = ROOT / "Bloom_Into_You_Vol_8_EPUB"
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", str(directory / "source.epub")],
            check=False,
        )
        self.assertEqual(0, ignored.returncode)
        for index in range(10):
            with self.subTest(page=index):
                preview = subprocess.run(
                    ["git", "check-ignore", "--no-index", "-q", str(directory / f"{index:02d}.png")],
                    check=False,
                )
                self.assertEqual(1 if index < 4 else 0, preview.returncode)

    def test_local_source_containers_reproduce_the_preview_pixels(self):
        sources = {
            "EPUB": ROOT / "Bloom_Into_You_Vol_8_EPUB" / "source.epub",
            "KEPUB": ROOT / "Bloom_Into_You_Vol_8_KEPUB" / "source.kepub.epub",
            "MOBI": ROOT / "Bloom_Into_You_Vol_8_MOBI" / "source.mobi",
        }
        missing = [str(path) for path in sources.values() if not path.exists()]
        if missing:
            self.skipTest("private source books are absent from this clone")

        for format_name in ("EPUB", "KEPUB"):
            with zipfile.ZipFile(sources[format_name]) as archive:
                decoded = [pixel_digest(archive.read(entry)) for entry in EPUB_ENTRIES]
            self.assertEqual(self.fixture_digests(format_name), decoded)

        mobi_digests = {pixel_digest(record) for record in mobi_jpeg_records(sources["MOBI"].read_bytes())}
        for expected in self.fixture_digests("MOBI"):
            self.assertIn(expected, mobi_digests)


if __name__ == "__main__":
    unittest.main()
