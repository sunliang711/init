"""验证 vault jwt 的最小命令生成、链路图渲染与一致性检查。

apply / plan 会真的写 Vault 和 Nomad，因此这里只测不触碰外部服务的纯逻辑。
"""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))

from nomad_tools import manager  # noqa: E402


def profile(**overrides) -> dict:
    data = dict(manager.PROFILE_DEFAULTS)
    data.update({
        "profile": "default",
        "vault_addr": "http://127.0.0.1:8200",
        "nomad_addr": "http://127.0.0.1:4646",
        "nomad_jwks_url": manager.derived_jwks_url("http://127.0.0.1:4646"),
    })
    data.update(overrides)
    return data


class ApplyCommandTest(unittest.TestCase):
    """plan 的 Next: 行是用户会照抄的，必须最短且可执行。"""

    def test_defaults_are_omitted(self) -> None:
        command = manager.vault_jwt_apply_command(profile())

        self.assertIn("--profile default", command)
        self.assertIn("--vault-addr http://127.0.0.1:8200", command)
        self.assertIn("--nomad-addr http://127.0.0.1:4646", command)
        for flag in ("--auth-path", "--role", "--policy", "--aud", "--ttl",
                     "--secret-path", "--nomad-jwks-url"):
            self.assertNotIn(flag, command, f"{flag} equals its default and must be omitted")

    def test_command_uses_the_current_subcommand_name(self) -> None:
        """曾经输出 'vault-jwt apply'，该命令在链路重构后已不存在。"""
        command = manager.vault_jwt_apply_command(profile())

        self.assertIn("vault jwt apply", command)
        self.assertNotIn("vault-jwt", command)

    def test_non_default_values_are_kept(self) -> None:
        command = manager.vault_jwt_apply_command(
            profile(auth_path="jwt-prod", ttl="30m", secret_paths=["kv/data/app/*"])
        )

        self.assertIn("--auth-path jwt-prod", command)
        self.assertIn("--ttl 30m", command)
        self.assertIn("--secret-path 'kv/data/app/*'", command)
        self.assertNotIn("--role", command)
        self.assertNotIn("--policy", command)

    def test_derived_jwks_url_is_omitted_but_an_override_is_kept(self) -> None:
        self.assertNotIn("--nomad-jwks-url", manager.vault_jwt_apply_command(profile()))

        custom = manager.vault_jwt_apply_command(profile(nomad_jwks_url="http://10.0.0.9:4646/jwks"))

        self.assertIn("--nomad-jwks-url http://10.0.0.9:4646/jwks", custom)

    def test_emitted_command_parses(self) -> None:
        """照抄输出必须能被解析，而不是撞上 invalid choice。"""
        import shlex

        command = manager.vault_jwt_apply_command(profile(auth_path="jwt-prod"))
        argv = shlex.split(command)[1:]

        args = manager.build_parser().parse_args(argv)

        self.assertEqual(args.profile, "default")
        self.assertEqual(args.auth_path, "jwt-prod")


class WiringDiagramTest(unittest.TestCase):
    def test_every_stage_and_flag_appears(self) -> None:
        diagram = manager.jwt_wiring_diagram(profile(secret_paths=["kv/data/app/*"]))

        for fragment in ("vault.io", "auth/jwt-nomad", "nomad-workloads",
                         "kv/data/app/*", ".well-known/jwks.json"):
            self.assertIn(fragment, diagram)
        for flag in ("--aud", "--nomad-addr", "--auth-path", "--ttl", "--secret-path"):
            self.assertIn(flag, diagram)

    def test_link_notes_are_attached_to_their_stage(self) -> None:
        diagram = manager.jwt_wiring_diagram(
            profile(), {"auth": [("FAIL", "Vault validates against something else")]}
        )
        lines = diagram.split("\n")
        note = next(i for i, line in enumerate(lines) if "validates against something else" in line)
        mount = next(i for i, line in enumerate(lines) if "auth/jwt-nomad" in line)
        role = next(i for i, line in enumerate(lines) if "Vault role" in line)

        self.assertLess(mount, note, "the note must sit under its own stage")
        self.assertLess(note, role, "and above the next one")

    def test_defaults_only_profile_renders(self) -> None:
        diagram = manager.jwt_wiring_diagram(
            manager.default_jwt_profile("http://127.0.0.1:8200", "http://127.0.0.1:4646")
        )

        self.assertIn("kv/data/*", diagram)
        self.assertIn("vault.io", diagram)


class ConsistencyCheckTest(unittest.TestCase):
    """doctor 要抓的是「两侧对不上」，而不只是「某个对象不存在」。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self._saved = {name: getattr(manager, name) for name in
                       ("VAULT_JWT_PROFILE_DIR", "VAULT_CONFIG", "command_exists",
                        "wait_http", "vault_auth_type", "vault_read_json", "vault_cmd")}
        manager.VAULT_JWT_PROFILE_DIR = self.root
        manager.VAULT_CONFIG = self.root / "60-vault.hcl"
        manager.wait_http = lambda url, **kwargs: True
        manager.command_exists = lambda name: True
        manager.vault_auth_type = lambda data: "jwt"
        manager.vault_cmd = lambda data, command, **kwargs: type("R", (), {"returncode": 0, "stdout": ""})()
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(lambda: [setattr(manager, k, v) for k, v in self._saved.items()])

    def _write_profile(self, **overrides) -> None:
        (self.root / "default.json").write_text(json.dumps(profile(**overrides)), encoding="utf-8")

    def _write_nomad_config(self, auth_path: str = "jwt-nomad", aud: str = "vault.io") -> None:
        manager.VAULT_CONFIG.write_text(
            f'{manager.MANAGED_MARKER}\nvault {{\n  jwt_auth_backend_path = "{auth_path}"\n'
            f'  default_identity {{\n    aud = ["{aud}"]\n  }}\n}}\n',
            encoding="utf-8",
        )

    @staticmethod
    def _capture(func, *args) -> tuple[int, str]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            result = func(*args)
        return result, buffer.getvalue()

    def _vault_side(self, *, jwks: str, audiences: list[str], policies: list[str]) -> None:
        def read_json(data, path):
            if path.endswith("/config"):
                return {"jwks_url": jwks}
            return {"bound_audiences": audiences, "token_policies": policies}
        manager.vault_read_json = read_json

    def test_everything_agreeing_passes(self) -> None:
        self._write_profile()
        self._write_nomad_config()
        self._vault_side(jwks=manager.derived_jwks_url("http://127.0.0.1:4646"),
                         audiences=["vault.io"], policies=["nomad-workloads"])

        failures, _ = self._capture(manager.vault_jwt_status_impl, "default")

        self.assertEqual(failures, 0)

    def test_stale_jwks_url_in_vault_is_caught(self) -> None:
        """Vault 里记的 JWKS 地址指向旧的 Nomad，各对象都存在，但链路是断的。"""
        self._write_profile()
        self._write_nomad_config()
        self._vault_side(jwks="http://10.0.0.9:4646/.well-known/jwks.json",
                         audiences=["vault.io"], policies=["nomad-workloads"])

        failures, output = self._capture(manager.vault_jwt_status_impl, "default")

        self.assertEqual(failures, 1)
        self.assertIn("10.0.0.9", output)
        self.assertIn("not the URL above", output)

    def test_audience_mismatch_is_caught(self) -> None:
        self._write_profile()
        self._write_nomad_config()
        self._vault_side(jwks=manager.derived_jwks_url("http://127.0.0.1:4646"),
                         audiences=["something-else"], policies=["nomad-workloads"])

        failures, output = self._capture(manager.vault_jwt_status_impl, "default")

        self.assertEqual(failures, 1)
        self.assertIn("but Nomad signs vault.io", output)

    def test_role_pointing_at_another_policy_is_caught(self) -> None:
        self._write_profile()
        self._write_nomad_config()
        self._vault_side(jwks=manager.derived_jwks_url("http://127.0.0.1:4646"),
                         audiences=["vault.io"], policies=["some-other-policy"])

        failures, output = self._capture(manager.vault_jwt_status_impl, "default")

        self.assertEqual(failures, 1)
        self.assertIn("not nomad-workloads", output)

    def test_nomad_config_auth_path_mismatch_is_caught(self) -> None:
        self._write_profile()
        self._write_nomad_config(auth_path="jwt-old")
        self._vault_side(jwks=manager.derived_jwks_url("http://127.0.0.1:4646"),
                         audiences=["vault.io"], policies=["nomad-workloads"])

        failures, output = self._capture(manager.vault_jwt_status_impl, "default")

        self.assertEqual(failures, 1)
        self.assertIn("profile says jwt-nomad", output)


if __name__ == "__main__":
    unittest.main()
