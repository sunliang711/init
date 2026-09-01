"""验证 consul-manager doctor 能读出实际配置取值，并对危险组合与失效引用报错。"""

import argparse
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "consul"))

from consul_tools import manager  # noqa: E402


MANAGED_CONFIG_CONSTANTS = ("TLS_CONFIG", "UI_CONFIG", "TELEMETRY_CONFIG", "DNS_CONFIG")


def install_args(**overrides) -> argparse.Namespace:
    base = dict(datacenter="dc1", bind="127.0.0.1", client="127.0.0.1", log_level="INFO",
                http_port=8500, grpc_port=8502, dns_port=8600, acl=True,
                acl_default_policy="deny", gossip_encrypt=True, ui=True, connect=True)
    base.update(overrides)
    return argparse.Namespace(**base)


class ConsulDoctorTest(unittest.TestCase):
    """把配置常量指向临时目录，避免读到真实 /opt/consul。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.config_dir = self.root / "consul.d"
        self.config_dir.mkdir()
        self._saved = {name: getattr(manager, name) for name in MANAGED_CONFIG_CONSTANTS}
        self._saved["CONFIG_DIR"] = manager.CONFIG_DIR
        self._saved["CONFIG_FILE"] = manager.CONFIG_FILE
        self._saved["install_text"] = manager.install_text
        self._saved["commit_managed_file"] = manager.commit_managed_file
        manager.CONFIG_DIR = self.config_dir
        manager.CONFIG_FILE = self.config_dir / "consul.hcl"
        for name in MANAGED_CONFIG_CONSTANTS:
            setattr(manager, name, self.config_dir / Path(self._saved[name]).name)
        # both writers normally shell out through install(1) and restart consul.service
        manager.install_text = lambda path, content, **kwargs: Path(path).write_text(content, encoding="utf-8")
        manager.commit_managed_file = lambda target, content: Path(target).write_text(content, encoding="utf-8")
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        for name, value in self._saved.items():
            setattr(manager, name, value)

    @staticmethod
    def _capture(func, *args) -> tuple[int, str]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = func(*args)
        return result, buffer.getvalue()

    def test_base_config_values_round_trip(self) -> None:
        manager.write_consul_config(install_args(datacenter="prod", bind="10.0.0.5"), "SECRET-GOSSIP-KEY=")

        values = manager.base_config_values()

        self.assertEqual(values["datacenter"], "prod")
        self.assertEqual(values["bind_addr"], "10.0.0.5")
        self.assertEqual(values["http_port"], "8500")
        self.assertEqual(values["grpc_port"], "8502")
        self.assertEqual(values["connect"], "true")
        self.assertEqual(values["acl_enabled"], "true")
        self.assertEqual(values["acl_default_policy"], "deny")

    def test_gossip_key_is_never_exposed(self) -> None:
        """只报告是否配置了 gossip 加密，绝不把密钥本身放进任何输出。"""
        manager.write_consul_config(install_args(), "SECRET-GOSSIP-KEY=")

        values = manager.base_config_values()
        _, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(values["gossip_encrypt"], "true")
        self.assertNotIn("SECRET-GOSSIP-KEY", str(values))
        self.assertNotIn("SECRET-GOSSIP-KEY", output)

    def test_gossip_encryption_absent_is_reported_false(self) -> None:
        manager.write_consul_config(install_args(gossip_encrypt=False), "")

        self.assertEqual(manager.base_config_values()["gossip_encrypt"], "false")

    def test_connect_without_grpc_port_fails(self) -> None:
        """--connect 开着但 grpc 端口是 -1，service mesh 静默失效。"""
        manager.write_consul_config(install_args(), "")
        manager.CONFIG_FILE.write_text(
            manager.CONFIG_FILE.read_text(encoding="utf-8").replace("grpc = 8502", "grpc = -1"),
            encoding="utf-8",
        )

        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("Connect is enabled but the gRPC port is disabled", output)

    def test_public_bind_without_acl_fails(self) -> None:
        manager.write_consul_config(install_args(acl=False, bind="0.0.0.0"), "")

        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("with ACL disabled", output)

    def test_local_bind_without_acl_is_not_a_failure(self) -> None:
        manager.write_consul_config(install_args(acl=False), "")

        failures, _ = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 0)

    def test_acl_allow_policy_warns(self) -> None:
        manager.write_consul_config(install_args(acl_default_policy="allow"), "")

        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 0)
        self.assertIn("default_policy is allow", output)

    def test_missing_base_config_fails(self) -> None:
        failures, output = self._capture(manager.doctor_base_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("Base config not readable", output)

    def test_tls_missing_certificate_fails(self) -> None:
        tls_dir = self.root / "tls"
        tls_dir.mkdir()
        (tls_dir / "ca.crt").write_text("", encoding="utf-8")
        manager.cmd_tls_enable(
            argparse.Namespace(ca_file=str(tls_dir / "ca.crt"), cert_file=str(tls_dir / "server.crt"),
                               key_file=str(tls_dir / "server.key"), verify_incoming=False,
                               verify_outgoing=True, verify_server_hostname=True, auto_encrypt=False)
        )

        failures, output = self._capture(manager.doctor_node_configuration)

        self.assertEqual(failures, 2)
        self.assertIn("TLS ca_file exists", output)
        self.assertIn("TLS cert_file missing", output)
        self.assertIn("TLS key_file missing", output)

    def test_ui_telemetry_dns_values_round_trip(self) -> None:
        manager.cmd_ui_enable(argparse.Namespace(metrics_provider="prometheus", metrics_proxy_base_url="",
                                                 dashboard_url_template=""))
        manager.cmd_telemetry_enable(argparse.Namespace(retention="48h", disable_hostname=True))
        manager.cmd_dns_enable(argparse.Namespace(recursor=["1.1.1.1"], allow_stale=True,
                                                  enable_truncate=True, only_passing=True))

        _, output = self._capture(manager.doctor_node_configuration)

        self.assertIn("metrics_provider prometheus", output)
        self.assertIn("prometheus_retention_time 48h", output)
        self.assertIn("only_passing true", output)
        self.assertIn("1.1.1.1", output)

    def test_unconfigured_fragments_are_not_failures(self) -> None:
        failures, output = self._capture(manager.doctor_node_configuration)

        self.assertEqual(failures, 0)
        for label in ("UI: not configured", "Telemetry: not configured",
                      "DNS: not configured", "TLS: not configured"):
            self.assertIn(label, output)


if __name__ == "__main__":
    unittest.main()
