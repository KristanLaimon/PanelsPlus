"""Exercise release installation and profile isolation without a GUI or network."""

import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "koreader.sh"
LAUNCHER = b'''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ["LAUNCH_RECORD"]).write_text(json.dumps({
    "profile": os.environ.get("KO_HOME"), "args": sys.argv[1:]
}))
sys.exit(int(os.environ.get("LAUNCH_EXIT", "0")))
'''


class KoreaderLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="koreader launcher ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.archive = self.root / "release.tar.xz"
        with tarfile.open(self.archive, "w:xz") as archive:
            info = tarfile.TarInfo("bin/koreader")
            info.mode = 0o755
            info.size = len(LAUNCHER)
            archive.addfile(info, io.BytesIO(LAUNCHER))
        self.write_tool("uname", '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.write_tool("curl", '''#!/bin/bash
printf '%s\n' "$*" >> "$DOWNLOAD_RECORD"
[[ "${DOWNLOAD_FAIL:-0}" == 0 ]] || exit 22
if [[ "$*" == *api.github.com* ]]; then
    if [[ "$*" == *'page=1' ]]; then cat "$RELEASE_PAGE"; else cat "$RELEASE_LAST_PAGE"; fi
    exit
fi
cp -- "$FIXTURE_ARCHIVE" "${@: -1}"
''')
        self.releases = self.root / "releases.json"
        self.releases.write_text(json.dumps([
            self.release("2025.10"), self.release("2025.04"),
            self.release("2026.01", prerelease=True),
            self.release("2025.09", arch="aarch64"),
            self.release("2025.08", draft=True),
        ]))
        self.last_page = self.root / "releases-last.json"
        self.last_page.write_text("[]")
        self.write_tool("koreader", LAUNCHER)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        KOREADER_INSTALL_ROOT=str(self.root / "config"),
                        FIXTURE_ARCHIVE=str(self.archive),
                        RELEASE_PAGE=str(self.releases),
                        RELEASE_LAST_PAGE=str(self.last_page),
                        DOWNLOAD_RECORD=str(self.root / "downloads"),
                        LAUNCH_RECORD=str(self.root / "launch.json"))
        self.env.pop("KO_HOME", None)

    def write_tool(self, name, content):
        path = self.bin / name
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        path.chmod(0o755)

    def run_script(self, *args, input=None):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                              input=input, text=True, capture_output=True, cwd=self.root)

    def version_dir(self, version="2025.04"):
        return self.root / "config" / f"koreader-_{version}"

    @staticmethod
    def release(version, arch="x86_64", **flags):
        return dict(tag_name=f"v{version}",
                    assets=[{"name": f"koreader-linux-{arch}-v{version}.tar.xz"}], **flags)

    def test_default_uses_system_installation_and_forwards_arguments(self):
        self.assertEqual(0, self.run_script().returncode)
        self.assertEqual({"profile": None, "args": []}, json.loads((self.root / "launch.json").read_text()))
        self.assertEqual(0, self.run_script("system", "book with spaces.cbz").returncode)
        self.assertEqual(["book with spaces.cbz"], json.loads((self.root / "launch.json").read_text())["args"])
        self.assertFalse((self.root / "config").exists())

    def test_install_is_cached_and_versions_use_separate_profiles(self):
        for version in ("v2025.04", "2025.04", "2025.10"):
            result = self.run_script("install", version)
            self.assertEqual(0, result.returncode, result.stderr)
        downloads = (self.root / "downloads").read_text().splitlines()
        self.assertEqual(2, len(downloads))
        self.assertIn("v2025.04/koreader-linux-x86_64-v2025.04.tar.xz", downloads[0])
        for version in ("2025.04", "2025.10"):
            plugin = self.version_dir(version) / "profile/plugins/panelsplus.koplugin"
            self.assertEqual(SCRIPT.parent, plugin.resolve())
            result = self.run_script("run", version, str(self.root / "test book.cbz"))
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual({"profile": str(self.version_dir(version) / "profile"),
                              "args": [str(self.root / "test book.cbz")]},
                             json.loads((self.root / "launch.json").read_text()))

    def test_menu_installs_default_release(self):
        result = self.run_script("menu", input="2\n\n0\n")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.version_dir() / "runtime/bin/koreader").exists())
        self.assertIn("  2025.04\n", result.stdout)

    def test_install_lists_compatible_stable_versions_and_accepts_selection(self):
        result = self.run_script("install", input="invalid\n1\n")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("1) 2025.10", result.stdout)
        self.assertIn("2) 2025.04", result.stdout)
        for hidden in ("2026.01", "2025.09", "2025.08"):
            self.assertNotIn(hidden, result.stdout)
        self.assertIn("Choose a listed number", result.stdout)
        self.assertTrue((self.version_dir("2025.10") / "runtime/bin/koreader").exists())

    def test_release_menu_can_cancel_without_installing(self):
        result = self.run_script("install", input="0\n")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse((self.root / "config").exists())

    def test_release_menu_follows_pagination(self):
        self.releases.write_text(json.dumps([self.release("2025.10")] + [
            self.release("2025.09", draft=True) for _ in range(99)
        ]))
        self.last_page.write_text(json.dumps([self.release("2025.04")]))
        result = self.run_script("install", input="\n")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("2) 2025.04", result.stdout)
        self.assertIn("page=2", (self.root / "downloads").read_text())
        self.assertTrue((self.version_dir() / "runtime/bin/koreader").exists())

    def test_release_listing_failure_does_not_install(self):
        self.env["DOWNLOAD_FAIL"] = "1"
        result = self.run_script("install", input="\n")
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "config").exists())

    def test_no_compatible_releases_are_reported(self):
        self.releases.write_text("[]")
        result = self.run_script("install", input="\n")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("No Linux x86_64 releases", result.stderr)
        self.assertFalse((self.root / "config").exists())

    def test_failed_download_leaves_no_runtime_and_can_retry(self):
        self.env["DOWNLOAD_FAIL"] = "1"
        self.assertNotEqual(0, self.run_script("install", "2025.04").returncode)
        self.assertEqual([], list(self.version_dir().iterdir()))
        self.env["DOWNLOAD_FAIL"] = "0"
        self.assertEqual(0, self.run_script("install", "2025.04").returncode)

    def test_existing_plugin_is_preserved(self):
        plugin = self.version_dir() / "profile/plugins/panelsplus.koplugin"
        plugin.mkdir(parents=True)
        marker = plugin / "keep.txt"
        marker.write_text("existing plugin")
        result = self.run_script("install", "2025.04")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Plugin already exists", result.stderr)
        self.assertEqual("existing plugin", marker.read_text())

    def test_invalid_or_missing_versions_fail_before_installation(self):
        for args in (("install", "../../other"), ("run",), ("run", "2025.04")):
            self.assertNotEqual(0, self.run_script(*args).returncode)
        self.assertFalse((self.root / "config").exists())

    def test_launch_exit_status_is_preserved(self):
        self.assertEqual(0, self.run_script("install", "2025.04").returncode)
        self.env["LAUNCH_EXIT"] = "7"
        self.assertEqual(7, self.run_script("run", "2025.04").returncode)


if __name__ == "__main__":
    unittest.main()
