import os
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
XRAY_TRAFFIC = REPO_ROOT / "tools" / "xray" / "traffic" / "xray-traffic"


class XrayTrafficShowSummaryTest(unittest.TestCase):
    """验证 xray-traffic show 多实例输出的小计行。"""

    def setUp(self) -> None:
        """创建临时数据库和多实例环境，适用于隔离 CLI 输出测试。"""

        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp_dir.name) / "traffic.db"
        self.env = os.environ.copy()
        self.env.update(
            {
                "XRAY_TRAFFIC_INSTANCES": "usa1=127.0.0.1:18080,usa3=127.0.0.1:18081",
                "NO_COLOR": "1",
                "TERM": "dumb",
            }
        )
        self.run_tool("check", "health")

    def tearDown(self) -> None:
        """清理临时数据库目录，适用于避免测试文件残留。"""

        self.temp_dir.cleanup()

    def run_tool_with_global_options(self, global_options: list[str], *args: str) -> str:
        """执行 xray-traffic CLI 并返回 stdout，适用于需要额外全局选项的端到端验证。"""

        result = subprocess.run(
            [
                sys.executable,
                str(XRAY_TRAFFIC),
                "--db",
                str(self.db_path),
                "--timezone",
                "UTC",
                *global_options,
                *args,
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.env,
        )
        return result.stdout

    def run_tool(self, *args: str) -> str:
        """执行 xray-traffic CLI 并返回 stdout，适用于端到端验证 show 输出。"""

        return self.run_tool_with_global_options([], *args)

    def run_tool_result(self, *args: str) -> subprocess.CompletedProcess[str]:
        """执行 xray-traffic CLI 并返回完整结果，适用于验证失败路径。"""

        return self.run_tool_result_with_global_options([], *args)

    def run_tool_result_with_global_options(
        self,
        global_options: list[str],
        *args: str,
    ) -> subprocess.CompletedProcess[str]:
        """执行 xray-traffic CLI 并返回完整结果，适用于验证额外全局选项。"""

        return subprocess.run(
            [
                sys.executable,
                str(XRAY_TRAFFIC),
                "--db",
                str(self.db_path),
                "--timezone",
                "UTC",
                *global_options,
                *args,
            ],
            check=False,
            capture_output=True,
            text=True,
            env=self.env,
        )

    def write_fake_xray(
        self,
        values_by_server: dict[str, tuple[int, int]],
        fail_servers: Optional[set[str]] = None,
    ) -> Path:
        """写入临时 xray 可执行文件，适用于模拟 statsquery current 计数。"""

        fail_servers = fail_servers or set()
        fake_xray = Path(self.temp_dir.name) / "fake-xray"
        payload = {
            server: {"up": values[0], "down": values[1]}
            for server, values in values_by_server.items()
        }
        script = f"""#!/usr/bin/env python3
import json
import sys

values_by_server = json.loads({json.dumps(json.dumps(payload))})
fail_servers = set(json.loads({json.dumps(json.dumps(sorted(fail_servers)))}))
server = ""
for arg in sys.argv:
    if arg.startswith("--server="):
        server = arg.split("=", 1)[1]

if server in fail_servers:
    sys.stderr.write("mock statsquery failure\\n")
    sys.exit(9)

values = values_by_server.get(server, {{"up": 0, "down": 0}})
print(json.dumps({{
    "stat": [
        {{"name": "user>>>frp200>>>traffic>>>uplink", "value": values["up"]}},
        {{"name": "user>>>frp200>>>traffic>>>downlink", "value": values["down"]}},
    ]
}}))
"""
        fake_xray.write_text(script, encoding="utf-8")
        fake_xray.chmod(0o755)
        return fake_xray

    def insert_traffic_rows(self, rows: list[tuple[str, str, str, int, int, str, str, str, int]]) -> None:
        """写入自定义流量记录，适用于构造 monthly、yearly 和 cleanup 场景。"""

        with sqlite3.connect(self.db_path) as connection:
            connection.executemany(
                """
                INSERT INTO traffic_records (
                    instance, server, period, start_ts, end_ts, start_time, end_time,
                    scope, name, direction, bytes, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        instance,
                        server,
                        record_period,
                        record_start_ts,
                        record_end_ts,
                        datetime.fromtimestamp(record_start_ts, timezone.utc).isoformat(),
                        datetime.fromtimestamp(record_end_ts, timezone.utc).isoformat(),
                        scope,
                        name,
                        direction,
                        bytes_value,
                        datetime.now(timezone.utc).isoformat(),
                    )
                    for (
                        instance,
                        server,
                        record_period,
                        record_start_ts,
                        record_end_ts,
                        scope,
                        name,
                        direction,
                        bytes_value,
                    ) in rows
                ],
            )

    def insert_records(self, period: str, start_ts: int, end_ts: int) -> None:
        """写入两个实例的同名用户流量，适用于验证跨实例求和。"""

        rows = [
            ("usa1", "127.0.0.1:18080", period, start_ts, end_ts, "user", "frp200", "up", 100),
            ("usa1", "127.0.0.1:18080", period, start_ts, end_ts, "user", "frp200", "down", 300),
            ("usa3", "127.0.0.1:18081", period, start_ts, end_ts, "user", "frp200", "up", 20),
            ("usa3", "127.0.0.1:18081", period, start_ts, end_ts, "user", "frp200", "down", 40),
        ]
        self.insert_traffic_rows(rows)

    @staticmethod
    def add_months(month_start: datetime, months: int) -> datetime:
        """按月偏移 UTC 月份起点，适用于构造测试数据。"""

        month_index = month_start.year * 12 + month_start.month - 1 + months
        year = month_index // 12
        month = month_index % 12 + 1
        return datetime(year, month, 1, tzinfo=timezone.utc)

    @staticmethod
    def current_month_start() -> datetime:
        """返回当前 UTC 月份起点，适用于构造相对当前时间的保留期测试。"""

        return datetime.now(timezone.utc).replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    def test_show_hourly_all_appends_instance_total(self) -> None:
        """验证 hourly 多实例查询会在同一小时后追加 ALL 小计。"""

        start_ts = int(datetime(2026, 6, 17, 8, tzinfo=timezone.utc).timestamp())
        self.insert_records("hourly", start_ts, start_ts + 3600)

        output = self.run_tool(
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            "2026-06-17",
        )

        self.assertRegex(output, r"2026-06-17 08:00 usa1\s+user\s+frp200\s+100B\s+300B\s+400B")
        self.assertRegex(output, r"2026-06-17 08:00 usa3\s+user\s+frp200\s+20B\s+40B\s+60B")
        self.assertRegex(output, r"2026-06-17 08:00 ALL\s+user\s+frp200\s+120B\s+340B\s+460B")

    def test_show_daily_all_appends_instance_total(self) -> None:
        """验证 daily 多实例查询会在同一天后追加 ALL 小计。"""

        start_ts = int(datetime(2026, 6, 17, tzinfo=timezone.utc).timestamp())
        self.insert_records("daily", start_ts, start_ts + 86400)

        output = self.run_tool(
            "show",
            "daily",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            "2026-06-17",
        )

        self.assertRegex(output, r"2026-06-17\s+usa1\s+user\s+frp200\s+100B\s+300B\s+400B")
        self.assertRegex(output, r"2026-06-17\s+usa3\s+user\s+frp200\s+20B\s+40B\s+60B")
        self.assertRegex(output, r"2026-06-17\s+ALL\s+user\s+frp200\s+120B\s+340B\s+460B")

    def test_collect_monthly_is_idempotent(self) -> None:
        """验证 monthly 从 daily 聚合，并在重跑时先删除同月旧数据。"""

        target_month = self.add_months(self.current_month_start(), -1)
        next_month = self.add_months(target_month, 1)
        day_one = target_month
        day_two = target_month + timedelta(days=1)
        month_value = target_month.strftime("%Y-%m")
        self.insert_traffic_rows(
            [
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "daily",
                    int(day_one.timestamp()),
                    int((day_one + timedelta(days=1)).timestamp()),
                    "user",
                    "frp200",
                    "up",
                    100,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "daily",
                    int(day_one.timestamp()),
                    int((day_one + timedelta(days=1)).timestamp()),
                    "user",
                    "frp200",
                    "down",
                    300,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "daily",
                    int(day_two.timestamp()),
                    int((day_two + timedelta(days=1)).timestamp()),
                    "user",
                    "frp200",
                    "up",
                    200,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "daily",
                    int(day_two.timestamp()),
                    int((day_two + timedelta(days=1)).timestamp()),
                    "user",
                    "frp200",
                    "down",
                    400,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "monthly",
                    int(target_month.timestamp()),
                    int(next_month.timestamp()),
                    "user",
                    "stale",
                    "up",
                    999,
                ),
            ]
        )

        self.run_tool("collect", "monthly", "--instance", "usa1", "--month", month_value)
        self.run_tool("collect", "monthly", "--instance", "usa1", "--month", month_value)

        with sqlite3.connect(self.db_path) as connection:
            rows = connection.execute(
                """
                SELECT scope, name, direction, bytes
                FROM traffic_records
                WHERE instance = 'usa1'
                  AND period = 'monthly'
                  AND start_ts = ?
                ORDER BY scope, name, direction
                """,
                (int(target_month.timestamp()),),
            ).fetchall()

        self.assertEqual(
            [("user", "frp200", "down", 700), ("user", "frp200", "up", 300)],
            rows,
        )

    def test_show_monthly_all_appends_instance_total(self) -> None:
        """验证 monthly 多实例查询会在同一月后追加 ALL 小计。"""

        target_month = self.add_months(self.current_month_start(), -1)
        next_month = self.add_months(target_month, 1)
        self.insert_records("monthly", int(target_month.timestamp()), int(next_month.timestamp()))

        output = self.run_tool(
            "show",
            "monthly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--month",
            target_month.strftime("%Y-%m"),
        )

        month_label = target_month.strftime("%Y-%m")
        self.assertRegex(output, rf"{month_label}\s+usa1\s+user\s+frp200\s+100B\s+300B\s+400B")
        self.assertRegex(output, rf"{month_label}\s+usa3\s+user\s+frp200\s+20B\s+40B\s+60B")
        self.assertRegex(output, rf"{month_label}\s+ALL\s+user\s+frp200\s+120B\s+340B\s+460B")

    def test_show_yearly_aggregates_from_monthly(self) -> None:
        """验证 yearly 不落库，直接从 monthly 记录聚合。"""

        target_year = datetime.now(timezone.utc).year - 1
        january = datetime(target_year, 1, 1, tzinfo=timezone.utc)
        february = datetime(target_year, 2, 1, tzinfo=timezone.utc)
        march = datetime(target_year, 3, 1, tzinfo=timezone.utc)
        self.insert_traffic_rows(
            [
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "monthly",
                    int(january.timestamp()),
                    int(february.timestamp()),
                    "user",
                    "frp200",
                    "up",
                    100,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "monthly",
                    int(january.timestamp()),
                    int(february.timestamp()),
                    "user",
                    "frp200",
                    "down",
                    300,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "monthly",
                    int(february.timestamp()),
                    int(march.timestamp()),
                    "user",
                    "frp200",
                    "up",
                    200,
                ),
                (
                    "usa1",
                    "127.0.0.1:18080",
                    "monthly",
                    int(february.timestamp()),
                    int(march.timestamp()),
                    "user",
                    "frp200",
                    "down",
                    400,
                ),
                (
                    "usa3",
                    "127.0.0.1:18081",
                    "monthly",
                    int(january.timestamp()),
                    int(february.timestamp()),
                    "user",
                    "frp200",
                    "up",
                    20,
                ),
                (
                    "usa3",
                    "127.0.0.1:18081",
                    "monthly",
                    int(january.timestamp()),
                    int(february.timestamp()),
                    "user",
                    "frp200",
                    "down",
                    40,
                ),
            ]
        )

        output = self.run_tool(
            "show",
            "yearly",
            "--instance",
            "usa1",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--year",
            str(target_year),
        )

        self.assertRegex(output, rf"{target_year}\s+usa1\s+user\s+frp200\s+300B\s+700B\s+1000B")

        all_output = self.run_tool(
            "show",
            "yearly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--year",
            str(target_year),
        )

        self.assertRegex(all_output, rf"{target_year}\s+usa1\s+user\s+frp200\s+300B\s+700B\s+1000B")
        self.assertRegex(all_output, rf"{target_year}\s+usa3\s+user\s+frp200\s+20B\s+40B\s+60B")
        self.assertRegex(all_output, rf"{target_year}\s+ALL\s+user\s+frp200\s+320B\s+740B\s+1\.04KiB")

    def test_show_hourly_appends_current_period(self) -> None:
        """验证 hourly 会追加当前小时动态结果和 ALL 小计。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            }
        )
        current_hour = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)

        output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
        )

        hour_label = current_hour.strftime("%Y-%m-%d %H:00")
        self.assertRegex(output, rf"{hour_label}\s+usa1\s+user\s+frp200\s+5B\s+7B\s+12B")
        self.assertRegex(output, rf"{hour_label}\s+usa3\s+user\s+frp200\s+11B\s+13B\s+24B")
        self.assertRegex(output, rf"{hour_label}\s+ALL\s+user\s+frp200\s+16B\s+20B\s+36B")

    def test_show_daily_current_combines_hourly_and_current(self) -> None:
        """验证 daily 当前日由已落库 hourly 加 current 动态值组成。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            }
        )
        now = datetime.now(timezone.utc)
        current_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        current_hour = now.replace(minute=0, second=0, microsecond=0)
        history_up = 0
        history_down = 0
        if current_hour > current_day:
            start_ts = int((current_hour - timedelta(hours=1)).timestamp())
            self.insert_records("hourly", start_ts, int(current_hour.timestamp()))
            history_up = 120
            history_down = 340

        output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "daily",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            current_day.strftime("%Y-%m-%d"),
        )

        day_label = current_day.strftime("%Y-%m-%d")
        expected_up = history_up + 16
        expected_down = history_down + 20
        expected_total = expected_up + expected_down
        self.assertRegex(output, rf"{day_label}\s+ALL\s+user\s+frp200\s+{expected_up}B\s+{expected_down}B\s+{expected_total}B")

    def test_show_monthly_current_combines_daily_and_today(self) -> None:
        """验证 monthly 当前月由已落库 daily 加今天动态值组成。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            }
        )
        now = datetime.now(timezone.utc)
        current_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        current_month = current_day.replace(day=1)
        history_up = 0
        history_down = 0
        if current_day > current_month:
            start_ts = int((current_day - timedelta(days=1)).timestamp())
            self.insert_records("daily", start_ts, int(current_day.timestamp()))
            history_up = 120
            history_down = 340

        output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "monthly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--month",
            current_month.strftime("%Y-%m"),
        )

        month_label = current_month.strftime("%Y-%m")
        expected_up = history_up + 16
        expected_down = history_down + 20
        expected_total = expected_up + expected_down
        self.assertRegex(output, rf"{month_label}\s+ALL\s+user\s+frp200\s+{expected_up}B\s+{expected_down}B\s+{expected_total}B")

    def test_show_yearly_current_combines_monthly_and_month(self) -> None:
        """验证 yearly 当前年由已落库 monthly 加本月动态值组成。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            }
        )
        now = datetime.now(timezone.utc)
        current_month = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        current_year = current_month.replace(month=1)
        history_up = 0
        history_down = 0
        if current_month > current_year:
            previous_month = self.add_months(current_month, -1)
            self.insert_records("monthly", int(previous_month.timestamp()), int(current_month.timestamp()))
            history_up = 120
            history_down = 340

        output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "yearly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--year",
            current_year.strftime("%Y"),
        )

        year_label = current_year.strftime("%Y")
        expected_up = history_up + 16
        expected_down = history_down + 20
        expected_total = expected_up + expected_down
        self.assertRegex(output, rf"{year_label}\s+ALL\s+user\s+frp200\s+{expected_up}B\s+{expected_down}B\s+{expected_total}B")

    def test_show_current_error_keeps_history_rows(self) -> None:
        """验证 current 读取失败时仍输出已落库历史行并返回非零。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            },
            fail_servers={"127.0.0.1:18081"},
        )
        current_hour = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
        history_hour = current_hour - timedelta(hours=1)
        self.insert_records("hourly", int(history_hour.timestamp()), int(current_hour.timestamp()))

        result = self.run_tool_result_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
        )

        history_label = history_hour.strftime("%Y-%m-%d %H:00")
        current_label = current_hour.strftime("%Y-%m-%d %H:00")
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stdout, rf"{history_label}\s+usa3\s+user\s+frp200\s+20B\s+40B\s+60B")
        self.assertRegex(result.stdout, rf"{current_label}\s+usa1\s+user\s+frp200\s+5B\s+7B\s+12B")
        self.assertIn("xray statsquery failed for instance usa3", result.stderr)

    def test_show_limit_counts_current_detail_rows(self) -> None:
        """验证 limit 在历史和当前动态明细合并后生效。"""

        fake_xray = self.write_fake_xray(
            {
                "127.0.0.1:18080": (5, 7),
                "127.0.0.1:18081": (11, 13),
            }
        )
        current_hour = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
        history_hour = current_hour - timedelta(hours=1)
        self.insert_records("hourly", int(history_hour.timestamp()), int(current_hour.timestamp()))

        output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--limit",
            "1",
        )

        current_label = current_hour.strftime("%Y-%m-%d %H:00")
        history_label = history_hour.strftime("%Y-%m-%d %H:00")
        self.assertRegex(output, rf"{current_label}\s+usa1\s+user\s+frp200\s+5B\s+7B\s+12B")
        self.assertNotRegex(output, rf"{current_label}\s+usa3\s+user\s+frp200")
        self.assertRegex(output, rf"{current_label}\s+ALL\s+user\s+frp200\s+16B\s+20B\s+36B")
        self.assertNotRegex(output, rf"{history_label}\s+usa1\s+user\s+frp200")

    def test_show_explicit_past_periods_do_not_append_current(self) -> None:
        """验证显式查询过去日期、月份和年份时不会读取 current。"""

        fail_servers = {"127.0.0.1:18080", "127.0.0.1:18081"}
        fake_xray = self.write_fake_xray({}, fail_servers=fail_servers)
        now = datetime.now(timezone.utc)
        current_hour = now.replace(minute=0, second=0, microsecond=0)
        current_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
        past_day = current_day - timedelta(days=1)
        past_hour = past_day + timedelta(hours=8)
        current_month = current_day.replace(day=1)
        past_month = self.add_months(current_month, -1)
        current_year = current_month.replace(month=1)
        past_year = current_year.replace(year=current_year.year - 1)

        self.insert_records("hourly", int(past_hour.timestamp()), int((past_hour + timedelta(hours=1)).timestamp()))
        self.insert_records("daily", int(past_day.timestamp()), int((past_day + timedelta(days=1)).timestamp()))
        self.insert_records("monthly", int(past_month.timestamp()), int(current_month.timestamp()))
        january_end = self.add_months(past_year, 1)
        self.insert_records("monthly", int(past_year.timestamp()), int(january_end.timestamp()))

        hourly_output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            past_day.strftime("%Y-%m-%d"),
        )
        daily_output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "daily",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            past_day.strftime("%Y-%m-%d"),
        )
        monthly_output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "monthly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--month",
            past_month.strftime("%Y-%m"),
        )
        yearly_output = self.run_tool_with_global_options(
            ["--xray-bin", str(fake_xray)],
            "show",
            "yearly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--year",
            past_year.strftime("%Y"),
        )

        self.assertRegex(hourly_output, rf"{past_hour.strftime('%Y-%m-%d %H:00')}\s+ALL\s+user\s+frp200")
        self.assertNotIn(current_hour.strftime("%Y-%m-%d %H:00"), hourly_output)
        self.assertRegex(daily_output, rf"{past_day.strftime('%Y-%m-%d')}\s+ALL\s+user\s+frp200")
        self.assertNotIn(current_day.strftime("%Y-%m-%d"), daily_output)
        self.assertRegex(monthly_output, rf"{past_month.strftime('%Y-%m')}\s+ALL\s+user\s+frp200")
        self.assertNotIn(current_month.strftime("%Y-%m"), monthly_output)
        self.assertRegex(yearly_output, rf"{past_year.strftime('%Y')}\s+ALL\s+user\s+frp200")
        self.assertNotIn(current_year.strftime("%Y"), yearly_output)

    def test_show_months_and_years_zero_are_errors(self) -> None:
        """验证 --months 0 和 --years 0 不会被静默替换为默认值。"""

        monthly_result = self.run_tool_result("show", "monthly", "--instance", "usa1", "--months", "0")
        yearly_result = self.run_tool_result("show", "yearly", "--instance", "usa1", "--years", "0")

        self.assertNotEqual(monthly_result.returncode, 0)
        self.assertIn("--months must be greater than 0", monthly_result.stderr)
        self.assertNotEqual(yearly_result.returncode, 0)
        self.assertIn("--years must be greater than 0", yearly_result.stderr)

    def test_show_single_instance_keeps_detail_only(self) -> None:
        """验证单实例查询保持原有输出，不追加 ALL 小计。"""

        start_ts = int(datetime(2026, 6, 17, 8, tzinfo=timezone.utc).timestamp())
        self.insert_records("hourly", start_ts, start_ts + 3600)

        output = self.run_tool(
            "show",
            "hourly",
            "--instance",
            "usa1",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            "2026-06-17",
        )

        self.assertRegex(output, r"2026-06-17 08:00 usa1\s+user\s+frp200\s+100B\s+300B\s+400B")
        self.assertNotRegex(output, r"2026-06-17 08:00 ALL\s+user\s+frp200")

    def test_show_all_total_ignores_detail_limit(self) -> None:
        """验证 ALL 小计不受明细 LIMIT 截断影响。"""

        start_ts = int(datetime(2026, 6, 17, 8, tzinfo=timezone.utc).timestamp())
        self.insert_records("hourly", start_ts, start_ts + 3600)

        output = self.run_tool(
            "show",
            "hourly",
            "--instance",
            "ALL",
            "--scope",
            "user",
            "--name",
            "frp200",
            "--date",
            "2026-06-17",
            "--limit",
            "1",
        )

        self.assertRegex(output, r"2026-06-17 08:00 usa1\s+user\s+frp200\s+100B\s+300B\s+400B")
        self.assertNotRegex(output, r"2026-06-17 08:00 usa3\s+user\s+frp200")
        self.assertRegex(output, r"2026-06-17 08:00 ALL\s+user\s+frp200\s+120B\s+340B\s+460B")

    def test_cleanup_uses_period_specific_retention(self) -> None:
        """验证 cleanup 按 hourly、daily、monthly 使用不同保留策略。"""

        now = datetime.now(timezone.utc)
        current_day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        current_month = self.current_month_start()
        monthly_keep = self.add_months(current_month, -36)
        monthly_delete = self.add_months(current_month, -37)
        rows = [
            (
                "usa1",
                "127.0.0.1:18080",
                "hourly",
                int((now - timedelta(days=31)).timestamp()),
                int((now - timedelta(days=31, hours=-1)).timestamp()),
                "user",
                "hourly-delete",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "daily",
                int((current_day_start - timedelta(days=62)).timestamp()),
                int((current_day_start - timedelta(days=61)).timestamp()),
                "user",
                "daily-boundary-keep",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "hourly",
                int((now - timedelta(days=29)).timestamp()),
                int((now - timedelta(days=29, hours=-1)).timestamp()),
                "user",
                "hourly-keep",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "daily",
                int((now - timedelta(days=63)).timestamp()),
                int((now - timedelta(days=62)).timestamp()),
                "user",
                "daily-delete",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "daily",
                int((now - timedelta(days=61)).timestamp()),
                int((now - timedelta(days=60)).timestamp()),
                "user",
                "daily-keep",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "monthly",
                int(monthly_delete.timestamp()),
                int(self.add_months(monthly_delete, 1).timestamp()),
                "user",
                "monthly-delete",
                "up",
                1,
            ),
            (
                "usa1",
                "127.0.0.1:18080",
                "monthly",
                int(monthly_keep.timestamp()),
                int(self.add_months(monthly_keep, 1).timestamp()),
                "user",
                "monthly-keep",
                "up",
                1,
            ),
        ]
        self.insert_traffic_rows(rows)

        self.run_tool_with_global_options(["--retention-days", "30"], "cleanup", "records")

        with sqlite3.connect(self.db_path) as connection:
            names = {
                row[0]
                for row in connection.execute(
                    """
                    SELECT name
                    FROM traffic_records
                    WHERE name LIKE '%-delete'
                       OR name LIKE '%-keep'
                    """
                ).fetchall()
            }

        self.assertNotIn("hourly-delete", names)
        self.assertIn("hourly-keep", names)
        self.assertNotIn("daily-delete", names)
        self.assertIn("daily-boundary-keep", names)
        self.assertIn("daily-keep", names)
        self.assertNotIn("monthly-delete", names)
        self.assertIn("monthly-keep", names)


if __name__ == "__main__":
    unittest.main()
