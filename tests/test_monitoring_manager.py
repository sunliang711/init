"""验证 monctl 的生成配置、抓取目标管理、升级判断与移除计划。

这套东西真正跑起来需要两台带 systemd 的机器,真机上复现一次的代价很高,
所以承重的不变量都锁在这里:生成的 prometheus.yml 长什么样、目标文件怎么增删、
promtool 拒绝时是否回滚、以及卸载计划有没有把数据目录默认留下。
"""

import argparse
import io
import json
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "tools" / "monitoring"))

from monitoring_tools import common  # noqa: E402
from monitoring_tools import manager  # noqa: E402


class _FakePwd:
    """pwd stand-in so the uid comparison can be driven from a test."""

    def __init__(self, uid: int) -> None:
        self.uid = uid

    def getpwnam(self, name: str) -> object:
        return type("Entry", (), {"pw_uid": self.uid, "pw_gid": self.uid})()


def fake_install_text(path, content, *, mode="0644", owner=None, group=None) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


class ManagerTestCase(unittest.TestCase):
    """把所有写盘路径挪到临时目录,并把需要 root 的调用换成记录器。"""

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.root_calls: list[list[str]] = []
        self.patch(manager, "install_text", fake_install_text)
        self.patch(manager, "run_root", self.fake_run_root)
        self.patch(manager, "ROOT_DIR", self.root)
        self.patch(manager, "BIN_DIR", self.root / "bin")
        self.patch(manager, "BINARY_VERSION_DIR", self.root / "bin" / "versions")
        self.patch(manager, "ETC_DIR", self.root / "etc")
        self.patch(manager, "DATA_ROOT", self.root / "data")
        self.patch(manager, "SHARE_DIR", self.root / "share")
        self.patch(manager, "LOG_ROOT", self.root / "log")
        self.patch(manager, "TOOL_DIR", self.root / "lib" / "monctl")
        self.patch(manager, "TOOL_LOG_DIR", self.root / "log" / "monctl")
        self.patch(manager, "PROMETHEUS_CONFIG_DIR", self.root / "etc" / "prometheus")
        self.patch(manager, "PROMETHEUS_CONFIG_FILE", self.root / "etc" / "prometheus" / "prometheus.yml")
        self.patch(manager, "PROMETHEUS_TARGET_DIR", self.root / "etc" / "prometheus" / "targets")
        self.patch(manager, "PROMETHEUS_DATA_DIR", self.root / "data" / "prometheus")
        self.patch(manager, "GRAFANA_DATA_DIR", self.root / "data" / "grafana")
        self.patch(manager, "GRAFANA_LOG_DIR", self.root / "log" / "grafana")
        self.patch(manager, "GRAFANA_HOME_DIR", self.root / "share" / "grafana")
        self.patch(manager, "GRAFANA_VERSION_DIR", self.root / "share" / "grafana" / "versions")
        self.patch(manager, "GRAFANA_CURRENT_DIR", self.root / "share" / "grafana" / "current")
        self.patch(manager, "GRAFANA_CONFIG_FILE", self.root / "etc" / "grafana" / "grafana.ini")
        self.patch(manager, "GRAFANA_CONFIG_DIR", self.root / "etc" / "grafana")
        self.patch(manager, "GRAFANA_PROVISIONING_DIR", self.root / "etc" / "grafana" / "provisioning")
        self.patch(manager, "GRAFANA_DATASOURCE_FILE",
                   self.root / "etc" / "grafana" / "provisioning" / "datasources" / "prometheus.yaml")
        self.patch(manager, "INSTALL_METADATA_FILE", self.root / "data" / "tools" / "install.json")
        self.patch(manager, "TOOL_STATE_DIR", self.root / "data" / "tools")
        self.patch(manager, "SYSTEMD_DIR", self.root / "systemd")
        self.patch(manager, "LEGACY_PATHS", ())

    def patch(self, module: object, name: str, value: object) -> None:
        saved = getattr(module, name)
        self.addCleanup(lambda: setattr(module, name, saved))
        setattr(module, name, value)

    def fake_run_root(self, args, **kwargs):
        args = [str(item) for item in args]
        self.root_calls.append(args)
        if args[0] == "install" and "-d" in args:
            Path(args[-1]).mkdir(parents=True, exist_ok=True)
        if args[0] == "rm":
            target = Path(args[-1])
            if target.is_file() or target.is_symlink():
                target.unlink()
        return subprocess.CompletedProcess(args, 0, "", "")

    def capture(self, callback) -> str:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            callback()
        return buffer.getvalue()


class TargetFileTest(ManagerTestCase):
    """抓取目标存在 file_sd 的 JSON 里,Prometheus 自己会重读,所以增删不该触发重启。"""

    def test_add_writes_file_sd_entry(self) -> None:
        self.assertTrue(manager.add_target_entry("node", "10.0.0.11:9100", {"instance": "web-1"}))
        entries = json.loads(manager.target_file("node").read_text(encoding="utf-8"))
        self.assertEqual(entries, [{"labels": {"instance": "web-1"}, "targets": ["10.0.0.11:9100"]}])
        self.assertEqual(manager.scrape_jobs(), ["node"])

    def test_add_is_idempotent(self) -> None:
        self.assertTrue(manager.add_target_entry("node", "10.0.0.11:9100", {}))
        self.assertFalse(manager.add_target_entry("node", "10.0.0.11:9100", {}))
        self.assertEqual(manager.entry_addresses(manager.read_target_entries("node")), ["10.0.0.11:9100"])

    def test_add_updates_labels_of_a_known_address(self) -> None:
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        self.assertTrue(manager.add_target_entry("node", "10.0.0.11:9100", {"env": "prod"}))
        entries = manager.read_target_entries("node")
        self.assertEqual(entries[0]["labels"], {"env": "prod"})

    def test_remove_keeps_the_job_with_an_empty_file(self) -> None:
        """留下空文件是为了下一次 add 不用再改写 prometheus.yml,也就不用 reload。"""
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        args = argparse.Namespace(address="10.0.0.11:9100", job="")
        self.patch(manager, "component_installed", lambda component: True)
        self.assertEqual(manager.cmd_prometheus_target_remove(args), 0)
        self.assertEqual(manager.read_target_entries("node"), [])
        self.assertEqual(manager.scrape_jobs(), ["node"])

    def test_remove_keeps_the_other_addresses_of_an_entry(self) -> None:
        """一个条目里可以有多个地址,删掉其中一个不能连带标签和同伴一起消失。"""
        manager.write_target_entries("node", [
            {"targets": [], "labels": {"stale": "entry"}},
            {"targets": ["10.0.0.11:9100", "10.0.0.12:9100"], "labels": {"env": "prod"}},
        ])
        self.patch(manager, "component_installed", lambda component: True)
        args = argparse.Namespace(address="10.0.0.11:9100", job="node")
        self.assertEqual(manager.cmd_prometheus_target_remove(args), 0)
        entries = manager.read_target_entries("node")
        self.assertEqual(entries, [
            {"labels": {"stale": "entry"}, "targets": []},
            {"labels": {"env": "prod"}, "targets": ["10.0.0.12:9100"]},
        ])

    def test_remove_reports_an_unknown_address(self) -> None:
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        self.patch(manager, "component_installed", lambda component: True)
        args = argparse.Namespace(address="10.0.0.99:9100", job="")
        self.assertEqual(manager.cmd_prometheus_target_remove(args), 1)
        self.assertEqual(manager.entry_addresses(manager.read_target_entries("node")), ["10.0.0.11:9100"])

    def test_a_new_job_is_not_left_behind_when_the_config_write_fails(self) -> None:
        """配置没改成的话,这个 job 文件只会让 target list 显示一个 Prometheus 根本没抓的 job。"""
        self.patch(manager, "component_installed", lambda component: True)
        manager.PROMETHEUS_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        manager.PROMETHEUS_CONFIG_FILE.write_text("global:\n", encoding="utf-8")  # 不是本工具写的
        args = argparse.Namespace(address="10.0.0.77:9100", job="newjob", label=[])
        with self.assertRaises(common.CLIError):
            self.capture(lambda: manager.cmd_prometheus_target_add(args))
        self.assertFalse(manager.target_file("newjob").exists())
        self.assertEqual(manager.scrape_jobs(), [])

    def test_an_existing_job_survives_a_failed_config_write(self) -> None:
        """已有 job 的地址增删压根不碰 prometheus.yml,不该被它的失败连累。"""
        self.patch(manager, "component_installed", lambda component: True)
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        args = argparse.Namespace(address="10.0.0.12:9100", job="node", label=[])
        self.capture(lambda: manager.cmd_prometheus_target_add(args))
        self.assertEqual(manager.entry_addresses(manager.read_target_entries("node")),
                         ["10.0.0.11:9100", "10.0.0.12:9100"])

    def test_refuses_to_rewrite_a_foreign_target_file(self) -> None:
        """JSON 里放不下 managed marker,所以只能靠结构判断,形状不对就不碰。"""
        path = manager.target_file("node")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"targets": "not a list of entries"}', encoding="utf-8")
        with self.assertRaises(common.CLIError):
            manager.read_target_entries("node")

    def test_rejects_addresses_and_jobs_that_break_the_layout(self) -> None:
        for bad in ("10.0.0.11", "10.0.0.11:not-a-port", "10.0.0.11:70000"):
            with self.subTest(address=bad), self.assertRaises(common.CLIError):
                manager.validate_target(bad)
        for bad in ("../etc/passwd", "node.json", "a b"):
            with self.subTest(job=bad), self.assertRaises(common.CLIError):
                manager.validate_job(bad)

    def test_ignores_files_that_are_not_job_files(self) -> None:
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        (manager.PROMETHEUS_TARGET_DIR / "node.json.bak").write_text("[]", encoding="utf-8")
        self.assertEqual(manager.scrape_jobs(), ["node"])


class TargetHealthTest(ManagerTestCase):
    """doctor 和 target list 要把 API 报的健康状态对回「当初加的那个地址」。"""

    PAYLOAD = {
        "status": "success",
        "data": {
            "activeTargets": [
                {
                    # 带了自定义 instance 标签:labels.instance 不再是地址
                    "discoveredLabels": {"__address__": "10.0.0.11:9100", "job": "node",
                                         "instance": "web-1"},
                    "labels": {"instance": "web-1", "job": "node"},
                    "scrapePool": "node",
                    "scrapeUrl": "http://10.0.0.11:9100/metrics",
                    "lastError": "",
                    "health": "up",
                },
                {
                    "discoveredLabels": {"__address__": "127.0.0.1:9999", "job": "broken"},
                    "labels": {"instance": "127.0.0.1:9999", "job": "broken"},
                    "scrapePool": "broken",
                    "scrapeUrl": "http://127.0.0.1:9999/metrics",
                    "lastError": "connect: connection refused",
                    "health": "down",
                },
            ]
        },
    }

    def test_health_is_keyed_by_the_address_it_was_added_with(self) -> None:
        """真机上撞出来的:instance 标签一改,健康状态就永远对不上,doctor 报「还没被抓到」。"""
        self.patch(manager, "prometheus_api", lambda path: self.PAYLOAD)
        health = manager.active_target_health()
        self.assertEqual(health[("node", "10.0.0.11:9100")]["health"], "up")
        self.assertEqual(health[("broken", "127.0.0.1:9999")]["health"], "down")
        self.assertIn("refused", health[("broken", "127.0.0.1:9999")]["error"])

    def test_doctor_reports_the_down_target_with_its_error(self) -> None:
        self.patch(manager, "prometheus_api", lambda path: self.PAYLOAD)
        manager.add_target_entry("node", "10.0.0.11:9100", {"instance": "web-1"})
        manager.add_target_entry("broken", "127.0.0.1:9999", {})
        output = self.capture(lambda: self.assertEqual(manager.doctor_prometheus_targets(), 1))
        self.assertIn("Target up: node 10.0.0.11:9100", output)
        self.assertIn("Target down: broken 127.0.0.1:9999", output)
        self.assertIn("connection refused", output)
        self.assertNotIn("not picked up", output)

    def test_an_unreachable_prometheus_is_not_a_target_failure(self) -> None:
        self.patch(manager, "prometheus_api", lambda path: None)
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        output = self.capture(lambda: self.assertEqual(manager.doctor_prometheus_targets(), 0))
        self.assertIn("did not report its targets", output)


class PrometheusConfigTest(ManagerTestCase):
    def test_generated_config_has_one_file_sd_job_per_target_file(self) -> None:
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        manager.add_target_entry("db", "10.0.0.12:9100", {})
        rendered = manager.render_prometheus_config("127.0.0.1:9090", "15s", manager.scrape_jobs())
        self.assertTrue(rendered.startswith(manager.MANAGED_MARKER))
        self.assertIn("  - job_name: 'node'", rendered)
        self.assertIn("  - job_name: 'db'", rendered)
        self.assertIn("    file_sd_configs:", rendered)
        self.assertIn(str(manager.target_file("node")), rendered)
        self.assertIn("scrape_interval:     15s", rendered)

    def test_self_scrape_uses_a_reachable_address(self) -> None:
        """监听 0.0.0.0 时抓自己必须换成回环地址,否则 job 'prometheus' 的 target 很别扭。"""
        rendered = manager.render_prometheus_config("0.0.0.0:9090", "15s", [])
        self.assertIn("targets: ['127.0.0.1:9090']", rendered)

    def test_bad_config_is_rolled_back(self) -> None:
        """promtool 拒绝新配置时必须把旧文件放回去,而不是留下一个起不来的服务。"""
        previous = manager.managed_text("global:\n  scrape_interval: 99s")
        fake_install_text(manager.PROMETHEUS_CONFIG_FILE, previous)

        def reject() -> None:
            raise common.CLIError("promtool rejected the generated config")

        self.patch(manager, "check_prometheus_config", reject)
        manager.add_target_entry("node", "10.0.0.11:9100", {})
        with self.assertRaises(common.CLIError):
            manager.apply_prometheus_config()
        self.assertEqual(manager.PROMETHEUS_CONFIG_FILE.read_text(encoding="utf-8"), previous)

    def test_unchanged_config_is_not_rewritten(self) -> None:
        calls: list[int] = []
        self.patch(manager, "check_prometheus_config", lambda: calls.append(1))
        self.assertTrue(manager.apply_prometheus_config())
        self.assertFalse(manager.apply_prometheus_config())
        self.assertEqual(len(calls), 1)

    def test_refuses_a_config_this_tool_did_not_write(self) -> None:
        manager.PROMETHEUS_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        manager.PROMETHEUS_CONFIG_FILE.write_text("global:\n  scrape_interval: 1s\n", encoding="utf-8")
        with self.assertRaises(common.CLIError):
            manager.require_managed_or_absent(manager.PROMETHEUS_CONFIG_FILE, False)
        manager.require_managed_or_absent(manager.PROMETHEUS_CONFIG_FILE, True)


class UnitFileTest(ManagerTestCase):
    def test_node_exporter_unit_carries_the_flags(self) -> None:
        flags = manager.node_exporter_flags("127.0.0.1:9100", ["systemd"], ["mdadm"], ["--log.level=warn"])
        unit = manager.render_node_exporter_unit(flags)
        self.assertTrue(unit.startswith(manager.MANAGED_MARKER))
        self.assertIn("--web.listen-address=127.0.0.1:9100", unit)
        self.assertIn("--collector.systemd", unit)
        self.assertIn("--no-collector.mdadm", unit)
        self.assertIn("--log.level=warn", unit)

    def test_node_exporter_keeps_home_visible(self) -> None:
        """ProtectHome=yes 会让独立挂载的 /home 从 node_filesystem_* 里消失。"""
        unit = manager.render_node_exporter_unit(manager.node_exporter_flags("127.0.0.1:9100", [], [], []))
        self.assertIn("ProtectHome=read-only", unit)

    def test_extra_arguments_must_look_like_flags(self) -> None:
        with self.assertRaises(common.CLIError):
            manager.node_exporter_flags("127.0.0.1:9100", [], [], ["log.level=warn"])

    def test_values_with_whitespace_are_rejected(self) -> None:
        """ExecStart 每个 flag 占一行、ini 每个值占一行,空白会让文件读起来和看起来不一样。"""
        with self.assertRaises(common.CLIError):
            manager.prometheus_flags("127.0.0.1:9090", "15d", "http://example.com/ x", [])
        with self.assertRaises(common.CLIError):
            manager.node_exporter_flags("127.0.0.1:9100", [], [], ["--log.level=warn extra"])
        with self.assertRaises(common.CLIError):
            manager.validate_generated_value("bad\nvalue", "domain")

    def test_prometheus_unit_reloads_on_sighup(self) -> None:
        flags = manager.prometheus_flags("127.0.0.1:9090", "30d", "", [])
        unit = manager.render_prometheus_unit(flags)
        self.assertIn("ExecReload=/bin/kill --signal HUP $MAINPID", unit)
        self.assertIn("--storage.tsdb.retention.time=30d", unit)
        self.assertIn(f"ConditionFileNotEmpty={manager.PROMETHEUS_CONFIG_FILE}", unit)

    def test_prometheus_rejects_a_retention_prometheus_would_reject(self) -> None:
        with self.assertRaises(common.CLIError):
            manager.prometheus_flags("127.0.0.1:9090", "forever", "", [])

    def test_grafana_unit_points_at_the_current_symlink(self) -> None:
        """单元文件必须写 current,而不是某个版本目录,否则每次升级都要改单元。"""
        home = self.root / "share" / "grafana" / "versions" / "grafana-13.2.2"
        (home / "bin").mkdir(parents=True)
        (home / "bin" / "grafana").write_text("#!/bin/sh\n", encoding="utf-8")
        unit = manager.render_grafana_unit(manager.grafana_server_command(home))
        self.assertIn(f"{manager.GRAFANA_CURRENT_DIR}/bin/grafana server", unit)
        self.assertIn(f"--homepath={manager.GRAFANA_CURRENT_DIR}", unit)
        self.assertNotIn("grafana-13.2.2", unit)

    def test_grafana_falls_back_to_the_legacy_server_binary(self) -> None:
        home = self.root / "share" / "grafana" / "versions" / "grafana-9.5.0"
        (home / "bin").mkdir(parents=True)
        (home / "bin" / "grafana-server").write_text("#!/bin/sh\n", encoding="utf-8")
        self.assertTrue(manager.grafana_server_command(home).endswith("/bin/grafana-server"))
        empty = self.root / "share" / "grafana" / "versions" / "grafana-0.0.0"
        (empty / "bin").mkdir(parents=True)
        with self.assertRaises(common.CLIError):
            manager.grafana_server_command(empty)


class StagedBinaryTest(ManagerTestCase):
    """staged 的版本校验发生在切软链之前,这是「坏包不会顶掉正在跑的版本」的唯一保证。"""

    def test_a_binary_that_cannot_run_fails_loudly(self) -> None:
        binary = self.root / "node_exporter"
        binary.write_text("not a real binary\n", encoding="utf-8")
        os.chmod(binary, 0o644)
        with self.assertRaises(common.CLIError) as caught:
            manager.verify_staged_version(binary, "1.12.1")
        self.assertIn("cannot be executed", str(caught.exception))
        self.assertEqual(manager.binary_reported_version(binary), "")

    def test_a_version_mismatch_fails(self) -> None:
        binary = self.root / "node_exporter"
        binary.write_text("#!/bin/sh\necho 'node_exporter, version 1.9.0 (branch: HEAD)'\n", encoding="utf-8")
        os.chmod(binary, 0o755)
        self.assertEqual(manager.binary_reported_version(binary), "1.9.0")
        manager.verify_staged_version(binary, "1.9.0")
        with self.assertRaises(common.CLIError):
            manager.verify_staged_version(binary, "1.12.1")

    def test_unparsable_output_is_only_a_warning(self) -> None:
        """Grafana 各版本的 --version 输出格式变过,读不出来不该挡住安装。"""
        binary = self.root / "grafana"
        binary.write_text("#!/bin/sh\necho 'something else entirely'\n", encoding="utf-8")
        os.chmod(binary, 0o755)
        manager.verify_staged_version(binary, "13.2.2")


class VersionTest(ManagerTestCase):
    def test_normalize_version_rejects_anything_but_a_release(self) -> None:
        self.assertEqual(manager.normalize_version("v1.12.1"), "1.12.1")
        for bad in ("latest", "1.12", "1.12.1-rc.1"):
            with self.subTest(version=bad), self.assertRaises(common.CLIError):
                manager.normalize_version(bad)

    def test_upgrade_target_never_falls_back_to_the_pinned_default(self) -> None:
        """安装时联网失败可以退回内置版本,升级时不行:那会把线上换成没人要求的版本。"""
        def unreachable(component: object) -> str:
            raise OSError("no network")

        self.patch(manager, "fetch_latest_version", unreachable)
        with self.assertRaises(common.CLIError):
            manager.resolve_upgrade_target(manager.PROMETHEUS, "latest")
        self.assertEqual(manager.resolve_version(manager.PROMETHEUS, "latest"),
                         manager.PROMETHEUS.default_version)

    def test_upgrade_plan_explains_the_restart_and_the_rollback(self) -> None:
        lines = "\n".join(manager.upgrade_plan_lines(manager.PROMETHEUS, "3.0.0", "3.14.0", 2))
        self.assertIn("Current version:  3.0.0", lines)
        self.assertIn("Target version:   3.14.0", lines)
        self.assertIn("rolled back", lines)
        self.assertIn("the TSDB", lines)
        self.assertNotIn("Downgrade:", lines)

    def test_upgrade_plan_warns_about_a_downgrade(self) -> None:
        lines = "\n".join(manager.upgrade_plan_lines(manager.PROMETHEUS, "3.14.0", "3.0.0", 2))
        self.assertIn("Downgrade:", lines)

    def test_upgrade_refuses_a_downgrade_without_the_flag(self) -> None:
        self.patch(manager, "require_linux", lambda: None)
        self.patch(manager, "require_command", lambda command: None)
        self.patch(manager, "component_installed", lambda component: True)
        self.patch(manager, "installed_version", lambda component: "3.14.0")
        self.patch(manager, "resolve_upgrade_target", lambda component, requested: "3.0.0")
        args = argparse.Namespace(version="3.0.0", keep=2, allow_downgrade=False, dry_run=True, yes=True)
        with self.assertRaises(common.CLIError):
            manager.cmd_component_upgrade(manager.PROMETHEUS, args)
        args.allow_downgrade = True
        output = self.capture(lambda: manager.cmd_component_upgrade(manager.PROMETHEUS, args))
        self.assertIn("Downgrade:", output)
        self.assertEqual(self.root_calls, [])

    def test_dry_run_upgrade_touches_nothing(self) -> None:
        self.patch(manager, "require_linux", lambda: None)
        self.patch(manager, "require_command", lambda command: None)
        self.patch(manager, "component_installed", lambda component: True)
        self.patch(manager, "installed_version", lambda component: "1.9.0")
        self.patch(manager, "resolve_upgrade_target", lambda component, requested: "1.12.1")
        args = argparse.Namespace(version="latest", keep=2, allow_downgrade=False, dry_run=True, yes=True)
        output = self.capture(lambda: manager.cmd_component_upgrade(manager.NODE_EXPORTER, args))
        self.assertIn("node-exporter upgrade plan:", output)
        self.assertEqual(self.root_calls, [])


class UninstallPlanTest(ManagerTestCase):
    def plan(self, components: list[object], **overrides: object) -> str:
        args = argparse.Namespace(purge=False, remove_tools=False, dry_run=True, yes=True, components="")
        for key, value in overrides.items():
            setattr(args, key, value)
        return self.capture(lambda: manager.print_uninstall_plan(components, args))

    def test_data_is_preserved_unless_purge_is_given(self) -> None:
        """默认删掉的是二进制和配置,TSDB 与 Grafana 数据库必须留着。"""
        output = self.plan([manager.PROMETHEUS, manager.GRAFANA])
        self.assertIn("Preserve paths:", output)
        self.assertIn(str(manager.PROMETHEUS_DATA_DIR), output)
        self.assertIn(str(manager.GRAFANA_DATA_DIR), output)
        removed = output.split("Preserve paths:")[0]
        self.assertNotIn(str(manager.PROMETHEUS_DATA_DIR), removed)

    def test_purge_moves_data_into_the_removed_list(self) -> None:
        output = self.plan([manager.PROMETHEUS], purge=True)
        self.assertNotIn("Preserve paths:", output)
        self.assertIn(f"{manager.PROMETHEUS_DATA_DIR}   <-- deletes stored metrics", output)

    def test_purge_leaves_no_empty_skeleton(self) -> None:
        """--purge 说是全删,就不该留下一副空目录。rmdir 只删空的,别的组件不受影响。"""
        self.assertIn(f"Remove the directories under {manager.ROOT_DIR} that end up empty",
                      self.plan([manager.PROMETHEUS], purge=True))
        calls: list[list[str]] = []
        self.patch(manager, "run_root", lambda args, **kw: calls.append([str(a) for a in args]))
        manager.prune_empty_root_directories()
        self.assertIn(["rmdir", "--ignore-fail-on-non-empty", "--", str(manager.BIN_DIR)], calls)
        self.assertTrue(all(call[0] == "rmdir" for call in calls), "purge must not use rm here")

    def test_the_plan_admits_the_audit_log_comes_back(self) -> None:
        """每条命令结束都会写审计记录,包括这一条,所以日志目录删完立刻又出现。"""
        output = self.plan([manager.NODE_EXPORTER], remove_tools=True)
        self.assertIn(f"{manager.TOOL_LOG_DIR}   <-- recreated afterwards", output)

    def test_tool_files_are_preserved_unless_asked(self) -> None:
        self.assertIn("Preserve tool paths:", self.plan([manager.NODE_EXPORTER]))
        self.assertIn("Remove tool paths:", self.plan([manager.NODE_EXPORTER], remove_tools=True))

    def test_uninstall_without_an_install_says_so(self) -> None:
        self.patch(manager, "component_installed", lambda component: False)
        with self.assertRaises(common.CLIError):
            manager.resolve_uninstall_components(
                argparse.Namespace(components="", purge=False, remove_tools=False))

    def test_the_tool_files_can_still_be_removed_after_the_components(self) -> None:
        """组件一般先卸,剩下的正好就是工具文件;这时候再报「没有已安装组件」就只能手工 rm 了。"""
        self.patch(manager, "component_installed", lambda component: False)
        for flags in ({"remove_tools": True, "purge": False}, {"remove_tools": False, "purge": True}):
            with self.subTest(**flags):
                args = argparse.Namespace(components="", **flags)
                self.assertEqual(manager.resolve_uninstall_components(args), [])
        args = argparse.Namespace(components="", purge=False, remove_tools=True, dry_run=True, yes=True)
        output = self.capture(lambda: manager.print_uninstall_plan([], args))
        self.assertIn("<none installed>", output)
        self.assertIn("Remove tool paths:", output)
        self.assertNotIn("Stop and disable services:", output)


class LegacyInstallTest(ManagerTestCase):
    """老的 tools.old/grafana/install.sh 装在 /usr/local/bin 和 /etc/prometheus,两套并存会抢端口。"""

    def test_install_refuses_while_the_old_layout_is_present(self) -> None:
        legacy = self.root / "usr" / "local" / "bin" / "node_exporter"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("old binary", encoding="utf-8")
        self.patch(manager, "LEGACY_PATHS", (legacy,))
        with self.assertRaises(common.CLIError) as caught:
            manager.require_no_legacy_install(manager.NODE_EXPORTER, False)
        self.assertIn(str(legacy), str(caught.exception))
        manager.require_no_legacy_install(manager.NODE_EXPORTER, True)

    def test_an_unmanaged_unit_file_is_reported(self) -> None:
        unit = self.root / "node_exporter.service"
        unit.write_text("[Service]\nExecStart=/usr/local/bin/node_exporter\n", encoding="utf-8")
        self.patch(manager, "LEGACY_PATHS", ())
        self.patch(manager, "service_file", lambda component: unit)
        self.assertIn(unit, manager.legacy_install_paths())
        unit.write_text(manager.managed_text("[Service]\nExecStart=/opt/monitoring/bin/node_exporter"),
                        encoding="utf-8")
        self.assertEqual(manager.legacy_install_paths(), [])


class ChecksumAndArchiveTest(ManagerTestCase):
    def test_sha256sums_entry_must_match(self) -> None:
        archive = self.root / "node_exporter-1.12.1.linux-amd64.tar.gz"
        archive.write_bytes(b"release")
        digest = common.sha256_file(archive)
        sums = self.root / "sha256sums.txt"
        sums.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
        manager.verify_sha256sums(archive, sums)
        sums.write_text(f"{'0' * 64}  {archive.name}\n", encoding="utf-8")
        with self.assertRaises(common.CLIError):
            manager.verify_sha256sums(archive, sums)
        sums.write_text(f"{digest}  something-else.tar.gz\n", encoding="utf-8")
        with self.assertRaises(common.CLIError):
            manager.verify_sha256sums(archive, sums)

    def test_grafana_publishes_a_bare_hash(self) -> None:
        archive = self.root / "grafana-13.2.2.linux-amd64.tar.gz"
        archive.write_bytes(b"release")
        sums = self.root / "grafana.sha256"
        sums.write_text(common.sha256_file(archive) + "\n", encoding="utf-8")
        manager.verify_single_sha256(archive, sums)
        sums.write_text("not a hash\n", encoding="utf-8")
        with self.assertRaises(common.CLIError):
            manager.verify_single_sha256(archive, sums)

    def test_extract_keeps_the_executable_bit(self) -> None:
        source = self.root / "node_exporter"
        source.write_text("#!/bin/sh\necho ran\n", encoding="utf-8")
        os.chmod(source, 0o755)
        archive = self.root / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            handle.add(source, "node_exporter-1.12.1.linux-amd64/node_exporter")
        output = self.root / "extract"
        common.extract_tar_gz(archive, output)
        extracted = output / "node_exporter-1.12.1.linux-amd64" / "node_exporter"
        self.assertTrue(extracted.stat().st_mode & stat.S_IXUSR)

    def test_extract_refuses_to_escape_the_target_directory(self) -> None:
        """release 包是从网上下来的,一个 ../ 成员就能覆盖目标目录之外的文件。"""
        archive = self.root / "evil.tar.gz"
        payload = self.root / "payload"
        payload.write_text("owned", encoding="utf-8")
        with tarfile.open(archive, "w:gz") as handle:
            handle.add(payload, "../escaped")
        with self.assertRaises(common.CLIError):
            common.extract_tar_gz(archive, self.root / "extract")
        self.assertFalse((self.root / "escaped").exists())


class InstallFlowTest(ManagerTestCase):
    """安装流程里顺序是承重的:元数据要先落盘,生成 prometheus.yml 才知道监听地址和 job。"""

    def stub_install(self, component: object, version: str) -> Path:
        source = self.root / "release" / component.service
        source.mkdir(parents=True)
        for name in component.binaries:
            (source / name).write_text("#!/bin/sh\n", encoding="utf-8")
        self.patch(manager, "require_install_environment", lambda: None)
        self.patch(manager, "resolve_version", lambda comp, requested: version)
        self.patch(manager, "create_install_tmpdir", lambda prefix: Path(tempfile.mkdtemp(dir=str(self.root))))
        self.patch(manager, "download_prometheus_release", lambda comp, ver, arch, tmp: source)
        self.patch(manager, "ensure_user", lambda comp: self.root_calls.append(["useradd", comp.user]))
        self.patch(manager, "stage_binaries", lambda comp, src, ver: [])
        self.patch(manager, "switch_binaries", lambda comp, ver: None)
        self.patch(manager, "enable_service", lambda comp: None)
        self.patch(manager, "check_prometheus_config", lambda: None)
        self.patch(manager, "maybe_install_tool_snapshot", lambda flag: None)
        self.patch(manager, "report_endpoint", lambda label, url: None)
        return source

    def prometheus_install_stubs(self) -> None:
        self.stub_install(manager.PROMETHEUS, "3.14.0")

    def prometheus_install(self, **overrides: object) -> None:
        self.stub_install(manager.PROMETHEUS, "3.14.0")
        values: dict[str, object] = {"version": "latest", "listen": "0.0.0.0:9090", "retention": "30d",
                                     "scrape_interval": "20s", "external_url": "", "job": "node",
                                     "extra_arg": [], "scrape_local_node": True, "force": False,
                                     "install_tools": False}
        values.update(overrides)
        self.capture(lambda: manager.cmd_prometheus_install(argparse.Namespace(**values)))

    def grafana_install(self, **overrides: object) -> str:
        self.stub_install(manager.GRAFANA, "13.2.2")
        source = self.root / "release" / "grafana"
        (source / "bin").mkdir(parents=True, exist_ok=True)
        (source / "bin" / "grafana").write_text("#!/bin/sh\n", encoding="utf-8")
        self.patch(manager, "download_grafana_release", lambda ver, arch, tmp: source)
        self.patch(manager, "stage_grafana", lambda src, ver: src)
        self.patch(manager, "atomic_symlink", lambda target, link: None)
        values: dict[str, object] = {"version": "latest", "listen_addr": "0.0.0.0", "port": 3000,
                                     "domain": "localhost", "root_url": "", "prometheus_url": "",
                                     "datasource": False, "force": False, "install_tools": False}
        values.update(overrides)
        return self.capture(lambda: manager.cmd_grafana_install(argparse.Namespace(**values)))

    def test_prometheus_install_writes_config_unit_and_metadata(self) -> None:
        self.prometheus_install()

        config = manager.PROMETHEUS_CONFIG_FILE.read_text(encoding="utf-8")
        self.assertTrue(config.startswith(manager.MANAGED_MARKER))
        self.assertIn("scrape_interval:     20s", config)
        self.assertIn("targets: ['127.0.0.1:9090']", config)
        self.assertIn("  - job_name: 'node'", config)

        unit = manager.service_file(manager.PROMETHEUS).read_text(encoding="utf-8")
        self.assertIn("--storage.tsdb.retention.time=30d", unit)
        self.assertIn("--web.listen-address=0.0.0.0:9090", unit)

        record = manager.component_record(manager.PROMETHEUS)
        self.assertEqual(record["version"], "3.14.0")
        self.assertEqual(record["listen"], "0.0.0.0:9090")
        self.assertEqual(record["retention"], "30d")
        self.assertEqual(manager.read_target_entries("node"), [])

    def assert_user_created_first(self, component: object) -> None:
        """data 目录要 chown 给服务用户,用户还没建的时候 install -d -o <user> 直接失败。

        这是在真机上撞出来的:单元测试把建用户和建目录都打了桩,顺序错了也看不出来。
        """
        order = [" ".join(call) for call in self.root_calls]
        created = next((i for i, call in enumerate(order) if call == f"useradd {component.user}"), -1)
        chowned = [i for i, call in enumerate(order)
                   if call.startswith("install -d") and f"-o {component.user}" in call]
        self.assertGreaterEqual(created, 0, f"{component.name}: the service user is never created")
        self.assertTrue(chowned, f"{component.name}: no directory is owned by the service user")
        self.assertLess(created, min(chowned),
                        f"{component.name}: the user must be created before its directories")

    def test_prometheus_creates_its_user_before_its_directories(self) -> None:
        self.prometheus_install()
        self.assert_user_created_first(manager.PROMETHEUS)

    def test_grafana_creates_its_user_before_its_directories(self) -> None:
        self.grafana_install()
        self.assert_user_created_first(manager.GRAFANA)

    def test_grafana_install_points_at_a_dashboard_to_import(self) -> None:
        """数据源配好了、数据也在采,但 Grafana 不自带面板,首页是空的。
        装完不说这件事,用起来就像装坏了 —— 真实反馈就是这么来的。"""
        output = self.grafana_install()
        self.assertIn("Dashboards -> New -> Import", output)
        self.assertIn(str(manager.GRAFANA_DASHBOARD_ID), output)

    def test_grafana_config_turns_off_the_startup_plugin_updater(self) -> None:
        """真机上撞出来的:它会把自带插件就地更新,写不进 root 的 release 树,
        更新到一半失败后那个插件就是注销状态 —— provision 好的数据源直接不可用。"""
        self.grafana_install()
        config = manager.GRAFANA_CONFIG_FILE.read_text(encoding="utf-8")
        self.assertIn("[plugins]", config)
        self.assertIn("preinstall_disabled = true", config)

    def test_grafana_creates_every_provisioning_directory(self) -> None:
        """少一个目录 Grafana 每次启动就报一条 level=error。"""
        self.grafana_install()
        for name in manager.GRAFANA_PROVISIONING_SUBDIRS:
            with self.subTest(directory=name):
                self.assertTrue((manager.GRAFANA_PROVISIONING_DIR / name).is_dir(),
                                f"provisioning/{name} was not created")

    def test_a_release_already_on_disk_is_not_downloaded_again(self) -> None:
        """重跑 install 是改监听地址/retention/Grafana 配置的方式,不该每次重下一遍包。"""
        for name in manager.PROMETHEUS.binaries:
            path = manager.BINARY_VERSION_DIR / f"{name}-3.14.0"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"#!/bin/sh\necho '{name}, version 3.14.0 (branch: HEAD)'\n", encoding="utf-8")
            os.chmod(path, 0o755)
        self.assertTrue(manager.release_already_staged(manager.PROMETHEUS, "3.14.0"))
        self.assertFalse(manager.release_already_staged(manager.PROMETHEUS, "3.13.0"))

        downloads: list[str] = []
        self.prometheus_install_stubs()
        self.patch(manager, "download_prometheus_release",
                   lambda comp, ver, arch, tmp: downloads.append(ver))
        args = argparse.Namespace(version="3.14.0", listen="127.0.0.1:9090", retention="30d",
                                  scrape_interval="15s", external_url="", job="node", extra_arg=[],
                                  scrape_local_node=False, force=False, install_tools=False)
        output = self.capture(lambda: manager.cmd_prometheus_install(args))
        self.assertEqual(downloads, [], "the release on disk should be reused")
        self.assertEqual(manager.component_record(manager.PROMETHEUS)["retention"], "30d")
        del output

    def test_a_damaged_staged_release_is_downloaded_again(self) -> None:
        """盘上的文件跑不起来或版本对不上,就不能当作已装好。"""
        path = manager.BINARY_VERSION_DIR / "prometheus-3.14.0"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("truncated", encoding="utf-8")
        os.chmod(path, 0o644)
        self.assertFalse(manager.release_already_staged(manager.PROMETHEUS, "3.14.0"))

    def test_data_kept_across_an_uninstall_is_handed_back_to_the_new_user(self) -> None:
        """uninstall 删用户但留数据,重装的用户未必拿到同一个 uid —— 那些文件就没人能写了。"""
        calls: list[list[str]] = []
        self.patch(manager, "run_root", lambda args, **kw: calls.append([str(a) for a in args]))
        manager.PROMETHEUS_DATA_DIR.mkdir(parents=True, exist_ok=True)
        own_uid = os.stat(manager.PROMETHEUS_DATA_DIR).st_uid
        self.patch(manager, "pwd", _FakePwd(own_uid + 1))
        manager.reclaim_data_dir(manager.PROMETHEUS_DATA_DIR, "prometheus")
        self.assertIn(["chown", "-R", "prometheus:prometheus", str(manager.PROMETHEUS_DATA_DIR)], calls)

        calls.clear()
        self.patch(manager, "pwd", _FakePwd(own_uid))
        manager.reclaim_data_dir(manager.PROMETHEUS_DATA_DIR, "prometheus")
        self.assertEqual(calls, [], "already owned, nothing to chown")

        calls.clear()
        manager.reclaim_data_dir(self.root / "does-not-exist", "prometheus")
        self.assertEqual(calls, [], "a fresh install has no data directory yet")

    def test_prometheus_install_keeps_existing_targets(self) -> None:
        """改 --retention 要重跑 install,已有的抓取目标不能被这次重装抹掉。"""
        manager.add_target_entry("node", "10.0.0.11:9100", {"instance": "web-1"})
        self.prometheus_install(listen="127.0.0.1:9090", retention="60d",
                                scrape_interval="15s", scrape_local_node=False)
        self.assertEqual(manager.entry_addresses(manager.read_target_entries("node")), ["10.0.0.11:9100"])
        self.assertEqual(manager.component_record(manager.PROMETHEUS)["retention"], "60d")

    def test_node_exporter_install_records_its_listen_address(self) -> None:
        self.stub_install(manager.NODE_EXPORTER, "1.12.1")
        args = argparse.Namespace(version="latest", listen="0.0.0.0:9100", enable_collector=["systemd"],
                                  disable_collector=[], extra_arg=[], force=False, install_tools=False)
        self.capture(lambda: manager.cmd_node_exporter_install(args))
        unit = manager.service_file(manager.NODE_EXPORTER).read_text(encoding="utf-8")
        self.assertIn("--collector.systemd", unit)
        record = manager.component_record(manager.NODE_EXPORTER)
        self.assertEqual(record["listen"], "0.0.0.0:9100")
        self.assertEqual(record["version"], "1.12.1")

    def test_install_metadata_keeps_the_other_components(self) -> None:
        """两个组件装在同一台机器上时,后装的不能把先装的记录冲掉。"""
        self.stub_install(manager.NODE_EXPORTER, "1.12.1")
        node_args = argparse.Namespace(version="latest", listen="127.0.0.1:9100", enable_collector=[],
                                       disable_collector=[], extra_arg=[], force=False, install_tools=False)
        self.capture(lambda: manager.cmd_node_exporter_install(node_args))
        self.prometheus_install(listen="127.0.0.1:9090", retention="15d", scrape_local_node=False)
        self.assertEqual(sorted(manager.component_records()), ["node-exporter", "prometheus"])
        manager.forget_component(manager.NODE_EXPORTER)
        self.assertEqual(sorted(manager.component_records()), ["prometheus"])


class DashboardHintTest(ManagerTestCase):
    """导入面板这一步在三个地方都要说到:装完的提示、quickstart、tutor。"""

    def test_quickstart_mentions_the_import(self) -> None:
        output = self.capture(lambda: manager.cmd_quickstart(argparse.Namespace()))
        self.assertIn("Dashboards -> New -> Import", output)
        self.assertIn(str(manager.GRAFANA_DASHBOARD_ID), output)

    def test_tutor_explains_the_offline_case(self) -> None:
        """按 ID 导入是 Grafana 服务端去 grafana.com 拉,连不上的机器要换个办法。"""
        topic = manager.TUTOR_TOPICS["grafana"]
        self.assertIn("Dashboards -> New -> Import", topic)
        self.assertIn("Import via dashboard JSON model", topic)
        self.assertIn("grafana.com", topic)

    def test_the_hint_wraps_to_its_context(self) -> None:
        """提示要跟着周围文本的缩进走,不然 quickstart 里会突出来一行。"""
        self.assertEqual(manager.dashboard_hint("  ").split("\n")[1][:2], "  ")
        self.assertEqual(manager.dashboard_hint("     ").split("\n")[1][:5], "     ")
        for line in manager.dashboard_hint("     ").split("\n"):
            self.assertLessEqual(len(line), 88, "the hint must not overflow the surrounding text")


class AddressTest(unittest.TestCase):
    def test_reachable_address_replaces_a_wildcard_bind(self) -> None:
        self.assertEqual(manager.reachable_address("0.0.0.0:9100"), "127.0.0.1:9100")
        self.assertEqual(manager.reachable_address("10.0.0.5:9100"), "10.0.0.5:9100")
        self.assertEqual(manager.reachable_address("127.0.0.1:9090"), "127.0.0.1:9090")

    def test_labels_must_be_key_value(self) -> None:
        self.assertEqual(manager.parse_label("instance=web-1"), ("instance", "web-1"))
        for bad in ("instance", "1bad=x", 'q="x"'):
            with self.subTest(label=bad), self.assertRaises(common.CLIError):
                manager.parse_label(bad)


if __name__ == "__main__":
    unittest.main()
