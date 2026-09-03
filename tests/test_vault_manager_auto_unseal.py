"""验证 vault-manager 的开机自动解封单元：unit 内容、开关流程与 doctor 报告。

自动解封的失效方式都是安静的——重启后 Vault 还锁着、或者密钥文件不在时单元每 5 秒重试一次，
两种都要等到用的时候才发现，所以在这里把关键指令逐条钉死。
"""

import argparse
import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "vault"))

from vault_tools import manager  # noqa: E402


def keys_file(exists: bool) -> Path:
    directory = Path(tempfile.mkdtemp())
    path = directory / "vault-init.json"
    if exists:
        path.write_text("{}")
    return path


class UnsealUnitTest(unittest.TestCase):
    def unit(self) -> str:
        return manager.unseal_service_content(Path("/opt/vault/init/vault-init.json"))

    def test_it_runs_on_every_start_of_vault_not_only_at_boot(self) -> None:
        """WantedBy=multi-user.target 只在开机拉一次，upgrade 的重启之后 Vault 就一直锁着。"""
        unit = self.unit()

        self.assertIn("WantedBy=vault.service", unit)
        self.assertNotIn("multi-user.target", unit)
        self.assertIn("PartOf=vault.service", unit)

    def test_a_finished_oneshot_still_receives_the_restart(self) -> None:
        """PartOf 传播的是 try-restart，对已经退出的 oneshot 是空操作，所以必须留在 active。"""
        unit = self.unit()

        self.assertIn("Type=oneshot", unit)
        self.assertIn("RemainAfterExit=yes", unit)

    def test_a_node_without_keys_is_skipped_instead_of_looping(self) -> None:
        """install 在 init 之前就 enable 了单元，没有这个条件就是每 RestartSec 一次的无限重试。"""
        unit = self.unit()

        self.assertIn("ConditionPathExists=/opt/vault/init/vault-init.json", unit)

    def test_it_waits_for_the_listener_and_reads_the_keys_as_root(self) -> None:
        unit = self.unit()

        self.assertIn(
            f"ExecStart={manager.TOOL_ENTRY} unseal --wait --keys-file /opt/vault/init/vault-init.json",
            unit,
        )
        self.assertIn("User=root", unit)

    def test_repeated_failures_do_not_retry_forever(self) -> None:
        unit = self.unit()

        self.assertIn("Restart=on-failure", unit)
        self.assertIn("RestartSec=5", unit)
        # without this the unit falls back to DefaultStartLimitIntervalSec=10s, a different rate limit
        self.assertIn("StartLimitIntervalSec=300", unit)
        self.assertIn("StartLimitBurst=10", unit)

    def test_it_is_ordered_after_the_server_it_unseals(self) -> None:
        unit = self.unit()

        self.assertIn("Requires=vault.service", unit)
        self.assertIn("After=vault.service", unit)
        self.assertIn("TimeoutStartSec=180", unit)

    def test_the_keys_file_can_be_read_back_from_the_installed_unit(self) -> None:
        path = Path(tempfile.mkdtemp()) / "vault-unseal.service"
        path.write_text(manager.unseal_service_content(Path("/srv/keys.json")))
        saved = manager.UNSEAL_SERVICE
        self.addCleanup(lambda: setattr(manager, "UNSEAL_SERVICE", saved))
        manager.UNSEAL_SERVICE = path

        self.assertEqual(manager.unseal_service_keys_file(), Path("/srv/keys.json"))


class EnableDisableTest(unittest.TestCase):
    def stub(self) -> tuple[list[list[str]], dict[str, str]]:
        calls: list[list[str]] = []
        written: dict[str, str] = {}
        saved = {key: getattr(manager, key) for key in ("run_root", "install_text", "command_exists", "safe_remove_path")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.run_root = lambda args, **kwargs: calls.append(list(args)) or subprocess.CompletedProcess(list(args), 0, "", "")
        manager.install_text = lambda path, content, **kwargs: written.__setitem__(str(path), content)
        manager.command_exists = lambda command: True
        manager.safe_remove_path = lambda path: calls.append(["rm", str(path)])
        return calls, written

    def test_enabling_writes_the_unit_and_enables_it(self) -> None:
        calls, written = self.stub()

        with redirect_stdout(io.StringIO()):
            manager.enable_auto_unseal(keys_file(exists=True), start=True)

        self.assertIn(str(manager.UNSEAL_SERVICE), written)
        self.assertIn(["systemctl", "daemon-reload"], calls)
        self.assertIn(["systemctl", "enable", manager.UNSEAL_SERVICE_NAME], calls)
        self.assertIn(["systemctl", "start", manager.UNSEAL_SERVICE_NAME], calls)

    def test_it_is_not_started_before_the_keys_exist(self) -> None:
        """install 装完就 enable，此时 init 还没跑；这时候 start 只会记一次跳过。"""
        calls, _ = self.stub()

        with redirect_stdout(io.StringIO()):
            manager.enable_auto_unseal(keys_file(exists=False), start=True)

        self.assertIn(["systemctl", "enable", manager.UNSEAL_SERVICE_NAME], calls)
        self.assertNotIn(["systemctl", "start", manager.UNSEAL_SERVICE_NAME], calls)

    def test_install_time_enable_never_starts_it(self) -> None:
        calls, _ = self.stub()

        with redirect_stdout(io.StringIO()):
            manager.enable_auto_unseal(keys_file(exists=True), start=False)

        self.assertNotIn(["systemctl", "start", manager.UNSEAL_SERVICE_NAME], calls)

    def test_enabling_says_what_it_costs(self) -> None:
        """密钥就在本机，seal 从此只是形式，这句必须打出来。"""
        self.stub()
        errors = io.StringIO()

        with redirect_stdout(io.StringIO()), redirect_stderr(errors):
            manager.enable_auto_unseal(keys_file(exists=True), start=False)

        self.assertIn("protects nothing at rest", errors.getvalue())

    def test_disabling_stops_removes_and_reloads(self) -> None:
        calls, _ = self.stub()

        manager.disable_auto_unseal()

        self.assertIn(["systemctl", "disable", "--now", manager.UNSEAL_SERVICE_NAME], calls)
        self.assertIn(["rm", str(manager.UNSEAL_SERVICE)], calls)
        self.assertIn(["systemctl", "daemon-reload"], calls)


class InstallWiringTest(unittest.TestCase):
    """install 的参数要经过一层手写 Namespace 转换，最容易漏字段。"""

    def install_namespace(self, argv: list[str]) -> argparse.Namespace:
        captured: list[argparse.Namespace] = []
        saved = manager.cmd_install
        self.addCleanup(lambda: setattr(manager, "cmd_install", saved))
        manager.cmd_install = lambda args: captured.append(args) or 0
        args = manager.build_parser().parse_args(argv)
        args.func(args)
        return captured[0]

    def test_auto_unseal_is_on_by_default(self) -> None:
        self.assertTrue(self.install_namespace(["install"]).auto_unseal)

    def test_the_flag_turns_it_off(self) -> None:
        self.assertFalse(self.install_namespace(["install", "--no-auto-unseal"]).auto_unseal)


class UnsealWaitTest(unittest.TestCase):
    def stub(self, sealed: bool) -> list[str]:
        events: list[str] = []
        saved = {key: getattr(manager, key) for key in ("wait_for_vault_api", "VaultClient")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])

        class Client:
            def __init__(self, _args: object) -> None:
                pass

            def status_json(self) -> dict:
                events.append("status")
                return {"sealed": sealed}

        manager.VaultClient = Client
        manager.wait_for_vault_api = lambda client: events.append("wait")
        return events

    def args(self, wait: bool) -> argparse.Namespace:
        return argparse.Namespace(keys_file="/opt/vault/init/vault-init.json", wait=wait,
                                  addr="", ca_cert="", namespace="", token_file="")

    def test_wait_happens_before_the_status_check(self) -> None:
        """单元在 vault.service fork 之后立刻启动，先问状态只会拿到连接失败。"""
        events = self.stub(sealed=False)

        with redirect_stdout(io.StringIO()):
            manager.cmd_unseal(self.args(wait=True))

        self.assertEqual(events, ["wait", "status"])

    def test_a_hand_run_unseal_does_not_wait(self) -> None:
        events = self.stub(sealed=False)

        with redirect_stdout(io.StringIO()):
            manager.cmd_unseal(self.args(wait=False))

        self.assertEqual(events, ["status"])


class DoctorAutoUnsealTest(unittest.TestCase):
    def stub(self, *, installed: bool, enabled: bool, keys: bool, failed: bool = False) -> io.StringIO:
        unit = Path(tempfile.mkdtemp()) / "vault-unseal.service"
        path = keys_file(exists=keys)
        if installed:
            unit.write_text(manager.unseal_service_content(path))
        saved = {key: getattr(manager, key) for key in ("UNSEAL_SERVICE", "auto_unseal_enabled", "command_exists", "run")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.UNSEAL_SERVICE = unit
        manager.auto_unseal_enabled = lambda: enabled
        manager.command_exists = lambda command: True
        manager.run = lambda args, **kwargs: subprocess.CompletedProcess(list(args), 0 if failed else 1, "", "")
        return io.StringIO()

    def test_an_enabled_unit_reports_the_trade_off(self) -> None:
        buffer = self.stub(installed=True, enabled=True, keys=True)

        with redirect_stdout(buffer):
            self.assertEqual(manager.doctor_auto_unseal(), 0)

        self.assertIn("protects nothing at rest", buffer.getvalue())

    def test_an_installed_but_disabled_unit_warns(self) -> None:
        buffer = self.stub(installed=True, enabled=False, keys=True)

        with redirect_stdout(buffer):
            self.assertEqual(manager.doctor_auto_unseal(), 0)

        self.assertIn("WARN", buffer.getvalue())
        self.assertIn("stays sealed after a restart", buffer.getvalue())

    def test_missing_keys_are_called_out(self) -> None:
        buffer = self.stub(installed=True, enabled=True, keys=False)

        with redirect_stdout(buffer):
            manager.doctor_auto_unseal()

        self.assertIn("Keys file missing", buffer.getvalue())

    def test_a_failed_unit_is_a_failure(self) -> None:
        buffer = self.stub(installed=True, enabled=True, keys=True, failed=True)

        with redirect_stdout(buffer):
            self.assertEqual(manager.doctor_auto_unseal(), 1)

        self.assertIn("failed state", buffer.getvalue())

    def test_no_unit_is_not_a_failure(self) -> None:
        buffer = self.stub(installed=False, enabled=False, keys=False)

        with redirect_stdout(buffer):
            self.assertEqual(manager.doctor_auto_unseal(), 0)

        self.assertIn("not installed", buffer.getvalue())


class UnreadableKeysFileTest(unittest.TestCase):
    """init 目录是 0700 root，sudoer 身份下 Path.is_file() 抛的是异常而不是返回 False。"""

    class Unreadable:
        """站位对象：本机 Python 3.14 会吞掉 EACCES，目标节点上的 3.11/3.12 不会。"""

        def is_file(self) -> bool:
            raise PermissionError(13, "Permission denied")

        def __str__(self) -> str:
            return "/opt/vault/init/vault-init.json"

    def test_an_unreadable_path_answers_none_instead_of_raising(self) -> None:
        self.assertIsNone(manager.keys_file_present(self.Unreadable()))

    def test_a_readable_path_still_answers_plainly(self) -> None:
        self.assertIs(manager.keys_file_present(keys_file(exists=True)), True)
        self.assertIs(manager.keys_file_present(keys_file(exists=False)), False)

    def test_doctor_reports_it_instead_of_dying(self) -> None:
        """doctor 在这里崩掉，后面的 Vault state 段落就整段不会跑。"""
        unit = Path(tempfile.mkdtemp()) / "vault-unseal.service"
        unit.write_text(manager.unseal_service_content(Path("/opt/vault/init/vault-init.json")))
        saved = {key: getattr(manager, key) for key in
                 ("UNSEAL_SERVICE", "auto_unseal_enabled", "command_exists", "run", "unseal_service_keys_file")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.UNSEAL_SERVICE = unit
        manager.auto_unseal_enabled = lambda: True
        manager.command_exists = lambda command: False
        manager.unseal_service_keys_file = lambda: self.Unreadable()
        buffer = io.StringIO()

        with redirect_stdout(buffer):
            self.assertEqual(manager.doctor_auto_unseal(), 0)

        self.assertIn("not readable from here", buffer.getvalue())

    def test_enabling_still_starts_the_unit(self) -> None:
        """读不到不等于不存在，交给 systemd 的 ConditionPathExists 判断。"""
        calls: list[list[str]] = []
        saved = {key: getattr(manager, key) for key in ("run_root", "install_text", "command_exists")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.run_root = lambda args, **kwargs: calls.append(list(args))
        manager.install_text = lambda path, content, **kwargs: None
        manager.command_exists = lambda command: True

        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            manager.enable_auto_unseal(self.Unreadable(), start=True)

        self.assertIn(["systemctl", "start", manager.UNSEAL_SERVICE_NAME], calls)


class WillRunTest(unittest.TestCase):
    """enabled 只是一半答案，ConditionPathExists 才决定单元跑不跑。"""

    def stub(self, *, enabled: bool, keys: bool) -> None:
        saved = {key: getattr(manager, key) for key in ("auto_unseal_enabled", "unseal_service_keys_file")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.auto_unseal_enabled = lambda: enabled
        manager.unseal_service_keys_file = lambda: keys_file(exists=keys)

    def test_enabled_with_keys_will_run(self) -> None:
        self.stub(enabled=True, keys=True)

        self.assertTrue(manager.auto_unseal_will_run())

    def test_enabled_without_keys_will_not(self) -> None:
        self.stub(enabled=True, keys=False)

        self.assertFalse(manager.auto_unseal_will_run())

    def test_upgrade_does_not_promise_an_unseal_that_will_be_skipped(self) -> None:
        """备份完密钥把文件挪走是这个工具自己建议的动作，之后单元就被静默跳过了。"""
        self.stub(enabled=True, keys=False)
        buffer = io.StringIO()

        with redirect_stdout(buffer), redirect_stderr(io.StringIO()):
            print("\n".join(manager.upgrade_plan_lines("1.2.0", "1.3.0", 2)))

        self.assertNotIn("unseals it again", buffer.getvalue())

    def test_the_plan_says_so_when_it_will_run(self) -> None:
        self.stub(enabled=True, keys=True)

        self.assertIn("unseals it again", "\n".join(manager.upgrade_plan_lines("1.2.0", "1.3.0", 2)))


class KeysFileArgumentTest(unittest.TestCase):
    def setUp(self) -> None:
        saved = {key: getattr(manager, key) for key in ("require_linux", "require_command", "enable_auto_unseal")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.require_linux = lambda: None
        manager.require_command = lambda command: None
        manager.enable_auto_unseal = lambda keys, *, start: self.fail("a rejected path must not reach the unit")

    def test_a_relative_path_is_refused(self) -> None:
        """单元以 WorkingDirectory=/ 运行，相对路径永远指不到用户想的那个文件。"""
        with self.assertRaises(manager.CLIError) as caught:
            manager.cmd_auto_unseal_enable(argparse.Namespace(keys_file="./vault-init.json"))

        self.assertIn("absolute", str(caught.exception))


class InstallBodyTest(unittest.TestCase):
    """install 装不装这个单元是本次改动的主行为，之前只测到参数那一层。"""

    def stub(self, unit_exists: bool) -> list[str]:
        events: list[str] = []
        unit = Path(tempfile.mkdtemp()) / "vault-unseal.service"
        if unit_exists:
            unit.write_text("[Unit]\n")
        names = ("require_linux", "require_command", "resolve_install_tls", "resolve_version", "detect_arch",
                 "create_install_tmpdir", "download_vault", "install_binary", "ensure_vault_user",
                 "install_directories", "write_vault_config", "write_client_env", "write_systemd_service",
                 "running_from_installed_copy", "install_tool_snapshot", "write_state_pointer", "run_root",
                 "wait_for_vault_api", "enable_auto_unseal", "disable_auto_unseal", "UNSEAL_SERVICE")
        saved = {key: getattr(manager, key) for key in names}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        for name in names:
            if name.isupper():
                continue
            setattr(manager, name, lambda *args, **kwargs: None)
        manager.UNSEAL_SERVICE = unit
        manager.resolve_install_tls = lambda args: argparse.Namespace(
            mode="off", api_addr="http://127.0.0.1:8200", cluster_addr="", tls_cert_file="",
            tls_key_file="", tls_ca_cert_file="", tls_dns=[], tls_ip=[], tls_common_name="vault-server")
        manager.resolve_version = lambda requested: "1.3.0"
        manager.detect_arch = lambda: "amd64"
        manager.create_install_tmpdir = lambda prefix: Path(tempfile.mkdtemp())
        manager.running_from_installed_copy = lambda script_dir: False
        manager.enable_auto_unseal = lambda keys, *, start: events.append(f"enable start={start}")
        manager.disable_auto_unseal = lambda: events.append("disable")
        return events

    def args(self, auto_unseal: bool) -> argparse.Namespace:
        return argparse.Namespace(version="1.3.0", auto_unseal=auto_unseal)

    def test_install_enables_it_dormant_by_default(self) -> None:
        events = self.stub(unit_exists=False)

        with redirect_stdout(io.StringIO()):
            manager.cmd_install(self.args(True))

        self.assertEqual(events, ["enable start=False"])

    def test_the_flag_turns_off_a_unit_that_is_already_there(self) -> None:
        """install 可以重复跑，用这个 flag 关掉自动解封必须真的关掉。"""
        events = self.stub(unit_exists=True)

        with redirect_stdout(io.StringIO()):
            manager.cmd_install(self.args(False))

        self.assertEqual(events, ["disable"])

    def test_a_fresh_install_with_the_flag_touches_nothing(self) -> None:
        events = self.stub(unit_exists=False)

        with redirect_stdout(io.StringIO()):
            manager.cmd_install(self.args(False))

        self.assertEqual(events, [])


class UninstallBodyTest(unittest.TestCase):
    def test_the_unit_is_disabled_before_vault_stops(self) -> None:
        calls: list[list[str]] = []
        names = ("require_linux", "require_command", "run_root", "safe_remove_path", "remove_acl_env_file", "run")
        saved = {key: getattr(manager, key) for key in names}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.require_linux = lambda: None
        manager.require_command = lambda command: None
        manager.run_root = lambda args, **kwargs: calls.append(list(args))
        manager.safe_remove_path = lambda path: None
        manager.remove_acl_env_file = lambda: None
        manager.run = lambda args, **kwargs: subprocess.CompletedProcess(list(args), 1, "", "")
        args = argparse.Namespace(purge_data=False, purge=False, remove_tools=False, dry_run=False, yes=True)

        with redirect_stdout(io.StringIO()):
            manager.cmd_uninstall(args)

        disable = ["systemctl", "disable", "--now", manager.UNSEAL_SERVICE_NAME]
        self.assertIn(disable, calls)
        self.assertLess(calls.index(disable), calls.index(["systemctl", "stop", "vault"]))


class StatusLineTest(unittest.TestCase):
    def stub(self, *, installed: bool, enabled: bool, keys: bool) -> None:
        unit = Path(tempfile.mkdtemp()) / "vault-unseal.service"
        if installed:
            unit.write_text(manager.unseal_service_content(keys_file(exists=keys)))
        saved = {key: getattr(manager, key) for key in ("UNSEAL_SERVICE", "auto_unseal_enabled")}
        self.addCleanup(lambda: [setattr(manager, key, value) for key, value in saved.items()])
        manager.UNSEAL_SERVICE = unit
        manager.auto_unseal_enabled = lambda: enabled

    def line(self) -> str:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            manager.print_auto_unseal_status_line()
        return buffer.getvalue()

    def test_an_enabled_unit_shows_its_keys_file(self) -> None:
        self.stub(installed=True, enabled=True, keys=True)

        self.assertIn("enabled", self.line())

    def test_a_missing_keys_file_is_visible_in_status(self) -> None:
        self.stub(installed=True, enabled=True, keys=False)

        self.assertIn("keys file missing", self.line())

    def test_no_unit_reads_as_not_installed(self) -> None:
        self.stub(installed=False, enabled=False, keys=False)

        self.assertIn("<not installed>", self.line())


class UninstallTest(unittest.TestCase):
    def test_the_unit_is_listed_and_removed(self) -> None:
        args = argparse.Namespace(purge_data=False, purge=False, remove_tools=False, dry_run=True, yes=True)
        buffer = io.StringIO()

        with redirect_stdout(buffer):
            manager.print_uninstall_plan(args)

        self.assertIn(f"    - {manager.UNSEAL_SERVICE_NAME}\n", buffer.getvalue())
        self.assertIn(manager.UNSEAL_SERVICE, manager.uninstall_runtime_paths())


if __name__ == "__main__":
    unittest.main()
