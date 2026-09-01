"""验证 nomad-manager doctor 能读出托管配置的实际取值，并对失效引用报 FAIL。"""

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


MANAGED_CONFIG_CONSTANTS = (
    "DOCKER_CONFIG", "TLS_CONFIG", "UI_CONFIG", "TELEMETRY_CONFIG", "RAW_EXEC_CONFIG",
    "DRIVER_DENYLIST_CONFIG", "META_CONFIG", "VAULT_CONFIG", "CONSUL_CONFIG", "CNI_CLIENT_CONFIG",
)


class DoctorTest(unittest.TestCase):
    """把所有托管配置常量指向临时目录，避免读到真实 /opt/nomad。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.config_dir = self.root / "nomad.d"
        self.config_dir.mkdir()
        self._saved = {name: getattr(manager, name) for name in MANAGED_CONFIG_CONSTANTS}
        self._saved["CONFIG_DIR"] = manager.CONFIG_DIR
        self._saved["commit_managed_file"] = manager.commit_managed_file
        manager.CONFIG_DIR = self.config_dir
        for name in MANAGED_CONFIG_CONSTANTS:
            setattr(manager, name, self.config_dir / Path(self._saved[name]).name)
        # writing normally validates the config and restarts nomad.service; here just drop the bytes
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

    def _write_host_volume(self, name: str, path: Path, read_only: bool = False) -> None:
        body = (
            'client {\n'
            f'  host_volume "{name}" {{\n'
            f'    path      = "{path}"\n'
            f'    read_only = {"true" if read_only else "false"}\n'
            "  }\n"
            "}"
        )
        (self.config_dir / f"70-host-volume-{name}.hcl").write_text(
            manager.managed_config(body), encoding="utf-8"
        )

    def test_docker_values_round_trip(self) -> None:
        manager.cmd_docker_enable(
            argparse.Namespace(allow_privileged=False, volumes=True, image_gc=True,
                               image_delay="72h", auth_config="/root/.docker/config.json")
        )
        values = manager.docker_config_values()
        self.assertEqual(values["allow_privileged"], "false")
        self.assertEqual(values["volumes"], "true")
        self.assertEqual(values["image_gc"], "true")
        self.assertEqual(values["image_delay"], "72h")
        self.assertEqual(values["auth_config"], "/root/.docker/config.json")

    def test_vault_and_consul_values_round_trip(self) -> None:
        manager.cmd_vault_enable(
            argparse.Namespace(address="https://vault:8200", namespace="", jwt_auth_backend_path="jwt-prod",
                               ca_file="", ca_path="", cert_file="", key_file="",
                               aud="vault.io", ttl="30m", env=False, file=True)
        )
        self.assertEqual(manager.vault_config_values()["jwt_auth_backend_path"], "jwt-prod")
        self.assertEqual(manager.vault_config_values()["ttl"], "30m")

        manager.cmd_consul_enable(
            argparse.Namespace(address="consul:8500", grpc_address="", ca_file="", cert_file="", key_file="",
                               ssl=True, verify=False, aud="consul.io", ttl="1h", workload_identity=False)
        )
        values = manager.consul_config_values()
        self.assertEqual(values["ssl"], "true")
        self.assertEqual(values["verify_ssl"], "false")
        self.assertEqual(values["workload_identity"], "false")

    def test_host_volume_missing_path_fails(self) -> None:
        present = self.root / "vol-data"
        present.mkdir()
        self._write_host_volume("data", present)
        self._write_host_volume("logs", self.root / "deleted", read_only=True)

        failures, output = self._capture(manager.doctor_host_volumes)

        self.assertEqual(failures, 1)
        self.assertIn("data: host path is usable", output)
        self.assertIn("logs: host path does not exist", output)
        self.assertIn("(read-only)", output)

    def test_host_volume_file_instead_of_directory_fails(self) -> None:
        not_a_dir = self.root / "regular-file"
        not_a_dir.write_text("", encoding="utf-8")
        self._write_host_volume("data", not_a_dir)

        failures, output = self._capture(manager.doctor_host_volumes)

        self.assertEqual(failures, 1)
        self.assertIn("is not a directory", output)

    def test_no_host_volumes_is_not_a_failure(self) -> None:
        failures, output = self._capture(manager.doctor_host_volumes)

        self.assertEqual(failures, 0)
        self.assertIn("No managed host volumes", output)

    def test_tls_missing_certificate_fails(self) -> None:
        tls_dir = self.root / "tls"
        tls_dir.mkdir()
        (tls_dir / "ca.crt").write_text("", encoding="utf-8")
        (tls_dir / "server.crt").write_text("", encoding="utf-8")
        manager.cmd_tls_enable(
            argparse.Namespace(ca_file=str(tls_dir / "ca.crt"), cert_file=str(tls_dir / "server.crt"),
                               key_file=str(tls_dir / "server.key"), http=True, rpc=True,
                               verify_server_hostname=False, verify_https_client=False)
        )

        failures, output = self._capture(manager.doctor_node_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("TLS key_file missing", output)
        self.assertIn("TLS ca_file exists", output)

    def test_raw_exec_enabled_is_reported(self) -> None:
        manager.cmd_raw_exec_enable(argparse.Namespace())

        _, output = self._capture(manager.doctor_node_configuration)

        self.assertIn("raw_exec is enabled", output)
        self.assertIn("no isolation", output)

    def test_denylist_and_meta_are_reported(self) -> None:
        manager.write_driver_denylist(["exec", "java"])
        manager.write_meta_pairs({"role": "web", "zone": "a"})

        _, output = self._capture(manager.doctor_node_configuration)

        self.assertIn("Denied drivers: exec, java", output)
        self.assertIn("role=web, zone=a", output)

    def test_cni_version_round_trip(self) -> None:
        manager.CNI_CLIENT_CONFIG.write_text(
            manager.cni_client_config_content("v1.6.2"), encoding="utf-8"
        )
        self.assertEqual(manager.installed_cni_version(), "v1.6.2")
        self.assertTrue(manager.is_managed_file(manager.CNI_CLIENT_CONFIG))

    def test_cni_content_without_version_is_unchanged(self) -> None:
        """未记录版本时输出必须和加版本注释之前逐字节一致，避免旧节点被判定为配置变更。"""
        self.assertEqual(
            manager.cni_client_config_content(),
            manager.managed_config(
                'client {\n'
                f'  cni_path       = "{manager.CNI_BIN_DIR}"\n'
                f'  cni_config_dir = "{manager.CNI_CONFIG_DIR}"\n'
                "}"
            ),
        )

    def test_unmanaged_config_is_reported_as_failure(self) -> None:
        manager.UI_CONFIG.write_text("ui {\n  enabled = true\n}\n", encoding="utf-8")

        failures, output = self._capture(manager.doctor_node_configuration)

        self.assertEqual(failures, 1)
        self.assertIn("is not managed", output)


if __name__ == "__main__":
    unittest.main()
