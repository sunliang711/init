"""验证 nomad-manager 与 consul-manager 顶层命令与各自 COMMAND_GROUPS 分组表保持一致。"""

import argparse
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "consul"))

from consul_tools import manager as consul_manager  # noqa: E402
from nomad_tools import manager as nomad_manager  # noqa: E402


MANAGERS = (("nomad-manager", nomad_manager), ("consul-manager", consul_manager))


class CommandGroupsTest(unittest.TestCase):
    """帮助文本由分组表生成，新增命令忘记归组时必须失败而不是静默消失。"""

    def test_every_registered_command_is_grouped(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                registered = set(module.registered_command_names(module.build_parser()))
                missing = sorted(registered - set(module.grouped_command_names()))
                self.assertEqual(missing, [], f"{label}: commands missing from COMMAND_GROUPS: {missing}")

    def test_every_grouped_command_is_registered(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                registered = set(module.registered_command_names(module.build_parser()))
                stale = sorted(set(module.grouped_command_names()) - registered)
                self.assertEqual(stale, [], f"{label}: COMMAND_GROUPS lists unknown commands: {stale}")

    def test_no_command_is_grouped_twice(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                grouped = module.grouped_command_names()
                duplicates = sorted({n for n in grouped if grouped.count(n) > 1})
                self.assertEqual(duplicates, [], f"{label}: commands in more than one group: {duplicates}")

    def test_grouped_order_matches_registration_order(self) -> None:
        """分组顺序即注册顺序，避免帮助文本和 --help 的实际解析顺序脱节。"""
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertEqual(
                    module.registered_command_names(module.build_parser()),
                    module.grouped_command_names(),
                    f"{label}: parser registration order differs from COMMAND_GROUPS order",
                )

    def test_root_help_lists_every_group_title(self) -> None:
        for label, module in MANAGERS:
            with self.subTest(tool=label):
                help_text = module.build_parser().format_help()
                for index, (title, _, _) in enumerate(module.COMMAND_GROUPS, start=1):
                    self.assertIn(f"{index}. {title}", help_text)

    def test_every_parser_formats_help(self) -> None:
        def walk(parser: argparse.ArgumentParser) -> int:
            parser.format_help()
            count = 1
            for action in parser._actions:
                if isinstance(action, argparse._SubParsersAction):
                    for sub in action.choices.values():
                        count += walk(sub)
            return count

        for label, module in MANAGERS:
            with self.subTest(tool=label):
                self.assertGreater(walk(module.build_parser()), 20)


if __name__ == "__main__":
    unittest.main()
