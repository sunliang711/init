"""验证三个 manager 的 binary 升级流程：版本判断、计划输出与版本化布局。

升级要动的是正在被 systemd 执行的文件，所以关键不变量是「切换用 rename、旧版本留在盘上」，
这些在真机上很难复现，只能在这里锁死。
"""

import argparse
import builtins
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "nomad"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "consul"))
sys.path.insert(0, str(REPO_ROOT / "tools" / "vault"))

from consul_tools import common as consul_common  # noqa: E402
from consul_tools import manager as consul_manager  # noqa: E402
from nomad_tools import common as nomad_common  # noqa: E402
from nomad_tools import manager as nomad_manager  # noqa: E402
from vault_tools import common as vault_common  # noqa: E402
from vault_tools import manager as vault_manager  # noqa: E402


MANAGERS = (
    ("nomad-manager", nomad_manager, nomad_common, "nomad", "Nomad"),
    ("consul-manager", consul_manager, consul_common, "consul", "Consul"),
    ("vault-manager", vault_manager, vault_common, "vault", "Vault"),
)


def upgrade_args(**overrides: object) -> argparse.Namespace:
    values: dict[str, object] = {
        "version": "latest",
        "keep": 2,
        "allow_downgrade": False,
        "dry_run": True,
        "yes": True,
        "address": "",
        "token": "",
        "token_file": "",
        "addr": "",
        "ca_cert": "",
        "namespace": "",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class UpgradeCommandTest(unittest.TestCase):
    """升级命令在 --dry-run 之前就要做完所有判断，此时不允许有任何特权操作。"""

    def prepare(self, module: object, name: str, installed: str, resolved: str, recorded: str = "") -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        bin_path = root / "bin" / name
        bin_path.parent.mkdir(parents=True)
        bin_path.write_text("binary")
        saved = {
            "BIN_PATH": module.BIN_PATH,
            "BINARY_VERSION_DIR": module.BINARY_VERSION_DIR,
            "require_linux": module.require_linux,
            "require_command": module.require_command,
            "detect_arch": module.detect_arch,
            "installed_binary_version": module.installed_binary_version,
            "resolve_upgrade_target": module.resolve_upgrade_target,
            "run_root": module.run_root,
            f"read_installed_{name}_version": getattr(module, f"read_installed_{name}_version"),
            "record_upgrade_metadata": module.record_upgrade_metadata,
        }
        self.records: list[tuple[str, str]] = []
        self.addCleanup(lambda: [setattr(module, key, value) for key, value in saved.items()])
        module.BIN_PATH = bin_path
        module.BINARY_VERSION_DIR = bin_path.parent / "versions"
        module.require_linux = lambda: None
        module.require_command = lambda command: None
        module.detect_arch = lambda: "amd64"
        module.installed_binary_version = lambda: installed
        module.resolve_upgrade_target = lambda requested: resolved
        module.run_root = lambda *args, **kwargs: self.fail("a rejected or dry-run upgrade must not touch the node")
        setattr(module, f"read_installed_{name}_version", lambda: recorded or installed)
        module.record_upgrade_metadata = lambda old, new: self.records.append((old, new))
        return bin_path

    def test_dry_run_shows_the_warnings_the_real_run_would_print(self) -> None:
        """跨小版本和多 peer 的告警只在 --dry-run 里看不到，等于没有预演。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.2.0", "1.5.0")
                errors = io.StringIO()

                with redirect_stdout(io.StringIO()), redirect_stderr(errors):
                    module.cmd_upgrade(upgrade_args())

                self.assertIn("skips 2 minor release(s)", errors.getvalue())

    def test_dry_run_prints_the_plan_and_changes_nothing(self) -> None:
        for label, module, _, name, product in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.2.0", "1.3.0")
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    self.assertEqual(module.cmd_upgrade(upgrade_args()), 0)

                plan = buffer.getvalue()
                self.assertIn(f"{product} upgrade plan:", plan)
                self.assertIn("1.2.0", plan)
                self.assertIn("1.3.0", plan)
                self.assertIn(str(module.BIN_PATH), plan)
                self.assertIn(f"{name}.service", plan)
                self.assertFalse(module.BINARY_VERSION_DIR.exists())

    def test_plan_says_what_is_left_alone(self) -> None:
        """升级只换 binary，配置和数据不动——这句必须写在计划里，否则没人敢跑。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.2.0", "1.3.0")
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    module.cmd_upgrade(upgrade_args())

                self.assertIn("Left untouched:", buffer.getvalue())

    def test_vault_plan_warns_that_the_restart_seals(self) -> None:
        """重启后 Vault 必然是 sealed，事先不说清楚就等于把节点弄丢。"""
        self.prepare(vault_manager, "vault", "1.2.0", "1.3.0")
        buffer = io.StringIO()

        with redirect_stdout(buffer):
            vault_manager.cmd_upgrade(upgrade_args())

        self.assertIn("seals it", buffer.getvalue())

    def test_downgrade_is_refused_without_the_flag(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.3.0", "1.2.0")

                with self.assertRaises(module.CLIError) as caught:
                    module.cmd_upgrade(upgrade_args())

                self.assertIn("--allow-downgrade", str(caught.exception))

    def test_downgrade_plan_warns_about_stored_state(self) -> None:
        """二进制能换回去，raft 里已经被新版本写过的状态换不回去。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.3.0", "1.2.0")
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    module.cmd_upgrade(upgrade_args(allow_downgrade=True))

                self.assertIn("Downgrade:", buffer.getvalue())

    def test_same_version_is_a_no_op(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.3.0", "1.3.0")
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    self.assertEqual(module.cmd_upgrade(upgrade_args(dry_run=False)), 0)

                self.assertNotIn("upgrade plan", buffer.getvalue())
                self.assertEqual(self.records, [])

    def test_same_version_settles_a_drifted_record(self) -> None:
        """doctor 在 binary 与记录不一致时让人来跑 upgrade，这条路径必须真的把记录改掉。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.3.0", "1.3.0", recorded="1.1.0")

                with redirect_stdout(io.StringIO()):
                    self.assertEqual(module.cmd_upgrade(upgrade_args(dry_run=False)), 0)

                self.assertEqual(self.records, [("1.1.0", "1.3.0")])

    def test_missing_install_is_reported_before_anything_downloads(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                bin_path = self.prepare(module, name, "1.2.0", "1.3.0")
                bin_path.unlink()

                with self.assertRaises(module.CLIError) as caught:
                    module.cmd_upgrade(upgrade_args())

                self.assertIn("install", str(caught.exception))

    def test_keep_must_leave_the_running_release(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.prepare(module, name, "1.2.0", "1.3.0")

                with self.assertRaises(module.CLIError):
                    module.cmd_upgrade(upgrade_args(keep=0))

    def test_upgrade_is_registered_with_usable_defaults(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                args = module.build_parser().parse_args(["upgrade", "--dry-run"])

                self.assertIs(args.func, module.cmd_upgrade)
                self.assertEqual(args.version, "latest")
                self.assertEqual(args.keep, 2)
                self.assertFalse(args.allow_downgrade)


class StagedBinaryTest(unittest.TestCase):
    """新版本先落到版本目录并自检，链接切换之前发现问题才不会带走正在跑的服务。"""

    def stub(self, module: object, reported: str) -> list[list[str]]:
        calls: list[list[str]] = []
        saved = (module.run_root, module.run)
        self.addCleanup(lambda: (setattr(module, "run_root", saved[0]), setattr(module, "run", saved[1])))
        module.run_root = lambda args, **kwargs: calls.append(list(args))
        module.run = lambda args, **kwargs: subprocess.CompletedProcess(list(args), 0, reported, "")
        return calls

    def test_a_mismatched_archive_is_rejected(self) -> None:
        for label, module, _, name, product in MANAGERS:
            with self.subTest(tool=label):
                self.stub(module, f"{product} v1.2.0\n")

                with self.assertRaises(module.CLIError) as caught:
                    module.stage_binary(Path("/tmp/staging"), "1.3.0")

                self.assertIn("1.3.0", str(caught.exception))

    def test_a_matching_archive_lands_under_its_version(self) -> None:
        for label, module, _, name, product in MANAGERS:
            with self.subTest(tool=label):
                self.stub(module, f"{product} v1.3.0\n")

                staged = module.stage_binary(Path("/tmp/staging"), "1.3.0")

                self.assertEqual(staged, module.BINARY_VERSION_DIR / f"{name}-1.3.0")


class UpgradeFlowTest(unittest.TestCase):
    """成功、回滚、旧布局迁移三条路径，真机上都不好复现。"""

    def prepare(self, module: object, name: str, *, restart_fails: bool, linked: bool,
                error: BaseException | None = None) -> list[tuple]:
        events: list[tuple] = []
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        version_dir = Path(temp.name) / "versions"
        version_dir.mkdir()
        previous = version_dir / f"{name}-1.2.0"
        previous.write_text("binary")
        bin_path = Path(temp.name) / name
        bin_path.write_text("binary")
        restart_name = f"restart_{name}_service"
        download_name = f"download_{name}"
        saved = {
            key: getattr(module, key)
            for key in (
                "BIN_PATH", "BINARY_VERSION_DIR", "require_linux", "require_command", "detect_arch",
                "installed_binary_version", "resolve_upgrade_target", "create_install_tmpdir", "stage_binary",
                "atomic_symlink", "linked_binary_path", "adopt_versioned_binary_layout",
                "record_upgrade_metadata", "prune_binary_versions", "confirm_upgrade",
                restart_name, download_name,
            )
        }

        self.addCleanup(lambda: [setattr(module, key, value) for key, value in saved.items()])

        def restart(*_: object) -> None:
            """只有新版本那次重启失败，回滚那次要能起来。"""
            events.append(("restart",))
            if restart_fails and len([event for event in events if event[0] == "restart"]) == 1:
                raise error or module.CLIError("service failed to start")

        module.BIN_PATH = bin_path
        module.BINARY_VERSION_DIR = version_dir
        module.require_linux = lambda: None
        module.require_command = lambda command: None
        module.detect_arch = lambda: "amd64"
        module.installed_binary_version = lambda: "1.2.0"
        module.resolve_upgrade_target = lambda requested: "1.3.0"
        module.create_install_tmpdir = lambda prefix: Path(tempfile.mkdtemp(dir=temp.name))
        module.stage_binary = lambda tmpdir, version: version_dir / f"{name}-{version}"
        module.atomic_symlink = lambda target, link: events.append(("link", Path(target).name))
        module.linked_binary_path = lambda path: previous if linked else None
        module.adopt_versioned_binary_layout = lambda *args: (events.append(("migrate",)), previous)[1]
        module.record_upgrade_metadata = lambda old, new: events.append(("record", old, new))
        module.prune_binary_versions = (
            lambda *args, **kwargs: events.append(("prune", kwargs["keep"], Path(kwargs["current"]).name)) or []
        )
        module.confirm_upgrade = lambda assume_yes: None
        setattr(module, restart_name, restart)
        setattr(module, download_name, lambda version, arch, tmpdir: events.append(("download", version)))
        if hasattr(module, "warn_on_multiple_servers"):
            saved["warn_on_multiple_servers"] = module.warn_on_multiple_servers
            module.warn_on_multiple_servers = lambda address, token: None
        return events

    def test_a_successful_upgrade_switches_once_and_records_it(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                events = self.prepare(module, name, restart_fails=False, linked=True)
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    self.assertEqual(module.cmd_upgrade(upgrade_args(dry_run=False)), 0)

                self.assertEqual(
                    events,
                    [
                        ("download", "1.3.0"),
                        ("link", f"{name}-1.3.0"),
                        ("restart",),
                        ("record", "1.2.0", "1.3.0"),
                        ("prune", 2, f"{name}-1.3.0"),
                    ],
                )

    def test_a_failed_restart_goes_back_to_the_previous_release(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                events = self.prepare(module, name, restart_fails=True, linked=True)

                with self.assertRaises(module.CLIError) as caught, redirect_stdout(io.StringIO()):
                    module.cmd_upgrade(upgrade_args(dry_run=False))

                self.assertIn("rolled back", str(caught.exception))
                self.assertEqual(
                    [event for event in events if event[0] == "link"],
                    [("link", f"{name}-1.3.0"), ("link", f"{name}-1.2.0")],
                )
                self.assertNotIn("record", [event[0] for event in events])

    def test_a_failing_systemctl_also_triggers_the_rollback(self) -> None:
        """restart 里第一步是 run_root(systemctl restart)，它抛的是 CalledProcessError 而不是 CLIError。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                failure = subprocess.CalledProcessError(1, ["systemctl", "restart", name])
                events = self.prepare(module, name, restart_fails=True, linked=True, error=failure)

                with self.assertRaises(module.CLIError) as caught, redirect_stdout(io.StringIO()):
                    module.cmd_upgrade(upgrade_args(dry_run=False))

                self.assertIn("rolled back", str(caught.exception))
                self.assertEqual(
                    [event for event in events if event[0] == "link"],
                    [("link", f"{name}-1.3.0"), ("link", f"{name}-1.2.0")],
                )

    def test_an_older_plain_install_is_converted_before_the_switch(self) -> None:
        """install 早期把 binary 写成普通文件，不先搬走就没有可回退的旧版本。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                events = self.prepare(module, name, restart_fails=False, linked=False)
                buffer = io.StringIO()

                with redirect_stdout(buffer):
                    module.cmd_upgrade(upgrade_args(dry_run=False))

                self.assertEqual(events[0], ("migrate",))


class RecordedVersionTest(unittest.TestCase):
    """升级完成后 doctor 和 status 必须读到新版本，否则会一直提示版本漂移。"""

    def patch(self, module: object, name: str, metadata: dict | None) -> dict[str, str]:
        written: dict[str, str] = {}
        version_file = Path(tempfile.mkdtemp()) / "VERSION"
        version_file.write_text(f"tool={name}-manager\n{name}_version=1.2.0\ntool_revision=abc1234\n")
        saved = {key: getattr(module, key) for key in
                 ("read_install_metadata", "install_text", "run_root", "TOOL_VERSION_FILE")}
        self.addCleanup(lambda: [setattr(module, key, value) for key, value in saved.items()])
        module.read_install_metadata = lambda: dict(metadata) if metadata else {}
        module.install_text = lambda path, content, **kwargs: written.__setitem__(str(path), content)
        module.run_root = lambda args, **kwargs: subprocess.CompletedProcess(list(args), 1, "", "")
        module.TOOL_VERSION_FILE = version_file
        return written

    def test_the_recorded_version_moves_and_the_rest_of_the_record_survives(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                written = self.patch(module, name, {f"{name}_version": "1.2.0", "tool_revision": "abc1234"})

                module.record_upgrade_metadata("1.2.0", "1.3.0")

                recorded = json.loads(written[str(module.INSTALL_METADATA_FILE)])
                self.assertEqual(recorded[f"{name}_version"], "1.3.0")
                self.assertEqual(recorded[f"previous_{name}_version"], "1.2.0")
                self.assertEqual(recorded["tool_revision"], "abc1234")
                self.assertIn("upgraded_at", recorded)

    def test_the_version_file_follows_so_the_fallback_does_not_lie(self) -> None:
        """install.json 读不到时 doctor 回落到 VERSION，它留在旧版本就等于记录永远错。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                written = self.patch(module, name, {f"{name}_version": "1.2.0"})

                module.record_upgrade_metadata("1.2.0", "1.3.0")

                version_file = written[str(module.TOOL_VERSION_FILE)]
                self.assertIn(f"{name}_version=1.3.0", version_file)
                self.assertIn("tool_revision=abc1234", version_file)

    def test_a_root_only_state_directory_is_read_through_sudo(self) -> None:
        """sudoer 直接读不了 0750 的 state 目录，不走 sudo 就会静默跳过记录。"""
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                written = self.patch(module, name, None)
                module.run_root = lambda args, **kwargs: subprocess.CompletedProcess(
                    list(args), 0, json.dumps({f"{name}_version": "1.2.0", "root_dir": "/opt"}), ""
                )

                module.record_upgrade_metadata("1.2.0", "1.3.0")

                recorded = json.loads(written[str(module.INSTALL_METADATA_FILE)])
                self.assertEqual(recorded[f"{name}_version"], "1.3.0")
                self.assertEqual(recorded["root_dir"], "/opt")

    def test_an_unreadable_record_warns_instead_of_writing_a_stub(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                written = self.patch(module, name, None)

                module.record_upgrade_metadata("1.2.0", "1.3.0")

                self.assertEqual(written, {})


class ResolveTargetTest(unittest.TestCase):
    """install 解析不到最新版可以退回内置默认值，升级不行：那会把在跑的节点搬到没人要的版本。"""

    def patch(self, module: object, failure: Exception) -> None:
        saved = module.fetch_latest_version
        self.addCleanup(lambda: setattr(module, "fetch_latest_version", saved))

        def fetch() -> str:
            raise failure

        module.fetch_latest_version = fetch

    def test_an_unreachable_release_index_is_an_error(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.patch(module, OSError("connection refused"))

                with self.assertRaises(module.CLIError) as caught:
                    module.resolve_upgrade_target("latest")

                self.assertIn("--version", str(caught.exception))

    def test_install_keeps_its_fallback(self) -> None:
        for label, module, _, name, _ in MANAGERS:
            with self.subTest(tool=label):
                self.patch(module, OSError("connection refused"))

                self.assertEqual(
                    module.resolve_version("latest"),
                    getattr(module, f"DEFAULT_{name.upper()}_VERSION"),
                )

    def test_an_explicit_version_is_validated(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.assertEqual(module.resolve_upgrade_target("v1.4.2"), "1.4.2")
                with self.assertRaises(module.CLIError):
                    module.resolve_upgrade_target("1.4")


class ConfirmUpgradeTest(unittest.TestCase):
    def answer(self, value: object) -> None:
        saved = builtins.input
        self.addCleanup(lambda: setattr(builtins, "input", saved))

        def ask(prompt: str = "") -> str:
            if isinstance(value, BaseException):
                raise value
            return str(value)

        builtins.input = ask

    def test_anything_other_than_yes_cancels(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.answer("y")

                with self.assertRaises(module.CLIError):
                    module.confirm_upgrade(False)

    def test_a_non_interactive_run_is_told_about_yes(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.answer(EOFError())

                with self.assertRaises(module.CLIError) as caught:
                    module.confirm_upgrade(False)

                self.assertIn("--yes", str(caught.exception))

    def test_yes_skips_the_prompt(self) -> None:
        for label, module, _, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.answer(AssertionError("--yes must not prompt"))

                self.assertIsNone(module.confirm_upgrade(True))


class BinaryLayoutTest(unittest.TestCase):
    """版本化布局的两个不变量：切换不经过「先删后建」，旧版本按版本号留在盘上。"""

    def record(self, common: object) -> list[list[str]]:
        calls: list[list[str]] = []
        saved = common.run_root
        self.addCleanup(lambda: setattr(common, "run_root", saved))
        common.run_root = lambda args, **kwargs: calls.append(list(args))
        return calls

    def test_switching_never_unlinks_the_live_path(self) -> None:
        """ln -sfn 会先删再建，systemd 正好在这个窗口启动就找不到文件。"""
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                calls = self.record(common)

                common.atomic_symlink(f"/opt/{name}/bin/versions/{name}-1.3.0", f"/opt/{name}/bin/{name}")

                self.assertEqual(
                    calls,
                    [
                        ["ln", "-sfn", f"/opt/{name}/bin/versions/{name}-1.3.0", f"/opt/{name}/bin/.{name}.new"],
                        ["mv", "-Tf", f"/opt/{name}/bin/.{name}.new", f"/opt/{name}/bin/{name}"],
                    ],
                )

    def test_a_plain_install_is_moved_into_the_versioned_layout(self) -> None:
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                calls = self.record(common)

                target = common.adopt_versioned_binary_layout(
                    f"/opt/{name}/bin/{name}", f"/opt/{name}/bin/versions", name, "1.2.0"
                )

                self.assertEqual(target, Path(f"/opt/{name}/bin/versions/{name}-1.2.0"))
                self.assertIn(["mv", "-Tf", f"/opt/{name}/bin/{name}", str(target)], calls)
                self.assertEqual(calls[-1][:2], ["mv", "-Tf"])

    def test_version_parsing_rejects_what_cannot_be_compared(self) -> None:
        for label, _, common, _, _ in MANAGERS:
            with self.subTest(tool=label):
                self.assertEqual(common.version_tuple("v1.20.3"), (1, 20, 3))
                self.assertLess(common.version_tuple("1.9.0"), common.version_tuple("1.10.0"))
                with self.assertRaises(common.CLIError):
                    common.version_tuple("latest")


class PruneVersionsTest(unittest.TestCase):
    def version_dir(self) -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        return Path(temp.name)

    def write(self, directory: Path, name: str, mtime: int) -> Path:
        path = directory / name
        path.write_text("binary")
        os.utime(path, (mtime, mtime))
        return path

    def test_the_oldest_releases_go_and_the_running_one_stays(self) -> None:
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                directory = self.version_dir()
                removed: list[Path] = []
                saved = common.safe_remove_path
                self.addCleanup(lambda saved=saved, common=common: setattr(common, "safe_remove_path", saved))
                common.safe_remove_path = lambda path: (removed.append(Path(path)), Path(path).unlink())
                old = self.write(directory, f"{name}-1.1.0", 1_000)
                middle = self.write(directory, f"{name}-1.2.0", 2_000)
                current = self.write(directory, f"{name}-1.3.0", 3_000)

                common.prune_binary_versions(directory, name, keep=2, current=current)

                self.assertEqual(removed, [old])
                self.assertTrue(middle.is_file())
                self.assertTrue(current.is_file())

    def test_keeping_one_leaves_only_the_running_release(self) -> None:
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                directory = self.version_dir()
                removed: list[Path] = []
                saved = common.safe_remove_path
                self.addCleanup(lambda saved=saved, common=common: setattr(common, "safe_remove_path", saved))
                common.safe_remove_path = lambda path: (removed.append(Path(path)), Path(path).unlink())
                old = self.write(directory, f"{name}-1.1.0", 1_000)
                middle = self.write(directory, f"{name}-1.2.0", 2_000)
                current = self.write(directory, f"{name}-1.3.0", 3_000)

                common.prune_binary_versions(directory, name, keep=1, current=current)

                self.assertEqual(sorted(removed), sorted([old, middle]))
                self.assertTrue(current.is_file())

    def test_the_running_release_survives_even_when_it_is_the_oldest_file(self) -> None:
        """current 参数存在的唯一理由就是这个：刚装好的那份可能不是最新 mtime。"""
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                directory = self.version_dir()
                saved = common.safe_remove_path
                self.addCleanup(lambda saved=saved, common=common: setattr(common, "safe_remove_path", saved))
                common.safe_remove_path = lambda path: Path(path).unlink()
                current = self.write(directory, f"{name}-1.1.0", 1_000)
                self.write(directory, f"{name}-1.2.0", 2_000)
                self.write(directory, f"{name}-1.3.0", 3_000)

                common.prune_binary_versions(directory, name, keep=1, current=current)

                self.assertTrue(current.is_file())

    def test_the_manager_scripts_are_not_mistaken_for_releases(self) -> None:
        """管理脚本和 binary 同住 bin 目录，按前缀清理会把 <tool>-manager 一起删掉。"""
        for label, _, common, name, _ in MANAGERS:
            with self.subTest(tool=label):
                directory = self.version_dir()
                self.write(directory, f"{name}-manager", 1_000)
                self.write(directory, f"{name}-job", 1_000)
                current = self.write(directory, f"{name}-1.3.0", 3_000)

                kept = common.kept_binary_versions(directory, name)

                self.assertEqual(kept, [current])


if __name__ == "__main__":
    unittest.main()
