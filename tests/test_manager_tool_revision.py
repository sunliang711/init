"""验证三个 manager 都记录并回读源码树的 git 版本。

「我这台机器上装的到底是哪个版本的工具」此前无从回答，只能靠 grep 某个功能字符串反推。
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "consul"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "vault"))

from consul_tools import manager as consul_manager  # noqa: E402
from nomad_tools import manager as nomad_manager  # noqa: E402
from vault_tools import manager as vault_manager  # noqa: E402


MANAGERS = (("nomad-manager", nomad_manager), ("consul-manager", consul_manager),
            ("vault-manager", vault_manager))


def git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(cwd), *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class SourceRevisionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp_dir.name) / "repo"
        (self.repo / "tools" / "thing").mkdir(parents=True)
        (self.repo / "tools" / "other").mkdir(parents=True)
        git(self.repo.parent, "init", "-q", "repo")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        (self.repo / "tools" / "thing" / "a.py").write_text("x\n", encoding="utf-8")
        (self.repo / "tools" / "other" / "b.py").write_text("y\n", encoding="utf-8")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "initial")
        self.tool_dir = self.repo / "tools" / "thing"
        self.addCleanup(self.temp_dir.cleanup)

    def test_clean_checkout_reports_a_revision(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                revision, dirty = module.source_tool_revision(self.tool_dir)
                self.assertRegex(revision, r"^[0-9a-f]{7,}$")
                self.assertFalse(dirty)

    def test_edit_inside_the_tool_dir_marks_it_dirty(self) -> None:
        (self.tool_dir / "a.py").write_text("changed\n", encoding="utf-8")

        for label, module in MANAGERS:
            with self.subTest(tool=label):
                _, dirty = module.source_tool_revision(self.tool_dir)
                self.assertTrue(dirty)

    def test_edit_elsewhere_in_the_repo_does_not(self) -> None:
        """脏标记必须限定在工具目录内，否则仓库里任何无关改动都会污染它。"""
        (self.repo / "tools" / "other" / "b.py").write_text("changed\n", encoding="utf-8")

        for label, module in MANAGERS:
            with self.subTest(tool=label):
                _, dirty = module.source_tool_revision(self.tool_dir)
                self.assertFalse(dirty, f"{label}: an unrelated file must not mark the tool dirty")

    def test_untracked_file_in_the_tool_dir_marks_it_dirty(self) -> None:
        (self.tool_dir / "scratch.py").write_text("", encoding="utf-8")

        for label, module in MANAGERS:
            with self.subTest(tool=label):
                _, dirty = module.source_tool_revision(self.tool_dir)
                self.assertTrue(dirty)

    def test_non_git_directory_is_unknown_not_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as plain:
            for label, module in MANAGERS:
                with self.subTest(tool=label):
                    self.assertEqual(module.source_tool_revision(Path(plain)), ("unknown", False))


class InstalledRevisionReadbackTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self._saved = {label: (module.INSTALL_METADATA_FILE, module.TOOL_VERSION_FILE)
                       for label, module in MANAGERS}
        for label, module in MANAGERS:
            module.INSTALL_METADATA_FILE = self.root / f"{label}-install.json"
            module.TOOL_VERSION_FILE = self.root / f"{label}-VERSION"
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        for label, module in MANAGERS:
            module.INSTALL_METADATA_FILE, module.TOOL_VERSION_FILE = self._saved[label]

    def test_revision_comes_from_install_metadata(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                module.INSTALL_METADATA_FILE.write_text(
                    json.dumps({"tool_revision": "abc1234", "tool_revision_dirty": False}), encoding="utf-8")
                self.assertEqual(module.read_installed_tool_revision(), "abc1234")

    def test_dirty_installs_are_marked(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                module.INSTALL_METADATA_FILE.write_text(
                    json.dumps({"tool_revision": "abc1234", "tool_revision_dirty": True}), encoding="utf-8")
                self.assertEqual(module.read_installed_tool_revision(), "abc1234-dirty")

    def test_version_file_is_the_fallback(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                module.TOOL_VERSION_FILE.write_text(
                    "tool=x\ntool_revision=def5678\ntool_revision_dirty=true\n", encoding="utf-8")
                self.assertEqual(module.read_installed_tool_revision(), "def5678-dirty")

    def test_missing_metadata_reads_unknown(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertEqual(module.read_installed_tool_revision(), "unknown")


if __name__ == "__main__":
    unittest.main()
