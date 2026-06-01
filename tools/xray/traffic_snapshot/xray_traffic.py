#!/usr/bin/env python3
"""Xray 流量快照采集、聚合和查询工具。"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import time as time_module
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, TextIO, Tuple
from zoneinfo import ZoneInfo

import fcntl


VERSION = "0.1.0"
DEFAULT_APP_DIR = Path("/opt/xray-traffic")
DEFAULT_CONFIG_FILE = DEFAULT_APP_DIR / "config" / "xray-traffic.env"
DEFAULT_DB_PATH = DEFAULT_APP_DIR / "data" / "traffic.db"
DEFAULT_SERVER = "127.0.0.1:18080"
DEFAULT_XRAY_BIN = "/usr/local/bin/xray"
DEFAULT_RETENTION_DAYS = 180
DEFAULT_TIMEOUT_SECONDS = 30
VALID_SCOPES = ("inbound", "outbound", "user")
VALID_DIRECTIONS = ("up", "down")
CounterKey = Tuple[str, str, str]


class CliError(Exception):
    """表示可预期的命令行错误，适用于向用户返回简洁失败信息。"""


@dataclass(frozen=True)
class AppConfig:
    """保存运行配置，适用于所有子命令共享配置解析结果。"""

    server: str
    xray_bin: str
    db_path: Path
    retention_days: int
    timezone_name: Optional[str]
    timeout_seconds: int


@dataclass(frozen=True)
class ParsedStat:
    """保存从 Xray StatsService 解析出的单条原始统计。"""

    name: str
    value: int


@dataclass(frozen=True)
class TrafficRecord:
    """保存准备写入 SQLite 的标准化流量记录。"""

    period: str
    start_ts: int
    end_ts: int
    start_time: str
    end_time: str
    scope: str
    name: str
    direction: str
    bytes_value: int


def parse_env_file(path: Path) -> Dict[str, str]:
    """读取简单 KEY=VALUE 配置文件，适用于 systemd EnvironmentFile 兼容配置。"""

    values: Dict[str, str] = {}
    if not path.exists():
        return values

    with path.open("r", encoding="utf-8") as config_file:
        for raw_line in config_file:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key:
                values[key] = value
    return values


def pick_config_value(
    arg_value: Optional[Any],
    env_values: Dict[str, str],
    file_values: Dict[str, str],
    env_name: str,
    default: Any,
) -> Any:
    """按命令行、环境变量、配置文件、默认值的顺序选择配置值。"""

    if arg_value is not None:
        return arg_value
    if env_name in env_values:
        return env_values[env_name]
    if env_name in file_values:
        return file_values[env_name]
    return default


def resolve_config(args: argparse.Namespace) -> AppConfig:
    """解析全局配置，适用于所有子命令执行前统一生成运行参数。"""

    env_values = dict(os.environ)
    config_file_value = args.config or env_values.get("XRAY_TRAFFIC_CONFIG")
    config_file = Path(config_file_value) if config_file_value else DEFAULT_CONFIG_FILE
    file_values = parse_env_file(config_file)

    retention_days = int(
        pick_config_value(
            args.retention_days,
            env_values,
            file_values,
            "XRAY_TRAFFIC_RETENTION_DAYS",
            DEFAULT_RETENTION_DAYS,
        )
    )
    timeout_seconds = int(
        pick_config_value(
            args.timeout,
            env_values,
            file_values,
            "XRAY_TRAFFIC_TIMEOUT_SECONDS",
            DEFAULT_TIMEOUT_SECONDS,
        )
    )

    if retention_days <= 0:
        raise CliError("retention days must be greater than 0")
    if timeout_seconds <= 0:
        raise CliError("timeout seconds must be greater than 0")

    return AppConfig(
        server=str(
            pick_config_value(args.server, env_values, file_values, "XRAY_API_SERVER", DEFAULT_SERVER)
        ),
        xray_bin=str(
            pick_config_value(args.xray_bin, env_values, file_values, "XRAY_BIN", DEFAULT_XRAY_BIN)
        ),
        db_path=Path(
            str(pick_config_value(args.db, env_values, file_values, "XRAY_TRAFFIC_DB", DEFAULT_DB_PATH))
        ),
        retention_days=retention_days,
        timezone_name=pick_config_value(
            args.timezone,
            env_values,
            file_values,
            "XRAY_TRAFFIC_TIMEZONE",
            None,
        ),
        timeout_seconds=timeout_seconds,
    )


def get_timezone(config: AppConfig) -> timezone:
    """返回配置指定时区；未配置时使用系统本地时区。"""

    if config.timezone_name:
        try:
            return ZoneInfo(config.timezone_name)
        except Exception as exc:
            raise CliError(f"invalid timezone: {config.timezone_name}") from exc
    local_tz = datetime.now().astimezone().tzinfo
    if local_tz is None:
        return timezone.utc
    return local_tz


def configure_logging(level: str) -> None:
    """初始化日志输出，适用于 systemd journal 和手工命令行执行。"""

    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(levelname)s %(message)s",
    )


def ensure_database(connection: sqlite3.Connection) -> None:
    """创建 SQLite 表和索引，适用于首次运行或升级后自动补齐结构。"""

    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS traffic_records (
            period TEXT NOT NULL,
            start_ts INTEGER NOT NULL,
            end_ts INTEGER NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            scope TEXT NOT NULL,
            name TEXT NOT NULL,
            direction TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (period, start_ts, scope, name, direction)
        )
        """
    )
    connection.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_traffic_records_lookup
        ON traffic_records (period, scope, name, start_ts)
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    connection.commit()


@contextmanager
def database_lock(db_path: Path) -> Iterator[None]:
    """使用文件锁保护 SQLite 写入，避免 hourly 和 daily 定时任务并发写库。"""

    db_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = db_path.with_suffix(db_path.suffix + ".lock")
    with lock_path.open("w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


@contextmanager
def open_database(db_path: Path) -> Iterator[sqlite3.Connection]:
    """打开 SQLite 连接并确保基础表结构存在。"""

    db_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(db_path))
    connection.row_factory = sqlite3.Row
    try:
        ensure_database(connection)
        yield connection
    finally:
        connection.close()


def read_metadata(connection: sqlite3.Connection, key: str) -> Optional[str]:
    """读取 metadata 表中的单个键值，适用于保存采集游标。"""

    row = connection.execute("SELECT value FROM metadata WHERE key = ?", (key,)).fetchone()
    if row is None:
        return None
    return str(row["value"])


def write_metadata(connection: sqlite3.Connection, key: str, value: str) -> None:
    """写入 metadata 表中的单个键值，适用于更新采集游标。"""

    connection.execute(
        """
        INSERT INTO metadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, value),
    )


def isoformat(ts: int, tzinfo: timezone) -> str:
    """将 Unix 时间戳转换为带时区的秒级 ISO 字符串。"""

    return datetime.fromtimestamp(ts, tzinfo).replace(microsecond=0).isoformat()


def now_ts() -> int:
    """返回当前 Unix 秒级时间戳，适用于记录采集和写入时间。"""

    return int(datetime.now().timestamp())


def floor_to_hour(ts: int, tzinfo: timezone) -> int:
    """将时间戳向下取整到本地时区当前小时，适用于小时快照边界。"""

    current = datetime.fromtimestamp(ts, tzinfo)
    floored = current.replace(minute=0, second=0, microsecond=0)
    return int(floored.timestamp())


def date_range_for_day(day: date, tzinfo: timezone) -> Tuple[int, int]:
    """返回指定本地日期的起止 Unix 时间戳，结束时间为开区间。"""

    start_dt = datetime.combine(day, time.min, tzinfo=tzinfo)
    end_dt = start_dt + timedelta(days=1)
    return int(start_dt.timestamp()), int(end_dt.timestamp())


def parse_day(value: str) -> date:
    """解析 YYYY-MM-DD 日期参数，适用于 daily、summary、query 和 export。"""

    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise CliError(f"invalid date: {value}") from exc


def resolve_time_range(args: argparse.Namespace, tzinfo: timezone) -> Tuple[int, int]:
    """根据 --date、--from/--to 或 --days 解析查询时间范围。"""

    if getattr(args, "date", None):
        return date_range_for_day(parse_day(args.date), tzinfo)

    if getattr(args, "from_date", None) or getattr(args, "to_date", None):
        if not args.from_date or not args.to_date:
            raise CliError("--from and --to must be used together")
        start_day = parse_day(args.from_date)
        end_day = parse_day(args.to_date)
        start_ts, _ = date_range_for_day(start_day, tzinfo)
        end_ts, _ = date_range_for_day(end_day, tzinfo)
        if end_ts <= start_ts:
            raise CliError("--to must be later than --from")
        return start_ts, end_ts

    days = int(getattr(args, "days", 7) or 7)
    if days <= 0:
        raise CliError("--days must be greater than 0")
    end_ts = now_ts()
    start_ts = end_ts - days * 86400
    return start_ts, end_ts


def run_statsquery(config: AppConfig, reset: bool) -> str:
    """调用 xray api statsquery 获取统计输出，适用于真实小时采集。"""

    command = [
        config.xray_bin,
        "api",
        "statsquery",
        f"--server={config.server}",
    ]
    if reset:
        command.append("-reset=true")

    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=config.timeout_seconds,
        )
    except FileNotFoundError as exc:
        raise CliError(f"xray binary not found: {config.xray_bin}") from exc
    except subprocess.TimeoutExpired as exc:
        raise CliError("xray statsquery timed out") from exc

    if result.returncode != 0:
        stderr = result.stderr.strip() or "unknown error"
        raise CliError(f"xray statsquery failed: {stderr}")
    return result.stdout


def read_stats_source(args: argparse.Namespace, config: AppConfig) -> str:
    """读取统计来源；测试或离线导入时可用 --input-file 跳过真实 Xray 调用。"""

    input_file = getattr(args, "input_file", None)
    if input_file:
        return Path(input_file).read_text(encoding="utf-8")
    return run_statsquery(config, reset=not getattr(args, "no_reset", False))


def parse_json_stats(output: str) -> List[ParsedStat]:
    """尝试按 JSON 解析 Xray 输出，适用于当前 StatsService 的结构化输出。"""

    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return []

    stats: List[ParsedStat] = []

    def walk(value: Any) -> None:
        if isinstance(value, dict):
            if "name" in value and "value" in value:
                try:
                    stats.append(ParsedStat(str(value["name"]), int(float(value["value"]))))
                except (TypeError, ValueError):
                    logging.warning("Skip stat with invalid value")
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(payload)
    return stats


def parse_text_stats(output: str) -> List[ParsedStat]:
    """按文本行解析 Xray 输出，适用于 JSON 解析失败时的兼容路径。"""

    stats: List[ParsedStat] = []
    current_name: Optional[str] = None
    name_re = re.compile(r'"name"\s*:\s*"([^"]+)"')
    value_re = re.compile(r'"value"\s*:\s*"?([0-9]+(?:\.[0-9]+)?)"?')

    for line in output.splitlines():
        name_match = name_re.search(line)
        if name_match:
            current_name = name_match.group(1)

        value_match = value_re.search(line)
        if value_match and current_name is not None:
            stats.append(ParsedStat(current_name, int(float(value_match.group(1)))))
            current_name = None
    return stats


def parse_stats(output: str) -> List[ParsedStat]:
    """解析 Xray StatsService 输出，优先 JSON，失败后回退到文本解析。"""

    stats = parse_json_stats(output)
    if stats:
        return stats
    return parse_text_stats(output)


def stats_to_counters(stats: Iterable[ParsedStat]) -> Dict[CounterKey, int]:
    """将 Xray 原始统计转换为计数字典，适用于入库和实时速率计算。"""

    counters: Dict[CounterKey, int] = {}
    for stat in stats:
        parts = stat.name.split(">>>")
        if len(parts) < 4 or parts[2] != "traffic":
            continue

        scope = parts[0]
        item_name = parts[1]
        direction_token = parts[3]
        if scope not in VALID_SCOPES:
            continue
        if direction_token == "uplink":
            direction = "up"
        elif direction_token == "downlink":
            direction = "down"
        else:
            continue
        if stat.value < 0:
            logging.warning("Skip stat with negative value")
            continue

        key = (scope, item_name, direction)
        counters[key] = counters.get(key, 0) + stat.value
    return counters


def normalize_stats(
    stats: Iterable[ParsedStat],
    period: str,
    start_ts: int,
    end_ts: int,
    tzinfo: timezone,
) -> List[TrafficRecord]:
    """将 Xray 原始统计名转换为 scope/name/direction 结构，适用于统一入库。"""

    counters = stats_to_counters(stats)
    start_time = isoformat(start_ts, tzinfo)
    end_time = isoformat(end_ts, tzinfo)
    records = [
        TrafficRecord(
            period=period,
            start_ts=start_ts,
            end_ts=end_ts,
            start_time=start_time,
            end_time=end_time,
            scope=scope,
            name=name,
            direction=direction,
            bytes_value=bytes_value,
        )
        for (scope, name, direction), bytes_value in sorted(counters.items())
    ]
    return records


def insert_records(connection: sqlite3.Connection, records: Sequence[TrafficRecord]) -> None:
    """批量写入流量记录，适用于 hourly 和 daily 快照持久化。"""

    created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    connection.executemany(
        """
        INSERT INTO traffic_records (
            period, start_ts, end_ts, start_time, end_time,
            scope, name, direction, bytes, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(period, start_ts, scope, name, direction) DO UPDATE SET
            end_ts = excluded.end_ts,
            start_time = excluded.start_time,
            end_time = excluded.end_time,
            bytes = excluded.bytes,
            created_at = excluded.created_at
        """,
        [
            (
                record.period,
                record.start_ts,
                record.end_ts,
                record.start_time,
                record.end_time,
                record.scope,
                record.name,
                record.direction,
                record.bytes_value,
                created_at,
            )
            for record in records
        ],
    )


def cleanup_old_records(connection: sqlite3.Connection, config: AppConfig) -> int:
    """删除超过保留期的记录，适用于每次采集或聚合后执行。"""

    cutoff_ts = now_ts() - config.retention_days * 86400
    cursor = connection.execute("DELETE FROM traffic_records WHERE start_ts < ?", (cutoff_ts,))
    return int(cursor.rowcount if cursor.rowcount is not None else 0)


def command_hourly(args: argparse.Namespace, config: AppConfig) -> int:
    """执行小时采集，适用于 systemd timer 每小时调用。"""

    tzinfo = get_timezone(config)
    raw_output = read_stats_source(args, config)
    parsed_stats = parse_stats(raw_output)
    end_ts = floor_to_hour(now_ts(), tzinfo)
    if getattr(args, "at", None):
        end_dt = datetime.fromisoformat(args.at)
        if end_dt.tzinfo is None:
            end_dt = end_dt.replace(tzinfo=tzinfo)
        end_ts = floor_to_hour(int(end_dt.timestamp()), tzinfo)

    with database_lock(config.db_path):
        with open_database(config.db_path) as connection:
            last_end = read_metadata(connection, "last_hourly_end_ts")
            start_ts = int(last_end) if last_end else end_ts - 3600
            if start_ts >= end_ts:
                start_ts = end_ts - 3600

            records = normalize_stats(parsed_stats, "hourly", start_ts, end_ts, tzinfo)
            insert_records(connection, records)
            write_metadata(connection, "last_hourly_end_ts", str(end_ts))
            removed = cleanup_old_records(connection, config)
            connection.commit()

    logging.info("Hourly snapshot saved: records=%s removed=%s", len(records), removed)
    return 0


def command_daily(args: argparse.Namespace, config: AppConfig) -> int:
    """执行每日聚合，适用于每天凌晨从 hourly 记录生成 daily 记录。"""

    tzinfo = get_timezone(config)
    target_day = parse_day(args.date) if args.date else datetime.now(tzinfo).date() - timedelta(days=1)
    start_ts, end_ts = date_range_for_day(target_day, tzinfo)
    start_time = isoformat(start_ts, tzinfo)
    end_time = isoformat(end_ts, tzinfo)

    with database_lock(config.db_path):
        with open_database(config.db_path) as connection:
            rows = connection.execute(
                """
                SELECT scope, name, direction, SUM(bytes) AS bytes
                FROM traffic_records
                WHERE period = 'hourly'
                  AND start_ts >= ?
                  AND start_ts < ?
                GROUP BY scope, name, direction
                ORDER BY scope, name, direction
                """,
                (start_ts, end_ts),
            ).fetchall()

            connection.execute(
                "DELETE FROM traffic_records WHERE period = 'daily' AND start_ts = ?",
                (start_ts,),
            )
            records = [
                TrafficRecord(
                    period="daily",
                    start_ts=start_ts,
                    end_ts=end_ts,
                    start_time=start_time,
                    end_time=end_time,
                    scope=str(row["scope"]),
                    name=str(row["name"]),
                    direction=str(row["direction"]),
                    bytes_value=int(row["bytes"] or 0),
                )
                for row in rows
            ]
            insert_records(connection, records)
            removed = cleanup_old_records(connection, config)
            connection.commit()

    logging.info("Daily snapshot saved: date=%s records=%s removed=%s", target_day.isoformat(), len(records), removed)
    return 0


def read_current_counters(config: AppConfig) -> Dict[CounterKey, int]:
    """读取当前 Xray 统计计数且不 reset，适用于实时速率采样。"""

    raw_output = run_statsquery(config, reset=False)
    return stats_to_counters(parse_stats(raw_output))


def calculate_current_totals(
    counters: Dict[CounterKey, int],
    scope_filter: Optional[str],
    name_filter: Optional[str],
) -> List[Tuple[str, str, int, int, int]]:
    """将当前累计计数按 scope/name 汇总，适用于 current 子命令输出。"""

    grouped: Dict[Tuple[str, str], Dict[str, int]] = {}
    for scope, name, direction in sorted(counters):
        if scope_filter and scope != scope_filter:
            continue
        if name_filter and name != name_filter:
            continue

        item = grouped.setdefault((scope, name), {"up": 0, "down": 0})
        item[direction] = item.get(direction, 0) + counters[(scope, name, direction)]

    rows = []
    for (scope, name), values in grouped.items():
        up_bytes = values.get("up", 0)
        down_bytes = values.get("down", 0)
        total_bytes = up_bytes + down_bytes
        if total_bytes <= 0:
            continue
        rows.append((scope, name, up_bytes, down_bytes, total_bytes))
    rows.sort(key=lambda row: (-row[4], row[0], row[1]))
    return rows


def write_current_table(rows: Sequence[Tuple[str, str, int, int, int]], output: TextIO) -> None:
    """输出当前累计流量表格，适用于 current 子命令的人类可读结果。"""

    output.write(f"{'Scope':<10} {'Name':<30} {'Up':>12} {'Down':>12} {'Total':>12}\n")
    output.write(f"{'-' * 10} {'-' * 30} {'-' * 12} {'-' * 12} {'-' * 12}\n")
    for scope, name, up_bytes, down_bytes, total_bytes in rows:
        output.write(
            f"{scope:<10} {name:<30} "
            f"{format_bytes(up_bytes):>12} {format_bytes(down_bytes):>12} {format_bytes(total_bytes):>12}\n"
        )


def command_current(args: argparse.Namespace, config: AppConfig) -> int:
    """查询上次 reset 后的当前累计流量，适用于不落库的即时累计查看。"""

    counters = read_current_counters(config)
    rows = calculate_current_totals(counters, args.scope, args.name)
    if rows:
        write_current_table(rows, sys.stdout)
    else:
        sys.stdout.write("No current traffic counters found\n")
    return 0


def calculate_realtime_rates(
    before: Dict[CounterKey, int],
    after: Dict[CounterKey, int],
    elapsed: float,
    scope_filter: Optional[str],
    name_filter: Optional[str],
) -> List[Tuple[str, str, float, float, float]]:
    """根据两次累计计数计算实时速率，适用于 realtime 子命令输出。"""

    if elapsed <= 0:
        raise CliError("elapsed time must be greater than 0")

    grouped: Dict[Tuple[str, str], Dict[str, float]] = {}
    for scope, name, direction in sorted(set(before) | set(after)):
        if scope_filter and scope != scope_filter:
            continue
        if name_filter and name != name_filter:
            continue

        delta = after.get((scope, name, direction), 0) - before.get((scope, name, direction), 0)
        if delta < 0:
            # 采样期间如果 hourly timer reset 了 Xray 计数，避免展示负速率。
            delta = 0

        item = grouped.setdefault((scope, name), {"up": 0.0, "down": 0.0})
        item[direction] = item.get(direction, 0.0) + delta / elapsed

    rows = []
    for (scope, name), values in grouped.items():
        up_rate = values.get("up", 0.0)
        down_rate = values.get("down", 0.0)
        total_rate = up_rate + down_rate
        if total_rate <= 0:
            continue
        rows.append((scope, name, up_rate, down_rate, total_rate))
    rows.sort(key=lambda row: (-row[4], row[0], row[1]))
    return rows


def write_realtime_table(rows: Sequence[Tuple[str, str, float, float, float]], output: TextIO) -> None:
    """输出实时速率表格，适用于 realtime 子命令的人类可读结果。"""

    output.write(f"{'Scope':<10} {'Name':<30} {'Up/s':>12} {'Down/s':>12} {'Total/s':>12}\n")
    output.write(f"{'-' * 10} {'-' * 30} {'-' * 12} {'-' * 12} {'-' * 12}\n")
    for scope, name, up_rate, down_rate, total_rate in rows:
        output.write(
            f"{scope:<10} {name:<30} "
            f"{format_rate(up_rate):>12} {format_rate(down_rate):>12} {format_rate(total_rate):>12}\n"
        )


def command_realtime(args: argparse.Namespace, config: AppConfig) -> int:
    """采样并输出实时流量速率，适用于不落库的即时观测。"""

    if args.interval <= 0:
        raise CliError("--interval must be greater than 0")
    if args.count <= 0:
        raise CliError("--count must be greater than 0")

    before = read_current_counters(config)
    for index in range(args.count):
        start_monotonic = time_module.monotonic()
        time_module.sleep(args.interval)
        after = read_current_counters(config)
        elapsed = time_module.monotonic() - start_monotonic
        rows = calculate_realtime_rates(before, after, elapsed, args.scope, args.name)

        if args.count > 1:
            sampled_at = datetime.now(get_timezone(config)).replace(microsecond=0).isoformat()
            sys.stdout.write(f"Sample {index + 1}/{args.count} at {sampled_at}, elapsed={elapsed:.3f}s\n")
        if rows:
            write_realtime_table(rows, sys.stdout)
        else:
            sys.stdout.write("No active traffic\n")
        if index + 1 < args.count:
            sys.stdout.write("\n")
        before = after
    return 0


def format_bytes(value: int) -> str:
    """将字节数格式化为 IEC 单位，适用于终端表格展示。"""

    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    size = float(value)
    for unit in units:
        if abs(size) < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)}B"
            return f"{size:.2f}{unit}"
        size /= 1024.0
    return f"{value}B"


def format_rate(value: float) -> str:
    """将每秒速率格式化为 IEC 单位，适用于 realtime 子命令展示。"""

    if value < 1:
        return f"{value:.2f}B/s"
    return f"{format_bytes(int(round(value)))}/s"


def write_summary_table(rows: Sequence[sqlite3.Row], output: TextIO) -> None:
    """输出汇总表格，适用于 summary 子命令的人类可读结果。"""

    output.write(f"{'Scope':<10} {'Name':<30} {'Up':>12} {'Down':>12} {'Total':>12}\n")
    output.write(f"{'-' * 10} {'-' * 30} {'-' * 12} {'-' * 12} {'-' * 12}\n")
    for row in rows:
        up_bytes = int(row["up_bytes"] or 0)
        down_bytes = int(row["down_bytes"] or 0)
        total_bytes = int(row["total_bytes"] or 0)
        output.write(
            f"{row['scope']:<10} {row['name']:<30} "
            f"{format_bytes(up_bytes):>12} {format_bytes(down_bytes):>12} {format_bytes(total_bytes):>12}\n"
        )


def format_period_label(period: str, start_ts: int, tzinfo: timezone) -> str:
    """格式化快照时间标签，适用于 show 子命令按小时或天展示。"""

    start_dt = datetime.fromtimestamp(start_ts, tzinfo)
    if period == "hourly":
        return start_dt.strftime("%Y-%m-%d %H:00")
    return start_dt.strftime("%Y-%m-%d")


def resolve_show_time_range(args: argparse.Namespace, tzinfo: timezone) -> Tuple[int, int]:
    """解析 show 子命令的时间范围，默认 hourly 查 1 天、daily 查 7 天。"""

    if args.date:
        return date_range_for_day(parse_day(args.date), tzinfo)

    days = args.days
    if days is None:
        days = 1 if args.period == "hourly" else 7
    if days <= 0:
        raise CliError("--days must be greater than 0")

    end_ts = now_ts()
    start_ts = end_ts - days * 86400
    return start_ts, end_ts


def write_show_table(period: str, rows: Sequence[sqlite3.Row], tzinfo: timezone, output: TextIO) -> None:
    """输出按小时或天聚合后的流量表格，适用于日常查看已存储流量。"""

    label = "Hour" if period == "hourly" else "Day"
    separator = f"{'-' * 16} {'-' * 10} {'-' * 30} {'-' * 12} {'-' * 12} {'-' * 12}"
    output.write(f"{label:<16} {'Scope':<10} {'Name':<30} {'Up':>12} {'Down':>12} {'Total':>12}\n")
    output.write(f"{separator}\n")
    last_period_label = ""
    for row in rows:
        up_bytes = int(row["up_bytes"] or 0)
        down_bytes = int(row["down_bytes"] or 0)
        total_bytes = int(row["total_bytes"] or 0)
        current_period_label = format_period_label(period, int(row["start_ts"]), tzinfo)
        if last_period_label and current_period_label != last_period_label:
            output.write(f"{separator}\n")
        output.write(
            f"{current_period_label:<16} "
            f"{row['scope']:<10} {row['name']:<30} "
            f"{format_bytes(up_bytes):>12} {format_bytes(down_bytes):>12} {format_bytes(total_bytes):>12}\n"
        )
        last_period_label = current_period_label


def command_show(args: argparse.Namespace, config: AppConfig) -> int:
    """按小时或天查看已存储流量，适用于替代 query 的日常阅读场景。"""

    tzinfo = get_timezone(config)
    start_ts, end_ts = resolve_show_time_range(args, tzinfo)
    filters = ["period = ?", "start_ts >= ?", "start_ts < ?"]
    params: List[Any] = [args.period, start_ts, end_ts]

    if args.scope:
        filters.append("scope = ?")
        params.append(args.scope)
    if args.name:
        filters.append("name = ?")
        params.append(args.name)

    params.append(args.limit)
    query = f"""
        SELECT
            start_ts,
            scope,
            name,
            SUM(CASE WHEN direction = 'up' THEN bytes ELSE 0 END) AS up_bytes,
            SUM(CASE WHEN direction = 'down' THEN bytes ELSE 0 END) AS down_bytes,
            SUM(bytes) AS total_bytes
        FROM traffic_records
        WHERE {' AND '.join(filters)}
        GROUP BY start_ts, scope, name
        ORDER BY start_ts DESC, total_bytes DESC, scope ASC, name ASC
        LIMIT ?
    """

    with open_database(config.db_path) as connection:
        rows = connection.execute(query, params).fetchall()

    if not rows:
        sys.stdout.write("No records found\n")
        return 0
    write_show_table(args.period, rows, tzinfo, sys.stdout)
    return 0


def command_summary(args: argparse.Namespace, config: AppConfig) -> int:
    """按条件输出流量汇总，适用于按用户、入口或出口做统计。"""

    tzinfo = get_timezone(config)
    start_ts, end_ts = resolve_time_range(args, tzinfo)
    filters = ["period = ?", "start_ts >= ?", "start_ts < ?"]
    params: List[Any] = [args.period, start_ts, end_ts]

    if args.scope:
        filters.append("scope = ?")
        params.append(args.scope)
    if args.name:
        filters.append("name = ?")
        params.append(args.name)

    query = f"""
        SELECT
            scope,
            name,
            SUM(CASE WHEN direction = 'up' THEN bytes ELSE 0 END) AS up_bytes,
            SUM(CASE WHEN direction = 'down' THEN bytes ELSE 0 END) AS down_bytes,
            SUM(bytes) AS total_bytes
        FROM traffic_records
        WHERE {' AND '.join(filters)}
        GROUP BY scope, name
        ORDER BY total_bytes DESC, scope ASC, name ASC
    """

    with open_database(config.db_path) as connection:
        rows = connection.execute(query, params).fetchall()

    if not rows:
        sys.stdout.write("No records found\n")
        return 0
    write_summary_table(rows, sys.stdout)
    return 0


def command_query(args: argparse.Namespace, config: AppConfig) -> int:
    """输出明细记录，适用于排查单个时间范围内的原始快照。"""

    tzinfo = get_timezone(config)
    start_ts, end_ts = resolve_time_range(args, tzinfo)
    filters = ["period = ?", "start_ts >= ?", "start_ts < ?"]
    params: List[Any] = [args.period, start_ts, end_ts]

    if args.scope:
        filters.append("scope = ?")
        params.append(args.scope)
    if args.name:
        filters.append("name = ?")
        params.append(args.name)

    params.append(args.limit)
    query = f"""
        SELECT period, start_time, end_time, scope, name, direction, bytes
        FROM traffic_records
        WHERE {' AND '.join(filters)}
        ORDER BY start_ts DESC, scope ASC, name ASC, direction ASC
        LIMIT ?
    """

    with open_database(config.db_path) as connection:
        rows = connection.execute(query, params).fetchall()

    if not rows:
        sys.stdout.write("No records found\n")
        return 0

    sys.stdout.write(
        f"{'Period':<8} {'Start':<25} {'End':<25} {'Scope':<10} "
        f"{'Name':<30} {'Dir':<5} {'Bytes':>14}\n"
    )
    for row in rows:
        sys.stdout.write(
            f"{row['period']:<8} {row['start_time']:<25} {row['end_time']:<25} "
            f"{row['scope']:<10} {row['name']:<30} {row['direction']:<5} {int(row['bytes']):>14}\n"
        )
    return 0


def command_export(args: argparse.Namespace, config: AppConfig) -> int:
    """导出 CSV 明细，适用于报表系统或人工二次分析。"""

    tzinfo = get_timezone(config)
    start_ts, end_ts = resolve_time_range(args, tzinfo)
    filters = ["period = ?", "start_ts >= ?", "start_ts < ?"]
    params: List[Any] = [args.period, start_ts, end_ts]

    if args.scope:
        filters.append("scope = ?")
        params.append(args.scope)
    if args.name:
        filters.append("name = ?")
        params.append(args.name)

    query = f"""
        SELECT period, start_time, end_time, scope, name, direction, bytes, created_at
        FROM traffic_records
        WHERE {' AND '.join(filters)}
        ORDER BY start_ts ASC, scope ASC, name ASC, direction ASC
    """

    with open_database(config.db_path) as connection:
        rows = connection.execute(query, params).fetchall()

    output_file: Optional[TextIO] = None
    try:
        output: TextIO
        if args.output:
            output_file = Path(args.output).open("w", encoding="utf-8", newline="")
            output = output_file
        else:
            output = sys.stdout

        writer = csv.writer(output)
        writer.writerow(["period", "start_time", "end_time", "scope", "name", "direction", "bytes", "created_at"])
        for row in rows:
            writer.writerow(
                [
                    row["period"],
                    row["start_time"],
                    row["end_time"],
                    row["scope"],
                    row["name"],
                    row["direction"],
                    row["bytes"],
                    row["created_at"],
                ]
            )
    finally:
        if output_file is not None:
            output_file.close()

    logging.info("CSV exported: records=%s", len(rows))
    return 0


def command_cleanup(args: argparse.Namespace, config: AppConfig) -> int:
    """手工清理过期数据，适用于需要立即执行保留期策略的场景。"""

    with database_lock(config.db_path):
        with open_database(config.db_path) as connection:
            removed = cleanup_old_records(connection, config)
            connection.commit()
    logging.info("Cleanup finished: removed=%s", removed)
    return 0


def command_health(args: argparse.Namespace, config: AppConfig) -> int:
    """检查本工具运行环境，适用于安装或更新后快速验证。"""

    del args
    with open_database(config.db_path) as connection:
        record_count = connection.execute("SELECT COUNT(*) AS count FROM traffic_records").fetchone()["count"]
    sys.stdout.write(f"xray-traffic {VERSION}\n")
    sys.stdout.write(f"server={config.server}\n")
    sys.stdout.write(f"xray_bin={config.xray_bin}\n")
    sys.stdout.write(f"db={config.db_path}\n")
    sys.stdout.write(f"records={record_count}\n")
    return 0


def add_common_query_options(parser: argparse.ArgumentParser) -> None:
    """为查询类子命令添加通用过滤参数。"""

    parser.add_argument("--period", choices=("hourly", "daily"), default="daily", help="统计周期，默认 daily")
    parser.add_argument("--scope", choices=VALID_SCOPES, help="过滤统计范围")
    parser.add_argument("--name", help="过滤用户名、inbound tag 或 outbound tag")
    parser.add_argument("--date", help="查询单日，格式 YYYY-MM-DD")
    parser.add_argument("--from", dest="from_date", help="查询起始日期，格式 YYYY-MM-DD，包含当天")
    parser.add_argument("--to", dest="to_date", help="查询结束日期，格式 YYYY-MM-DD，不包含当天")
    parser.add_argument("--days", type=int, default=7, help="未指定日期范围时查询最近 N 天，默认 7")


def build_parser() -> argparse.ArgumentParser:
    """构建命令行解析器，适用于所有子命令入口。"""

    parser = argparse.ArgumentParser(description="Xray traffic snapshot collector")
    parser.add_argument("--config", help=f"配置文件路径，默认 {DEFAULT_CONFIG_FILE}")
    parser.add_argument("--server", help=f"Xray API server，默认 {DEFAULT_SERVER}")
    parser.add_argument("--xray-bin", help=f"Xray 二进制路径，默认 {DEFAULT_XRAY_BIN}")
    parser.add_argument("--db", help=f"SQLite 数据库路径，默认 {DEFAULT_DB_PATH}")
    parser.add_argument("--retention-days", type=int, help=f"保留天数，默认 {DEFAULT_RETENTION_DAYS}")
    parser.add_argument("--timezone", help="统计使用的 IANA 时区，例如 Asia/Shanghai；默认使用系统本地时区")
    parser.add_argument("--timeout", type=int, help=f"调用 xray 的超时时间秒数，默认 {DEFAULT_TIMEOUT_SECONDS}")
    parser.add_argument("--log-level", default="INFO", help="日志级别，默认 INFO")
    parser.add_argument("--version", action="version", version=f"xray-traffic {VERSION}")

    subparsers = parser.add_subparsers(dest="command", required=True)

    hourly_parser = subparsers.add_parser("hourly", help="采集小时增量快照")
    hourly_parser.add_argument("--input-file", help="从文件读取 statsquery 输出，主要用于测试或离线导入")
    hourly_parser.add_argument("--no-reset", action="store_true", help="调用 statsquery 时不重置 Xray 计数")
    hourly_parser.add_argument("--at", help=argparse.SUPPRESS)
    hourly_parser.set_defaults(func=command_hourly)

    daily_parser = subparsers.add_parser("daily", help="聚合每日快照")
    daily_parser.add_argument("--date", help="聚合指定日期，格式 YYYY-MM-DD；默认昨天")
    daily_parser.set_defaults(func=command_daily)

    current_parser = subparsers.add_parser("current", help="查看上次 reset 后的当前累计流量")
    current_parser.add_argument("--scope", choices=VALID_SCOPES, help="过滤统计范围")
    current_parser.add_argument("--name", help="过滤用户名、inbound tag 或 outbound tag")
    current_parser.set_defaults(func=command_current)

    realtime_parser = subparsers.add_parser("realtime", help="查看实时流量速率")
    realtime_parser.add_argument("--interval", type=float, default=1.0, help="采样间隔秒数，默认 1")
    realtime_parser.add_argument("--count", type=int, default=1, help="采样次数，默认 1")
    realtime_parser.add_argument("--scope", choices=VALID_SCOPES, help="过滤统计范围")
    realtime_parser.add_argument("--name", help="过滤用户名、inbound tag 或 outbound tag")
    realtime_parser.set_defaults(func=command_realtime)

    show_parser = subparsers.add_parser("show", help="按小时或天查看已存储流量")
    show_parser.add_argument("period", nargs="?", choices=("hourly", "daily"), default="hourly", help="查看周期，默认 hourly")
    show_parser.add_argument("--scope", choices=VALID_SCOPES, help="过滤统计范围")
    show_parser.add_argument("--name", help="过滤用户名、inbound tag 或 outbound tag")
    show_parser.add_argument("--date", help="查看单日，格式 YYYY-MM-DD")
    show_parser.add_argument("--days", type=int, help="查看最近 N 天；hourly 默认 1，daily 默认 7")
    show_parser.add_argument("--limit", type=int, default=500, help="最多输出行数，默认 500")
    show_parser.set_defaults(func=command_show)

    summary_parser = subparsers.add_parser("summary", help="按条件汇总流量")
    add_common_query_options(summary_parser)
    summary_parser.set_defaults(func=command_summary)

    query_parser = subparsers.add_parser("query", help="查询明细记录")
    add_common_query_options(query_parser)
    query_parser.add_argument("--limit", type=int, default=100, help="最多输出记录数，默认 100")
    query_parser.set_defaults(func=command_query)

    export_parser = subparsers.add_parser("export", help="导出 CSV 明细")
    add_common_query_options(export_parser)
    export_parser.add_argument("--output", help="CSV 输出文件，默认输出到 stdout")
    export_parser.set_defaults(func=command_export)

    cleanup_parser = subparsers.add_parser("cleanup", help="清理超过保留期的数据")
    cleanup_parser.set_defaults(func=command_cleanup)

    health_parser = subparsers.add_parser("health", help="检查运行环境和数据库")
    health_parser.set_defaults(func=command_health)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    """命令行主入口，负责解析参数、加载配置并分发子命令。"""

    parser = build_parser()
    args = parser.parse_args(argv)
    configure_logging(args.log_level)

    try:
        config = resolve_config(args)
        return int(args.func(args, config))
    except CliError as exc:
        logging.error("%s", exc)
        return 1
    except sqlite3.Error as exc:
        logging.error("sqlite error: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
