"""验证两个 manager 拒绝从已安装的自身副本更新工具文件。

从 /opt/<product>/lib/<product>-init-tools 里跑 install 或 tools update 时，
源目录就是目标目录，拷贝是空操作，旧代码会继续留在节点上而没有任何提示。
"""

import argparse
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "consul"))

from consul_tools import manager as consul_manager  # noqa: E402
from nomad_tools import manager as nomad_manager  # noqa: E402


MANAGERS = (("nomad-manager", nomad_manager), ("consul-manager", consul_manager))


class ToolSourceGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.tool_dir = self.root / "lib" / "init-tools"
        self.tool_dir.mkdir(parents=True)
        self._saved = {label: module.TOOL_DIR for label, module in MANAGERS}
        for _, module in MANAGERS:
            module.TOOL_DIR = self.tool_dir
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        for label, module in MANAGERS:
            module.TOOL_DIR = self._saved[label]

    def test_tool_dir_itself_is_detected(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertTrue(module.running_from_installed_copy(self.tool_dir))

    def test_directory_under_tool_dir_is_detected(self) -> None:
        nested = self.tool_dir / "nomad_tools"
        nested.mkdir()
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertTrue(module.running_from_installed_copy(nested))

    def test_source_checkout_is_not_detected(self) -> None:
        checkout = self.root / "src" / "tools" / "nomad"
        checkout.mkdir(parents=True)
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertFalse(module.running_from_installed_copy(checkout))

    def test_sibling_with_shared_prefix_is_not_detected(self) -> None:
        """路径前缀相同但不是子目录，不能误判。"""
        sibling = self.tool_dir.parent / "init-tools-backup"
        sibling.mkdir()
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertFalse(module.running_from_installed_copy(sibling))

    def test_tools_update_refuses_to_copy_onto_itself(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                saved = (module.require_linux, module.require_command,
                         module.current_script_dir, module.install_tool_snapshot)
                module.require_linux = lambda: None
                module.require_command = lambda command: None
                module.current_script_dir = lambda file_value: self.tool_dir / "package"
                called = []
                module.install_tool_snapshot = lambda *args: called.append(args)
                try:
                    with self.assertRaises(module.CLIError) as caught:
                        module.cmd_tools_update(argparse.Namespace(nomad_version=None, consul_version=None))
                    self.assertIn("Refusing to update from the installed copy", str(caught.exception))
                    self.assertEqual(called, [], f"{label}: snapshot must not be written")
                finally:
                    (module.require_linux, module.require_command,
                     module.current_script_dir, module.install_tool_snapshot) = saved

    def test_tools_update_proceeds_from_a_checkout(self) -> None:
        checkout = self.root / "checkout"
        checkout.mkdir()
        # each tool names its own version reader
        version_readers = {"nomad-manager": "read_installed_nomad_version",
                           "consul-manager": "read_installed_consul_version"}
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                reader = version_readers[label]
                names = ["require_linux", "require_command", "current_script_dir",
                         "install_tool_snapshot", "require_tool_source", reader]
                saved = {name: getattr(module, name) for name in names}
                module.require_linux = lambda: None
                module.require_command = lambda command: None
                module.current_script_dir = lambda file_value: checkout / "package"
                module.require_tool_source = lambda script_dir: None
                setattr(module, reader, lambda: "1.2.3")
                called = []
                module.install_tool_snapshot = lambda *args: called.append(args)
                try:
                    result = module.cmd_tools_update(argparse.Namespace(nomad_version=None, consul_version=None))
                    self.assertEqual(result, 0)
                    self.assertEqual(len(called), 1, f"{label}: snapshot should be written once")
                finally:
                    for name, value in saved.items():
                        setattr(module, name, value)


if __name__ == "__main__":
    unittest.main()
