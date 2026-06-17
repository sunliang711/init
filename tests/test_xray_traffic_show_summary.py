import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


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

    def run_tool(self, *args: str) -> str:
        """执行 xray-traffic CLI 并返回 stdout，适用于端到端验证 show 输出。"""

        result = subprocess.run(
            [
                sys.executable,
                str(XRAY_TRAFFIC),
                "--db",
                str(self.db_path),
                "--timezone",
                "UTC",
                *args,
            ],
            check=True,
            capture_output=True,
            text=True,
            env=self.env,
        )
        return result.stdout

    def insert_records(self, period: str, start_ts: int, end_ts: int) -> None:
        """写入两个实例的同名用户流量，适用于验证跨实例求和。"""

        rows = [
            ("usa1", "127.0.0.1:18080", period, start_ts, end_ts, "user", "frp200", "up", 100),
            ("usa1", "127.0.0.1:18080", period, start_ts, end_ts, "user", "frp200", "down", 300),
            ("usa3", "127.0.0.1:18081", period, start_ts, end_ts, "user", "frp200", "up", 20),
            ("usa3", "127.0.0.1:18081", period, start_ts, end_ts, "user", "frp200", "down", 40),
        ]
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


if __name__ == "__main__":
    unittest.main()
