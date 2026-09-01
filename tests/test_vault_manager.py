"""验证 vault-manager 的纯逻辑：TLS 参数解析、密钥文件读取、配置回读、init 输出权限。

install / init / unseal 会真正下载、写入密钥、调用 vault，因此这里只测不触碰主机的部分。
"""

import argparse
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "vault"))

from vault_tools import manager  # noqa: E402


def install_args(**overrides) -> argparse.Namespace:
    base = dict(listen_address=manager.DEFAULT_LISTEN_ADDRESS, cluster_address=manager.DEFAULT_CLUSTER_ADDRESS,
                api_addr="", cluster_addr="", no_tls=False, tls_auto=False, tls_cert_file="",
                tls_key_file="", tls_ca_cert_file="", tls_dns=[], tls_ip=[], tls_common_name="vault-server")
    base.update(overrides)
    return argparse.Namespace(**base)


class InstallTlsResolutionTest(unittest.TestCase):
    def test_default_is_plain_http(self) -> None:
        settings = manager.resolve_install_tls(install_args())
        self.assertEqual(settings.mode, "disabled")
        self.assertEqual(settings.tls_disable, "true")
        self.assertEqual(settings.api_addr, manager.DEFAULT_VAULT_ADDR)

    def test_tls_auto_switches_addresses_to_https(self) -> None:
        settings = manager.resolve_install_tls(install_args(tls_auto=True))
        self.assertEqual(settings.mode, "auto")
        self.assertEqual(settings.tls_disable, "false")
        self.assertTrue(settings.api_addr.startswith("https://"))
        self.assertTrue(settings.cluster_addr.startswith("https://"))

    def test_tls_with_http_api_addr_is_rejected(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.resolve_install_tls(install_args(tls_auto=True, api_addr="http://10.0.0.5:8200"))

    def test_no_tls_conflicts_with_tls_options(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.resolve_install_tls(install_args(no_tls=True, tls_auto=True))

    def test_tls_auto_conflicts_with_custom_certificates(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.resolve_install_tls(install_args(tls_auto=True, tls_cert_file="/tmp/a.crt"))

    def test_auto_only_options_require_tls_auto(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.resolve_install_tls(install_args(tls_ip=["10.0.0.5"]))

    def test_custom_certificate_requires_both_files(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.resolve_install_tls(install_args(tls_cert_file="/tmp/only.crt"))

    def test_custom_certificate_must_exist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cert = Path(tmp) / "server.crt"
            cert.write_text("", encoding="utf-8")
            with self.assertRaises(manager.CLIError) as caught:
                manager.resolve_install_tls(install_args(tls_cert_file=str(cert),
                                                         tls_key_file=str(Path(tmp) / "missing.key")))
            self.assertIn("key file not found", str(caught.exception))

    def test_sans_always_cover_localhost_and_loopback(self) -> None:
        dns, ips = manager.default_tls_sans(["vault.example.com"], [], ["https://10.2.37.64:8200", ""])
        self.assertIn("localhost", dns)
        self.assertIn("vault.example.com", dns)
        self.assertIn("10.2.37.64", ips)
        self.assertIn("127.0.0.1", ips)
        self.assertIn("::1", ips)


class TokenAndKeyFileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.addCleanup(self.temp_dir.cleanup)

    def _write(self, name: str, content: str) -> Path:
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        return path

    def test_token_from_init_json(self) -> None:
        path = self._write("init.json", json.dumps({"root_token": "hvs.ROOT", "unseal_keys_b64": ["a"]}))
        self.assertEqual(manager.read_token_file(path), "hvs.ROOT")

    def test_token_from_plain_file(self) -> None:
        path = self._write("token", "hvs.PLAIN\n")
        self.assertEqual(manager.read_token_file(path), "hvs.PLAIN")

    def test_token_file_missing_raises(self) -> None:
        with self.assertRaises(manager.CLIError):
            manager.read_token_file(self.root / "nope")

    def test_unseal_keys_prefers_b64(self) -> None:
        path = self._write("init.json", json.dumps({"unseal_keys_b64": ["k1", "k2"], "unseal_keys_hex": ["h1"]}))
        self.assertEqual(manager.unseal_keys_from_file(path), ["k1", "k2"])

    def test_unseal_keys_fall_back_to_hex(self) -> None:
        path = self._write("init.json", json.dumps({"unseal_keys_hex": ["h1"]}))
        self.assertEqual(manager.unseal_keys_from_file(path), ["h1"])

    def test_unseal_keys_from_invalid_json_raises(self) -> None:
        path = self._write("init.json", "not json")
        with self.assertRaises(manager.CLIError):
            manager.unseal_keys_from_file(path)


class ConfigReadbackTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self._saved = {"CONFIG_FILE": manager.CONFIG_FILE, "install_text": manager.install_text}
        manager.CONFIG_FILE = self.root / "config.hcl"
        manager.install_text = lambda path, content, **kwargs: Path(path).write_text(content, encoding="utf-8")
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(lambda: [setattr(manager, k, v) for k, v in self._saved.items()])

    def test_config_values_round_trip(self) -> None:
        manager.write_vault_config(argparse.Namespace(
            api_addr="https://10.0.0.5:8200", cluster_addr="https://10.0.0.5:8201",
            listen_address="0.0.0.0:8200", cluster_address="0.0.0.0:8201",
            tls_disable="false", tls_cert_file="/tls/server.crt", tls_key_file="/tls/server.key"))

        values = manager.config_values()

        self.assertEqual(values["api_addr"], "https://10.0.0.5:8200")
        self.assertEqual(values["listen_address"], "0.0.0.0:8200")
        self.assertEqual(values["cluster_address"], "0.0.0.0:8201")
        self.assertEqual(values["tls_disable"], "false")
        self.assertEqual(values["tls_cert_file"], "/tls/server.crt")
        self.assertEqual(values["storage_path"], str(manager.DATA_DIR))

    def test_listener_and_storage_blocks_do_not_bleed(self) -> None:
        """listener 和 storage 都有 path/address 类的键，块作用域必须分开。"""
        manager.write_vault_config(argparse.Namespace(
            api_addr="http://127.0.0.1:8200", cluster_addr="http://127.0.0.1:8201",
            listen_address="127.0.0.1:8200", cluster_address="127.0.0.1:8201",
            tls_disable="true", tls_cert_file="", tls_key_file=""))

        values = manager.config_values()

        self.assertEqual(values["tls_cert_file"], "")
        self.assertTrue(values["node_id"].startswith("vault-"))
        self.assertNotIn("listener", values["storage_path"])

    def test_written_config_is_recognised_as_managed(self) -> None:
        manager.write_vault_config(argparse.Namespace(
            api_addr="http://127.0.0.1:8200", cluster_addr="http://127.0.0.1:8201",
            listen_address="0.0.0.0:8200", cluster_address="0.0.0.0:8201",
            tls_disable="true", tls_cert_file="", tls_key_file=""))

        self.assertTrue(manager.is_managed_file(manager.CONFIG_FILE))

    def test_unmanaged_config_is_refused(self) -> None:
        manager.CONFIG_FILE.write_text("ui = true\n", encoding="utf-8")

        with self.assertRaises(manager.CLIError):
            manager.ensure_managed_or_absent(manager.CONFIG_FILE)


class InitOutputPermissionTest(unittest.TestCase):
    """init 输出装着全部 unseal key 和 root token，权限必须被复查。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self._saved = manager.INIT_DIR
        manager.INIT_DIR = self.root / "init"
        manager.INIT_DIR.mkdir()
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(lambda: setattr(manager, "INIT_DIR", self._saved))

    @staticmethod
    def _capture(func) -> tuple[int, str]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = func()
        return result, buffer.getvalue()

    def test_world_readable_init_output_fails(self) -> None:
        path = manager.INIT_DIR / "vault-init.json"
        path.write_text("{}", encoding="utf-8")
        os.chmod(path, 0o644)

        failures, output = self._capture(manager.doctor_init_output)

        self.assertEqual(failures, 1)
        self.assertIn("must be 0600", output)

    def test_no_init_output_is_not_a_failure(self) -> None:
        failures, output = self._capture(manager.doctor_init_output)

        self.assertEqual(failures, 0)
        self.assertIn("no JSON files", output)


class TlsDoctorTest(unittest.TestCase):
    @staticmethod
    def _capture(func, *args) -> tuple[int, str]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = func(*args)
        return result, buffer.getvalue()

    def test_tls_disabled_warns_without_failing(self) -> None:
        failures, output = self._capture(manager.doctor_tls, {"tls_disable": "true"})

        self.assertEqual(failures, 0)
        self.assertIn("clear text", output)

    def test_missing_certificate_files_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            values = {"tls_disable": "false",
                      "tls_cert_file": str(Path(tmp) / "gone.crt"),
                      "tls_key_file": str(Path(tmp) / "gone.key")}

            failures, output = self._capture(manager.doctor_tls, values)

            self.assertEqual(failures, 2)
            self.assertIn("vault.service will not start", output)

    def test_tls_enabled_without_paths_fails(self) -> None:
        failures, _ = self._capture(manager.doctor_tls, {"tls_disable": "false", "tls_cert_file": "", "tls_key_file": ""})

        self.assertEqual(failures, 2)


class HealthCodeHintTest(unittest.TestCase):
    def test_seal_and_init_codes_map_to_a_fix(self) -> None:
        self.assertIn("unseal", manager.SEAL_HINTS[503][1])
        self.assertIn("init", manager.SEAL_HINTS[501][1])


if __name__ == "__main__":
    unittest.main()
