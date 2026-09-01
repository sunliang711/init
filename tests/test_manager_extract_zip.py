"""验证解压保留归档里记录的权限位。

HashiCorp 的发布包里二进制是 0755，而 zipfile.extractall 会把它降成 0644，
于是解压出来的文件不可执行 —— consul install 的 gossip keygen 就栽在这上面。
"""

import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
for tool in ("nomad", "consul", "vault"):
    sys.path.insert(0, str(REPO_ROOT / "tools" / tool))

from consul_tools import common as consul_common  # noqa: E402
from nomad_tools import common as nomad_common  # noqa: E402
from vault_tools import common as vault_common  # noqa: E402


COMMONS = (("nomad", nomad_common), ("consul", consul_common), ("vault", vault_common))


class ExtractZipModeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        source = self.root / "binary"
        source.write_text("#!/bin/sh\necho ran\n", encoding="utf-8")
        os.chmod(source, 0o755)
        self.archive = self.root / "release.zip"
        with zipfile.ZipFile(self.archive, "w") as handle:
            handle.write(source, "binary")
            handle.writestr("notes.txt", "plain file")
            handle.writestr("nested/deeper.txt", "nested file")
        self.addCleanup(self.temp_dir.cleanup)

    def test_executable_bit_survives(self) -> None:
        for label, module in COMMONS:
            with self.subTest(tool=label):
                out = self.root / f"out-{label}"
                module.extract_zip(self.archive, out)
                mode = (out / "binary").stat().st_mode
                self.assertTrue(mode & stat.S_IXUSR, f"{label}: extracted binary must stay executable")

    def test_extracted_binary_actually_runs(self) -> None:
        out = self.root / "runnable"
        consul_common.extract_zip(self.archive, out)

        result = subprocess.run([str(out / "binary")], capture_output=True, text=True)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "ran")

    def test_plain_files_are_not_made_executable(self) -> None:
        out = self.root / "plain"
        consul_common.extract_zip(self.archive, out)

        self.assertFalse((out / "notes.txt").stat().st_mode & stat.S_IXUSR)

    def test_nested_members_are_extracted(self) -> None:
        out = self.root / "nested"
        consul_common.extract_zip(self.archive, out)

        self.assertEqual((out / "nested" / "deeper.txt").read_text(encoding="utf-8"), "nested file")

    def test_archive_without_recorded_modes_still_extracts(self) -> None:
        """Windows 上打的包 external_attr 可能为 0，不能因此报错。"""
        archive = self.root / "no-modes.zip"
        with zipfile.ZipFile(archive, "w") as handle:
            info = zipfile.ZipInfo("thing")
            info.external_attr = 0
            handle.writestr(info, "content")
        out = self.root / "no-modes"

        consul_common.extract_zip(archive, out)

        self.assertEqual((out / "thing").read_text(encoding="utf-8"), "content")


if __name__ == "__main__":
    unittest.main()
