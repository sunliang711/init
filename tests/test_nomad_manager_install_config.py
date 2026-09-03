"""验证 install 写出的基础配置，重点是 job_gc_threshold。"""

import argparse
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
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
        return self.written[str(manager.NOMAD_CONFIG_FILE)]

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


class BaseConfigReadbackTest(unittest.TestCase):
    """写出去的基础配置要能逐字段读回来，doctor 和 status 才报得准。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self._saved = (manager.NOMAD_CONFIG_FILE, manager.install_text, manager.run_root)
        manager.NOMAD_CONFIG_FILE = self.root / "nomad.hcl"
        manager.install_text = lambda path, content, **kwargs: Path(path).write_text(content, encoding="utf-8")
        manager.run_root = lambda *args, **kwargs: None
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(lambda: [setattr(manager, n, v) for n, v in
                                 zip(("NOMAD_CONFIG_FILE", "install_text", "run_root"), self._saved)])

    @staticmethod
    def _capture(func, *args) -> tuple[int, str]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = func(*args)
        return result, buffer.getvalue()

    def test_every_field_round_trips(self) -> None:
        manager.write_nomad_config("72h")

        values = manager.base_config_values()

        self.assertEqual(values["datacenter"], "dc1")
        self.assertEqual(values["bind_addr"], "0.0.0.0")
        self.assertEqual(values["job_gc_threshold"], "72h")
        self.assertEqual(values["server"], "true")
        self.assertEqual(values["client"], "true")
        self.assertEqual(values["bootstrap_expect"], "1")
        self.assertEqual(values["acl"], "true")

    def test_server_and_client_enabled_do_not_bleed(self) -> None:
        """两个块里都有 enabled，按块作用域读才不会串。"""
        manager.write_nomad_config()
        text = manager.read_base_config_text()

        self.assertIn("job_gc_threshold", manager.hcl_block_body(text, "server"))
        self.assertNotIn("job_gc_threshold", manager.hcl_block_body(text, "client"))

    def test_default_install_passes_doctor(self) -> None:
        manager.write_nomad_config()

        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 0)
        self.assertIn(f"job_gc_threshold = {manager.DEFAULT_JOB_GC_THRESHOLD}", output)

    def test_public_bind_without_acl_fails(self) -> None:
        """Nomad 的 HTTP API 就在 bind_addr 上，和 Consul 的 client_addr 不同。"""
        manager.write_nomad_config()
        manager.NOMAD_CONFIG_FILE.write_text(
            manager.read_base_config_text().replace(
                "acl {\n  enabled = true", "acl {\n  enabled = false"),
            encoding="utf-8")

        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("HTTP API binds 0.0.0.0 with ACL disabled", output)

    def test_missing_base_config_fails(self) -> None:
        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("Base config not readable", output)

    def test_a_config_without_the_threshold_says_so(self) -> None:
        """旧节点的 nomad.hcl 没有这一项，应报出 Nomad 自身的默认值而不是留空。"""
        manager.write_nomad_config()
        manager.NOMAD_CONFIG_FILE.write_text(
            "\n".join(line for line in manager.read_base_config_text().splitlines()
                      if "job_gc_threshold" not in line), encoding="utf-8")

        _, output = self._capture(manager.doctor_base_configuration)

        self.assertIn("Nomad default 4h", output)


if __name__ == "__main__":
    unittest.main()
