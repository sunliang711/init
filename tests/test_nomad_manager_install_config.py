"""验证 install 写出的基础配置，重点是 job_gc_threshold。"""

import argparse
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))

from nomad_tools import manager  # noqa: E402


class BaseConfigTest(unittest.TestCase):
    def setUp(self) -> None:
        self.written: dict[str, str] = {}
        self._saved = (manager.install_text, manager.run_root)
        manager.install_text = lambda path, content, **kwargs: self.written.__setitem__(str(path), content)
        manager.run_root = lambda *args, **kwargs: None
        self.addCleanup(lambda: setattr(manager, "install_text", self._saved[0]))
        self.addCleanup(lambda: setattr(manager, "run_root", self._saved[1]))

    def _config(self) -> str:
        return self.written[str(manager.CONFIG_DIR / "nomad.hcl")]

    def test_default_threshold_is_written(self) -> None:
        manager.write_nomad_config()

        self.assertIn(f'job_gc_threshold = "{manager.DEFAULT_JOB_GC_THRESHOLD}"', self._config())

    def test_threshold_sits_inside_the_server_block(self) -> None:
        """写到 client 或顶层都会被 Nomad 忽略或报错。"""
        manager.write_nomad_config()
        server = manager.hcl_block_body(self._config(), "server")

        self.assertIn("job_gc_threshold", server)
        self.assertNotIn("job_gc_threshold", manager.hcl_block_body(self._config(), "client"))

    def test_custom_threshold_is_used(self) -> None:
        manager.write_nomad_config("30m")

        self.assertIn('job_gc_threshold = "30m"', self._config())

    def test_invalid_duration_is_rejected_before_writing(self) -> None:
        with self.assertRaises(manager.CLIError) as caught:
            manager.write_nomad_config("forever")

        self.assertIn("Go duration", str(caught.exception))
        self.assertEqual(self.written, {}, "nothing may be written when the value is rejected")

    def test_bare_number_is_rejected(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.write_nomad_config("87600")

    def test_compound_durations_are_accepted(self) -> None:
        manager.write_nomad_config("1h30m")

        self.assertIn('job_gc_threshold = "1h30m"', self._config())

    def test_install_passes_the_flag_through(self) -> None:
        """解析器到 cmd_install 之间有一层 Namespace 转换，容易漏字段。"""
        args = manager.build_parser().parse_args(["install", "--job-gc-threshold", "72h"])

        self.assertEqual(args.job_gc_threshold, "72h")

    def test_install_help_states_the_default(self) -> None:
        import argparse as ap

        parser = manager.build_parser()
        install = next(a for a in parser._actions if isinstance(a, ap._SubParsersAction)).choices["install"]
        help_text = {a.option_strings[0]: (a.help or "") for a in install._actions if a.option_strings}

        self.assertIn(manager.DEFAULT_JOB_GC_THRESHOLD, help_text["--job-gc-threshold"])


if __name__ == "__main__":
    unittest.main()
