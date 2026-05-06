#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import ipaddress
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple


WIREGUARD_ROOT = Path(os.environ.get("WGTOOL_ROOT", "/etc/wireguard"))
CONFIG_NAME = "wgtool.json"
DB_NAME = "wgtool.db"
OLD_SETTINGS_NAME = "settings"
OLD_DB_NAME = "db"
STATE_FORMAT = "wgtool-state-v1"
DEFAULT_INTERFACE = "wg0"
DEFAULT_SUBNET = "10.10.10"
DEFAULT_ALLOWED_IPS = ["0.0.0.0/0", "::/0"]
DEFAULT_MTU = 1420
DEFAULT_TABLE_NO = 10
SERVER_PRIVATE_KEY_NAME = "server-privatekey"
SERVER_PUBLIC_KEY_NAME = "server-publickey"
INSTALL_PACKAGES = (
    ("wireguard", ("wg", "wg-quick")),
    ("qrencode", ("qrencode",)),
    ("iptables", ("iptables",)),
)
CLIENT_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
INTERFACE_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")

EXIT_REQUIRE_COMMAND = 100
EXIT_REQUIRE_ROOT = 101
EXIT_REQUIRE_LINUX = 102
EXIT_CONFIG = 103
EXIT_DB = 104
EXIT_COMMAND = 105


class ToolError(Exception):
    def __init__(self, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


COLORS = {
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "cyan": "\033[36m",
    "bold": "\033[1m",
    "reset": "\033[0m",
}


def use_color(stream: object) -> bool:
    return (
        hasattr(stream, "isatty")
        and stream.isatty()
        and os.environ.get("NO_COLOR") is None
        and os.environ.get("TERM") != "dumb"
    )


def color_text(text: str, *styles: str, stream: object = sys.stdout) -> str:
    if not use_color(stream):
        return text
    prefix = "".join(COLORS[style] for style in styles)
    return f"{prefix}{text}{COLORS['reset']}"


def emit(message: str = "") -> None:
    sys.stdout.write(f"{message}\n")


def emit_err(message: str) -> None:
    prefix = color_text("[ERR]", "red", "bold", stream=sys.stderr)
    sys.stderr.write(f"{prefix} {message}\n")


def emit_info(message: str) -> None:
    emit(f"{color_text('[INFO]', 'blue', 'bold')} {message}")


def emit_success(message: str) -> None:
    emit(f"{color_text('[OK]', 'green', 'bold')} {message}")


def emit_warning(message: str) -> None:
    emit(f"{color_text('[WARN]', 'yellow', 'bold')} {message}")


def emit_dry_run(message: str) -> None:
    emit(f"{color_text('[DRY]', 'cyan', 'bold')} {message}")


def table_header(text: str) -> str:
    return color_text(text, "bold")


def require_linux() -> None:
    if sys.platform != "linux":
        raise ToolError("Linux is required.", EXIT_REQUIRE_LINUX)


def require_root() -> None:
    if os.geteuid() != 0:
        raise ToolError("Root privilege is required.", EXIT_REQUIRE_ROOT)


def chmod_private(path: Path) -> None:
    path.chmod(0o600)


def write_text_atomic(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), delete=False) as temp_file:
            temp_path = Path(temp_file.name)
            temp_file.write(content)
        temp_path.chmod(mode)
        temp_path.replace(path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def write_bytes_atomic(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile("wb", dir=str(path.parent), delete=False) as temp_file:
            temp_path = Path(temp_file.name)
            temp_file.write(content)
        temp_path.chmod(mode)
        temp_path.replace(path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def read_text_stripped(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def check_client_name(name: str) -> str:
    if not CLIENT_NAME_PATTERN.fullmatch(name):
        raise ToolError("Client name must match [A-Za-z0-9_.-] and be 1-64 chars.", EXIT_CONFIG)
    return name


def check_host_number(host_number: int) -> int:
    if host_number < 2 or host_number > 254:
        raise ToolError("Host number must be in range 2-254.", EXIT_CONFIG)
    return host_number


def parse_host_number(value: str) -> int:
    try:
        host_number = int(value, 10)
    except ValueError as exc:
        raise ToolError("Host number must be an integer.", EXIT_CONFIG) from exc
    return check_host_number(host_number)


def parse_port(value: str) -> int:
    try:
        port = int(value, 10)
    except ValueError as exc:
        raise ToolError("Port must be an integer.", EXIT_CONFIG) from exc
    if port < 1 or port > 65535:
        raise ToolError("Port must be in range 1-65535.", EXIT_CONFIG)
    return port


def split_allowed_ips(raw_values: Sequence[str]) -> List[str]:
    values: List[str] = []
    for raw_value in raw_values:
        for item in raw_value.split(","):
            value = item.strip()
            if value:
                values.append(value)
    return values or list(DEFAULT_ALLOWED_IPS)


def validate_allowed_ips(values: Sequence[str]) -> List[str]:
    result: List[str] = []
    for value in values:
        try:
            result.append(str(ipaddress.ip_network(value, strict=False)))
        except ValueError as exc:
            raise ToolError(f"Invalid allowed IP network: {value}", EXIT_CONFIG) from exc
    return result


@dataclasses.dataclass(frozen=True)
class Config:
    interface: str = DEFAULT_INTERFACE
    subnet: str = DEFAULT_SUBNET
    server_ip: str = f"{DEFAULT_SUBNET}.1/24"
    server_endpoint: str = ""
    server_port: int = 51820
    client_gateway: str = f"{DEFAULT_SUBNET}.2"
    client_dns: str = "1.1.1.1"
    allowed_ips: Tuple[str, ...] = tuple(DEFAULT_ALLOWED_IPS)
    mtu: int = DEFAULT_MTU
    table_no: int = DEFAULT_TABLE_NO
    server_private_key: str = SERVER_PRIVATE_KEY_NAME
    server_public_key: str = SERVER_PUBLIC_KEY_NAME

    @classmethod
    def from_dict(cls, payload: dict) -> "Config":
        allowed_ips = payload.get("allowed_ips", DEFAULT_ALLOWED_IPS)
        if isinstance(allowed_ips, str):
            allowed_ips = split_allowed_ips([allowed_ips])
        subnet = str(payload.get("subnet", DEFAULT_SUBNET))
        config = cls(
            interface=str(payload.get("interface", DEFAULT_INTERFACE)),
            subnet=subnet,
            server_ip=str(payload.get("server_ip", f"{subnet}.1/24")),
            server_endpoint=str(payload.get("server_endpoint", "")),
            server_port=int(payload.get("server_port", 51820)),
            client_gateway=str(payload.get("client_gateway", f"{subnet}.2")),
            client_dns=str(payload.get("client_dns", "1.1.1.1")),
            allowed_ips=tuple(validate_allowed_ips([str(item) for item in allowed_ips])),
            mtu=int(payload.get("mtu", DEFAULT_MTU)),
            table_no=int(payload.get("table_no", DEFAULT_TABLE_NO)),
            server_private_key=str(payload.get("server_private_key", SERVER_PRIVATE_KEY_NAME)),
            server_public_key=str(payload.get("server_public_key", SERVER_PUBLIC_KEY_NAME)),
        )
        config.validate()
        return config

    def to_dict(self) -> dict:
        return {
            "interface": self.interface,
            "subnet": self.subnet,
            "server_ip": self.server_ip,
            "server_endpoint": self.server_endpoint,
            "server_port": self.server_port,
            "client_gateway": self.client_gateway,
            "client_dns": self.client_dns,
            "allowed_ips": list(self.allowed_ips),
            "mtu": self.mtu,
            "table_no": self.table_no,
            "server_private_key": self.server_private_key,
            "server_public_key": self.server_public_key,
        }

    def validate(self) -> None:
        if not INTERFACE_PATTERN.fullmatch(self.interface):
            raise ToolError("Invalid interface name.", EXIT_CONFIG)
        try:
            network = ipaddress.ip_network(f"{self.subnet}.0/24", strict=False)
        except ValueError as exc:
            raise ToolError("Subnet must be a valid IPv4 prefix like 10.10.10.", EXIT_CONFIG) from exc
        try:
            server_interface = ipaddress.ip_interface(self.server_ip)
        except ValueError as exc:
            raise ToolError("server_ip must be a valid interface address like 10.10.10.1/24.", EXIT_CONFIG) from exc
        if server_interface.ip.version != 4:
            raise ToolError("server_ip must be IPv4.", EXIT_CONFIG)
        if server_interface.ip not in network:
            raise ToolError("server_ip must be in subnet.", EXIT_CONFIG)
        try:
            gateway = ipaddress.ip_address(self.client_gateway)
        except ValueError as exc:
            raise ToolError("client_gateway must be a valid IPv4 address.", EXIT_CONFIG) from exc
        if gateway.version != 4:
            raise ToolError("client_gateway must be IPv4.", EXIT_CONFIG)
        if gateway == server_interface.ip:
            raise ToolError("client_gateway must not equal server_ip.", EXIT_CONFIG)
        if self.server_port < 1 or self.server_port > 65535:
            raise ToolError("server_port must be in range 1-65535.", EXIT_CONFIG)
        if self.mtu < 576 or self.mtu > 9000:
            raise ToolError("mtu must be in range 576-9000.", EXIT_CONFIG)
        if self.table_no < 1:
            raise ToolError("table_no must be a positive integer.", EXIT_CONFIG)

    def client_ip(self, host_number: int, cidr: bool = False) -> str:
        check_host_number(host_number)
        suffix = "/24" if cidr else ""
        return f"{self.subnet}.{host_number}{suffix}"

    def peer_allowed_ip(self, host_number: int) -> str:
        check_host_number(host_number)
        return f"{self.subnet}.{host_number}/32"


@dataclasses.dataclass(frozen=True)
class Paths:
    root: Path

    @property
    def config(self) -> Path:
        return self.root / CONFIG_NAME

    @property
    def db(self) -> Path:
        return self.root / DB_NAME

    @property
    def old_settings(self) -> Path:
        return self.root / OLD_SETTINGS_NAME

    @property
    def old_db(self) -> Path:
        return self.root / OLD_DB_NAME

    def server_private_key(self, config: Config) -> Path:
        return self.root / config.server_private_key

    def server_public_key(self, config: Config) -> Path:
        return self.root / config.server_public_key

    def server_config(self, config: Config) -> Path:
        return self.root / f"{config.interface}.conf"


class Runner:
    def __init__(self, dry_run: bool = False) -> None:
        self.dry_run = dry_run

    def require(self, *commands: str) -> None:
        missing = [command for command in commands if shutil.which(command) is None]
        if missing:
            raise ToolError(f"Missing required command: {', '.join(missing)}", EXIT_REQUIRE_COMMAND)

    def succeeds(self, *args: str) -> bool:
        if self.dry_run:
            emit_dry_run(" ".join(args))
            return False
        try:
            completed = subprocess.run(list(args), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            return False
        return completed.returncode == 0

    def run(self, *args: str, input_text: Optional[str] = None, check: bool = True) -> subprocess.CompletedProcess:
        if self.dry_run:
            emit_dry_run(" ".join(args))
            return subprocess.CompletedProcess(args, 0, "", "")
        try:
            return subprocess.run(
                list(args),
                input=input_text,
                text=True,
                check=check,
            )
        except FileNotFoundError as exc:
            raise ToolError(f"Missing required command: {args[0]}", EXIT_REQUIRE_COMMAND) from exc
        except subprocess.CalledProcessError as exc:
            raise ToolError(f"Command failed: {' '.join(args)}", EXIT_COMMAND) from exc

    def capture(self, *args: str, input_text: Optional[str] = None, check: bool = True) -> str:
        if self.dry_run:
            emit_dry_run(" ".join(args))
            return ""
        try:
            completed = subprocess.run(
                list(args),
                input=input_text,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=check,
            )
        except FileNotFoundError as exc:
            raise ToolError(f"Missing required command: {args[0]}", EXIT_REQUIRE_COMMAND) from exc
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or "").strip()
            detail = f": {stderr}" if stderr else ""
            raise ToolError(f"Command failed: {' '.join(args)}{detail}", EXIT_COMMAND) from exc
        return completed.stdout


class ConfigStore:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths

    def load(self) -> Config:
        if not self.paths.config.exists():
            raise ToolError(f"Config file not found: {self.paths.config}", EXIT_CONFIG)
        with self.paths.config.open("r", encoding="utf-8") as config_file:
            payload = json.load(config_file)
        if not isinstance(payload, dict):
            raise ToolError("Config file must contain a JSON object.", EXIT_CONFIG)
        return Config.from_dict(payload)

    def save(self, config: Config) -> None:
        content = json.dumps(config.to_dict(), indent=2, sort_keys=True)
        write_text_atomic(self.paths.config, f"{content}\n", 0o600)


@dataclasses.dataclass(frozen=True)
class Client:
    name: str
    host_number: int
    private_key: str
    public_key: str
    enabled: bool


class ClientRepository:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path

    def connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(str(self.db_path))
        connection.row_factory = sqlite3.Row
        return connection

    def init(self) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                create table if not exists clients(
                    name text primary key,
                    hostnumber integer not null unique,
                    privatekey text not null,
                    publickey text not null,
                    enable integer not null check(enable in (0, 1))
                )
                """
            )
        self.db_path.chmod(0o600)

    def get(self, name: str) -> Optional[Client]:
        with self.connect() as connection:
            row = connection.execute(
                "select name, hostnumber, privatekey, publickey, enable from clients where name = ?",
                (name,),
            ).fetchone()
        return self._row_to_client(row) if row else None

    def list(self, enabled: Optional[bool] = None) -> List[Client]:
        sql = "select name, hostnumber, privatekey, publickey, enable from clients"
        params: Tuple[int, ...] = ()
        if enabled is not None:
            sql += " where enable = ?"
            params = (1 if enabled else 0,)
        sql += " order by hostnumber"
        with self.connect() as connection:
            rows = connection.execute(sql, params).fetchall()
        return [self._row_to_client(row) for row in rows]

    def host_numbers(self) -> List[int]:
        with self.connect() as connection:
            rows = connection.execute("select hostnumber from clients order by hostnumber").fetchall()
        return [int(row["hostnumber"]) for row in rows]

    def add(self, client: Client) -> None:
        with self.connect() as connection:
            try:
                connection.execute(
                    """
                    insert into clients(name, hostnumber, privatekey, publickey, enable)
                    values(?, ?, ?, ?, ?)
                    """,
                    (client.name, client.host_number, client.private_key, client.public_key, 1 if client.enabled else 0),
                )
            except sqlite3.IntegrityError as exc:
                raise ToolError("Client name or host number already exists.", EXIT_DB) from exc

    def replace_all(self, clients: Sequence[Client]) -> None:
        with self.connect() as connection:
            try:
                connection.execute("delete from clients")
                connection.executemany(
                    """
                    insert into clients(name, hostnumber, privatekey, publickey, enable)
                    values(?, ?, ?, ?, ?)
                    """,
                    [
                        (client.name, client.host_number, client.private_key, client.public_key, 1 if client.enabled else 0)
                        for client in clients
                    ],
                )
            except sqlite3.IntegrityError as exc:
                raise ToolError("Imported clients contain duplicate name or host number.", EXIT_DB) from exc
        self.db_path.chmod(0o600)

    def add_many(self, clients: Sequence[Client]) -> None:
        with self.connect() as connection:
            try:
                connection.executemany(
                    """
                    insert into clients(name, hostnumber, privatekey, publickey, enable)
                    values(?, ?, ?, ?, ?)
                    """,
                    [
                        (client.name, client.host_number, client.private_key, client.public_key, 1 if client.enabled else 0)
                        for client in clients
                    ],
                )
            except sqlite3.IntegrityError as exc:
                raise ToolError("Imported clients conflict with existing clients.", EXIT_DB) from exc
        self.db_path.chmod(0o600)

    def remove(self, name: str) -> None:
        with self.connect() as connection:
            cursor = connection.execute("delete from clients where name = ?", (name,))
            if cursor.rowcount == 0:
                raise ToolError("Client not found.", EXIT_DB)

    def set_enabled(self, name: str, enabled: bool) -> Client:
        client = self.get(name)
        if client is None:
            raise ToolError("Client not found.", EXIT_DB)
        if client.enabled == enabled:
            state = "enabled" if enabled else "disabled"
            raise ToolError(f"Client already {state}.", 0)
        with self.connect() as connection:
            connection.execute("update clients set enable = ? where name = ?", (1 if enabled else 0, name))
        return dataclasses.replace(client, enabled=enabled)

    def rename(self, old_name: str, new_name: str) -> None:
        with self.connect() as connection:
            cursor = connection.execute("update clients set name = ? where name = ?", (new_name, old_name))
            if cursor.rowcount == 0:
                raise ToolError("Client not found.", EXIT_DB)

    @staticmethod
    def _row_to_client(row: sqlite3.Row) -> Client:
        return Client(
            name=str(row["name"]),
            host_number=int(row["hostnumber"]),
            private_key=str(row["privatekey"]),
            public_key=str(row["publickey"]),
            enabled=bool(row["enable"]),
        )


class WireGuardManager:
    def __init__(self, paths: Paths, config: Config, repo: ClientRepository, runner: Runner) -> None:
        self.paths = paths
        self.config = config
        self.repo = repo
        self.runner = runner

    def ensure_server_keys(self) -> None:
        private_key_path = self.paths.server_private_key(self.config)
        public_key_path = self.paths.server_public_key(self.config)
        if private_key_path.exists() and public_key_path.exists():
            chmod_private(private_key_path)
            return
        self.runner.require("wg")
        private_key = self.runner.capture("wg", "genkey").strip()
        public_key = self.runner.capture("wg", "pubkey", input_text=f"{private_key}\n").strip()
        write_text_atomic(private_key_path, f"{private_key}\n", 0o600)
        write_text_atomic(public_key_path, f"{public_key}\n", 0o644)

    def is_running(self) -> bool:
        return self.runner.succeeds("ip", "a", "s", self.config.interface)

    def live_add(self, client: Client) -> None:
        self.runner.run(
            "wg",
            "set",
            self.config.interface,
            "peer",
            client.public_key,
            "allowed-ips",
            self.config.peer_allowed_ip(client.host_number),
        )

    def live_remove(self, client: Client) -> None:
        self.runner.run("wg", "set", self.config.interface, "peer", client.public_key, "remove")

    def default_gateway_interface(self, timeout_seconds: int = 60) -> str:
        deadline = time.monotonic() + timeout_seconds
        while True:
            output = self.runner.capture("ip", "-o", "-4", "route", "show", "to", "default", check=False)
            interface = self._parse_gateway_interface(output)
            if interface:
                return interface
            if time.monotonic() >= deadline:
                raise ToolError("Cannot find default gateway interface.", EXIT_COMMAND)
            emit_warning("Cannot get gateway interface, retry after 2 seconds...")
            time.sleep(2)

    def render_server_config(self, gateway_interface: str) -> str:
        private_key = read_text_stripped(self.paths.server_private_key(self.config))
        return (
            "[Interface]\n"
            f"Address = {self.config.server_ip}\n"
            f"MTU = {self.config.mtu}\n"
            "SaveConfig = true\n"
            "PreUp = sysctl -w net.ipv4.ip_forward=1\n"
            "PostUp = "
            f"iptables -t nat -A POSTROUTING -o {gateway_interface} -j MASQUERADE;"
            f"iptables -I FORWARD 1 -i {self.config.interface} -o {gateway_interface} -s {self.config.subnet}.0/24 -j ACCEPT;"
            f"iptables -I FORWARD 2 -i {gateway_interface} -o {self.config.interface} -d {self.config.subnet}.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT;"
            f"ip rule add from {self.config.subnet}.0/24 table {self.config.table_no};"
            f"ip route add default via {self.config.client_gateway} table {self.config.table_no};\n"
            "PostDown = "
            f"iptables -t nat -D POSTROUTING -o {gateway_interface} -j MASQUERADE || true;"
            f"iptables -D FORWARD -i {self.config.interface} -o {gateway_interface} -s {self.config.subnet}.0/24 -j ACCEPT || true;"
            f"iptables -D FORWARD -i {gateway_interface} -o {self.config.interface} -d {self.config.subnet}.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true;"
            f"ip rule del from {self.config.subnet}.0/24 table {self.config.table_no} || true;"
            f"ip route del default table {self.config.table_no} || true;\n"
            f"ListenPort = {self.config.server_port}\n"
            f"PrivateKey = {private_key}\n"
        )

    def write_server_config(self) -> None:
        gateway_interface = self.default_gateway_interface()
        emit_info(f"Gateway interface: {gateway_interface}")
        content = self.render_server_config(gateway_interface)
        write_text_atomic(self.paths.server_config(self.config), content, 0o600)

    def add_enabled_peers(self) -> None:
        for client in self.repo.list(enabled=True):
            emit_info(f"Add peer: {client.name} {self.config.peer_allowed_ip(client.host_number)}")
            self.live_add(client)

    def export_client_config(self, client: Client) -> str:
        server_public_key = read_text_stripped(self.paths.server_public_key(self.config))
        allowed_ips = ", ".join(self.config.allowed_ips)
        return (
            "[Interface]\n"
            f"PrivateKey = {client.private_key}\n"
            f"Address = {self.config.client_ip(client.host_number, cidr=True)}\n"
            f"DNS = {self.config.client_dns}\n"
            f"MTU = {self.config.mtu}\n"
            "\n"
            "[Peer]\n"
            f"PublicKey = {server_public_key}\n"
            f"Endpoint = {self.config.server_endpoint}:{self.config.server_port}\n"
            f"AllowedIPs = {allowed_ips}\n"
            "PersistentKeepalive = 25\n"
        )

    @staticmethod
    def _parse_gateway_interface(output: str) -> str:
        for line in output.splitlines():
            parts = line.split()
            if "dev" in parts:
                index = parts.index("dev")
                if index + 1 < len(parts):
                    return parts[index + 1]
            if len(parts) >= 5:
                return parts[4]
        return ""


def load_config_and_manager(args: argparse.Namespace) -> Tuple[Config, ClientRepository, WireGuardManager]:
    paths = Paths(Path(args.root))
    config = ConfigStore(paths).load()
    runner = Runner(dry_run=getattr(args, "dry_run", False))
    repo = ClientRepository(paths.db)
    clients = repo.list() if paths.db.exists() else []
    return config, repo, WireGuardManager(paths, config, repo, runner)


def prompt_value(label: str, default: Optional[str] = None, validator: Optional[Callable[[str], object]] = None) -> str:
    if not sys.stdin.isatty():
        if default is not None:
            return default
        raise ToolError(f"{label} is required in non-interactive mode.", EXIT_CONFIG)
    prompt = f"{label}"
    if default is not None:
        prompt += f" [{default}]"
    prompt += ": "
    while True:
        try:
            value = input(prompt).strip()
        except EOFError as exc:
            raise ToolError(f"{label} is required in non-interactive mode.", EXIT_CONFIG) from exc
        if not value and default is not None:
            value = default
        if not value:
            emit_warning("Value is required.")
            continue
        if validator:
            try:
                validator(value)
            except (ToolError, ValueError) as exc:
                emit_warning(str(exc))
                continue
        return value


def build_config_from_install_args(args: argparse.Namespace) -> Config:
    server_port = args.server_port
    if server_port is None:
        server_port = int(prompt_value("Enter server port", "51820", parse_port))
    endpoint = args.endpoint or prompt_value("Enter server endpoint(ip or domain)")
    client_gateway = args.client_gateway or prompt_value("Enter client gateway", f"{DEFAULT_SUBNET}.2")
    client_dns = args.client_dns or prompt_value("Enter client DNS", "1.1.1.1")
    allowed_ips = tuple(validate_allowed_ips(split_allowed_ips(args.allowed_ip or DEFAULT_ALLOWED_IPS)))
    payload = {
        "interface": args.interface,
        "subnet": args.subnet,
        "server_ip": args.server_ip or f"{args.subnet}.1/24",
        "server_endpoint": endpoint,
        "server_port": server_port,
        "client_gateway": client_gateway,
        "client_dns": client_dns,
        "allowed_ips": list(allowed_ips),
        "mtu": args.mtu,
        "table_no": args.table_no,
        "server_private_key": SERVER_PRIVATE_KEY_NAME,
        "server_public_key": SERVER_PUBLIC_KEY_NAME,
    }
    return Config.from_dict(payload)


def missing_install_packages() -> List[str]:
    missing_packages: List[str] = []
    for package, commands in INSTALL_PACKAGES:
        if any(shutil.which(command) is None for command in commands):
            missing_packages.append(package)
    return missing_packages


def install_required_packages(runner: Runner) -> None:
    missing_packages = missing_install_packages()
    if not missing_packages:
        emit_success("System packages already installed.")
        return
    runner.require("apt")
    runner.run("apt", "update")
    runner.run("apt", "install", *missing_packages, "-y")


def install_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    paths = Paths(Path(args.root))
    runner = Runner(dry_run=args.dry_run)
    if not args.skip_packages:
        if not args.dry_run:
            install_required_packages(runner)
        else:
            emit_dry_run("install missing packages when needed")
    if not args.dry_run:
        runner.require("wg", "systemctl")
    config = build_config_from_install_args(args)
    if args.dry_run:
        emit_dry_run(f"create {paths.root}")
        emit_dry_run(f"write {paths.config}")
        emit(json.dumps(config.to_dict(), indent=2, sort_keys=True))
        emit_dry_run(f"initialize {paths.db}")
        emit_dry_run(f"ensure server keys in {paths.root}")
        install_symlink(args, runner)
        emit_dry_run(f"write /etc/systemd/system/wg-quick@{config.interface}.service.d/override.conf")
        runner.run("systemctl", "daemon-reload")
        runner.run("systemctl", "enable", f"wg-quick@{config.interface}")
        return 0
    paths.root.mkdir(parents=True, exist_ok=True)
    paths.root.chmod(0o700)
    ConfigStore(paths).save(config)
    repo = ClientRepository(paths.db)
    repo.init()
    manager = WireGuardManager(paths, config, repo, runner)
    manager.ensure_server_keys()
    install_symlink(args, runner)
    write_systemd_override(config, args.bin_path, str(paths.root))
    runner.run("systemctl", "daemon-reload")
    runner.run("systemctl", "enable", f"wg-quick@{config.interface}")
    emit_success(f"Installed wgtool for {config.interface}.")
    return 0


def install_symlink(args: argparse.Namespace, runner: Runner) -> None:
    link_path = Path(args.bin_path)
    target_path = Path(__file__).resolve()
    if runner.dry_run:
        emit_dry_run(f"link {link_path} -> {target_path}")
        return
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.exists() or link_path.is_symlink():
        link_path.unlink()
    link_path.symlink_to(target_path)


def write_systemd_override(config: Config, bin_path: str, root: str) -> None:
    drop_in_dir = Path(f"/etc/systemd/system/wg-quick@{config.interface}.service.d")
    override_path = drop_in_dir / "override.conf"
    command_prefix = f"{shlex.quote(bin_path)} --root {shlex.quote(root)}"
    root_path = Path(root)
    config_path = root_path / f"{config.interface}.conf"
    service_root_lines = ""
    if root_path != WIREGUARD_ROOT:
        service_root_lines = (
            "ExecStart=\n"
            f"ExecStart=/usr/bin/wg-quick up {shlex.quote(str(config_path))}\n"
            "ExecStop=\n"
            f"ExecStop=/usr/bin/wg-quick down {shlex.quote(str(config_path))}\n"
        )
    content = (
        "[Service]\n"
        f"{service_root_lines}"
        f"ExecStartPre={command_prefix} hook start-pre\n"
        f"ExecStartPost={command_prefix} hook start-post\n"
        f"ExecStopPost={command_prefix} hook stop-post\n"
    )
    write_text_atomic(override_path, content, 0o644)


def uninstall_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    if not args.yes:
        raise ToolError("Use --yes to confirm uninstall.", EXIT_CONFIG)
    paths = Paths(Path(args.root))
    config = ConfigStore(paths).load() if paths.config.exists() else Config()
    runner = Runner(dry_run=args.dry_run)
    runner.run("systemctl", "stop", f"wg-quick@{config.interface}", check=False)
    runner.run("systemctl", "disable", f"wg-quick@{config.interface}", check=False)
    link_path = Path(args.bin_path)
    if not args.keep_config and paths.root.exists():
        remove_path(paths.root, args.dry_run)
    drop_in_dir = Path(f"/etc/systemd/system/wg-quick@{config.interface}.service.d")
    if drop_in_dir.exists():
        remove_path(drop_in_dir, args.dry_run)
    if link_path.is_symlink() or link_path.exists():
        remove_path(link_path, args.dry_run)
    runner.run("systemctl", "daemon-reload")
    emit_success("Uninstalled wgtool.")
    return 0


def remove_path(path: Path, dry_run: bool) -> None:
    if dry_run:
        emit_dry_run(f"remove {path}")
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def service_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    paths = Paths(Path(args.root))
    config, _, _ = load_config_and_manager(args)
    runner = Runner(dry_run=args.dry_run)
    service_name = f"wg-quick@{config.interface}"
    if args.service_action == "reload":
        reload_interface(paths, config, runner)
        return 0
    runner.run("systemctl", args.service_action, service_name, check=args.service_action != "status")
    return 0


def reload_interface(paths: Paths, config: Config, runner: Runner) -> None:
    runner.require("wg-quick", "wg")
    stripped = runner.capture("wg-quick", "strip", str(paths.server_config(config)))
    temp_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as temp_file:
            temp_path = Path(temp_file.name)
            temp_file.write(stripped)
        temp_path.chmod(0o600)
        runner.run("wg", "syncconf", config.interface, str(temp_path))
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def hook_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, _, manager = load_config_and_manager(args)
    manager.runner.require("wg", "ip")
    if args.hook_action == "start-pre":
        emit_info("hook start-pre")
        manager.ensure_server_keys()
        manager.write_server_config()
    elif args.hook_action == "start-post":
        emit_info("hook start-post")
        manager.add_enabled_peers()
    elif args.hook_action == "stop-post":
        emit_info("hook stop-post")
    else:
        raise ToolError("Unknown hook action.", EXIT_CONFIG)
    return 0


def add_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    config, repo, manager = load_config_and_manager(args)
    manager.runner.require("wg")
    name = check_client_name(args.name)
    host_number = parse_host_number(args.host_number) if args.host_number else next_host_number(repo)
    private_key = manager.runner.capture("wg", "genkey").strip()
    public_key = manager.runner.capture("wg", "pubkey", input_text=f"{private_key}\n").strip()
    client = Client(name=name, host_number=host_number, private_key=private_key, public_key=public_key, enabled=True)
    repo.add(client)
    emit_success(f"Client added: {name} {config.client_ip(host_number)}")
    if manager.is_running():
        manager.live_add(client)
        emit_success("Peer added to running interface.")
    if args.export or not args.no_qr or args.output:
        export_client(manager, client, args.output, not args.no_qr)
    return 0


def remove_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, repo, manager = load_config_and_manager(args)
    name = check_client_name(args.name)
    client = repo.get(name)
    if client is None:
        raise ToolError("Client not found.", EXIT_DB)
    repo.remove(name)
    if manager.is_running():
        manager.live_remove(client)
        emit_success("Peer removed from running interface.")
    emit_success(f"Client removed: {name}")
    return 0


def enable_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, repo, manager = load_config_and_manager(args)
    client = repo.set_enabled(check_client_name(args.name), True)
    if manager.is_running():
        manager.live_add(client)
        emit_success("Peer added to running interface.")
    emit_success(f"Client enabled: {client.name}")
    return 0


def disable_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, repo, manager = load_config_and_manager(args)
    client = repo.set_enabled(check_client_name(args.name), False)
    if manager.is_running():
        manager.live_remove(client)
        emit_success("Peer removed from running interface.")
    emit_success(f"Client disabled: {client.name}")
    return 0


def rename_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, repo, _ = load_config_and_manager(args)
    old_name = check_client_name(args.old_name)
    new_name = check_client_name(args.new_name)
    repo.rename(old_name, new_name)
    emit_success(f"Client renamed: {old_name} -> {new_name}")
    return 0


def list_clients_command(args: argparse.Namespace) -> int:
    _, repo, _ = load_config_and_manager(args)
    clients = repo.list()
    if not clients:
        emit_info("No clients.")
        return 0
    if args.show_private_key:
        emit(table_header(f"{'NAME':<16} {'IP':<16} {'ENABLED':<8} {'PRIVATE_KEY':<44} PUBLIC_KEY"))
    else:
        emit(table_header(f"{'NAME':<16} {'IP':<16} {'ENABLED':<8} PUBLIC_KEY"))
    config = ConfigStore(Paths(Path(args.root))).load()
    for client in clients:
        enabled = "yes" if client.enabled else "no"
        if args.show_private_key:
            emit(
                f"{client.name:<16} {config.client_ip(client.host_number):<16} "
                f"{enabled:<8} {client.private_key:<44} {client.public_key}"
            )
        else:
            emit(f"{client.name:<16} {config.client_ip(client.host_number):<16} {enabled:<8} {client.public_key}")
    return 0


def export_client_command(args: argparse.Namespace) -> int:
    require_linux()
    require_root()
    _, repo, manager = load_config_and_manager(args)
    client = repo.get(check_client_name(args.name))
    if client is None:
        raise ToolError("Client not found.", EXIT_DB)
    export_client(manager, client, args.output, not args.no_qr)
    return 0


def export_client(manager: WireGuardManager, client: Client, output: Optional[str], qr: bool) -> None:
    content = manager.export_client_config(client)
    if output:
        output_path = Path(output)
        write_text_atomic(output_path, content, 0o600)
        emit_success(f"Client config written: {output_path}")
    else:
        emit(content.rstrip())
    if qr:
        manager.runner.require("qrencode")
        manager.runner.run("qrencode", "-t", "ansiutf8", input_text=content)


def client_to_state(client: Client, public_only: bool = False) -> dict:
    payload = {
        "name": client.name,
        "host_number": client.host_number,
        "public_key": client.public_key,
        "enabled": client.enabled,
    }
    if not public_only:
        payload["private_key"] = client.private_key
    return payload


def client_from_state(payload: dict, public_only: bool = False) -> Client:
    if not isinstance(payload, dict):
        raise ToolError("Each imported client must be an object.", EXIT_CONFIG)
    name = check_client_name(str(payload.get("name", "")))
    try:
        host_number = check_host_number(int(payload.get("host_number")))
    except (TypeError, ValueError) as exc:
        raise ToolError(f"Invalid host_number for client {name}.", EXIT_CONFIG) from exc
    public_key = str(payload.get("public_key", "")).strip()
    private_key = str(payload.get("private_key", "")).strip()
    if not public_key:
        raise ToolError(f"Missing public_key for client {name}.", EXIT_CONFIG)
    if not public_only and not private_key:
        raise ToolError(f"Missing private_key for client {name}.", EXIT_CONFIG)
    return Client(
        name=name,
        host_number=host_number,
        private_key=private_key,
        public_key=public_key,
        enabled=bool(payload.get("enabled", True)),
    )


def state_export_command(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.root))
    config = ConfigStore(paths).load()
    repo = ClientRepository(paths.db)
    clients = repo.list() if paths.db.exists() else []
    public_key_path = paths.server_public_key(config)
    if not public_key_path.exists():
        raise ToolError(f"Server public key not found: {public_key_path}", EXIT_CONFIG)
    payload = {
        "format": STATE_FORMAT,
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "public_only": bool(args.public_only),
        "config": config.to_dict(),
        "server_keys": {
            "public_key": read_text_stripped(public_key_path),
        },
        "clients": [client_to_state(client, public_only=args.public_only) for client in clients],
    }
    if not args.public_only:
        private_key_path = paths.server_private_key(config)
        if not private_key_path.exists():
            raise ToolError(f"Server private key not found: {private_key_path}", EXIT_CONFIG)
        payload["server_keys"]["private_key"] = read_text_stripped(private_key_path)
        emit_warning("Export contains private keys. Keep the file private.")
    content = json.dumps(payload, indent=2, sort_keys=True)
    if args.output:
        output_path = Path(args.output)
        if output_path.exists() and not args.force:
            raise ToolError(f"Output file already exists: {output_path}. Use --force to overwrite.", EXIT_CONFIG)
        write_text_atomic(output_path, f"{content}\n", 0o600)
        emit_success(f"State exported: {output_path}")
    else:
        emit(content)
    return 0


def state_import_command(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.root))
    input_path = Path(args.input)
    if not input_path.exists():
        raise ToolError(f"Import file not found: {input_path}", EXIT_CONFIG)
    with input_path.open("r", encoding="utf-8") as input_file:
        payload = json.load(input_file)
    config, server_keys, clients, public_only = parse_state_payload(payload)
    if public_only:
        raise ToolError("Public-only state cannot be imported.", EXIT_CONFIG)
    repo = ClientRepository(paths.db)
    if args.mode == "replace" and not args.yes and not args.dry_run:
        raise ToolError("Use --yes to confirm replace import.", EXIT_CONFIG)
    if args.mode == "merge":
        check_merge_conflicts(repo, clients)
    if args.dry_run:
        emit_dry_run(f"import state from {input_path}")
        emit_info(f"Mode: {args.mode}")
        emit_info(f"Clients: {len(clients)}")
        return 0
    repo.init()
    if args.mode == "replace":
        backup_existing_state(paths)
        ConfigStore(paths).save(config)
        write_imported_server_keys(paths, config, server_keys)
        repo.replace_all(clients)
    elif args.mode == "merge":
        repo.add_many(clients)
    else:
        raise ToolError("Invalid import mode.", EXIT_CONFIG)
    emit_success("State imported.")
    emit_info("Run: wgtool service restart")
    return 0


def parse_state_payload(payload: dict) -> Tuple[Config, dict, List[Client], bool]:
    if not isinstance(payload, dict):
        raise ToolError("State file must contain a JSON object.", EXIT_CONFIG)
    if payload.get("format") != STATE_FORMAT:
        raise ToolError(f"Unsupported state format: {payload.get('format')}", EXIT_CONFIG)
    public_only = bool(payload.get("public_only", False))
    config_payload = payload.get("config")
    if not isinstance(config_payload, dict):
        raise ToolError("State file missing config object.", EXIT_CONFIG)
    config = Config.from_dict(config_payload)
    server_keys = payload.get("server_keys")
    if not isinstance(server_keys, dict):
        raise ToolError("State file missing server_keys object.", EXIT_CONFIG)
    if not server_keys.get("public_key"):
        raise ToolError("State file missing server public key.", EXIT_CONFIG)
    if not public_only and not server_keys.get("private_key"):
        raise ToolError("State file missing server private key.", EXIT_CONFIG)
    clients_payload = payload.get("clients")
    if not isinstance(clients_payload, list):
        raise ToolError("State file missing clients list.", EXIT_CONFIG)
    clients = [client_from_state(item, public_only=public_only) for item in clients_payload]
    check_import_client_duplicates(clients)
    return config, server_keys, clients, public_only


def check_import_client_duplicates(clients: Sequence[Client]) -> None:
    names = set()
    host_numbers = set()
    for client in clients:
        if client.name in names:
            raise ToolError(f"Duplicate client name in import: {client.name}", EXIT_CONFIG)
        if client.host_number in host_numbers:
            raise ToolError(f"Duplicate host number in import: {client.host_number}", EXIT_CONFIG)
        names.add(client.name)
        host_numbers.add(client.host_number)


def check_merge_conflicts(repo: ClientRepository, clients: Sequence[Client]) -> None:
    if not repo.db_path.exists():
        return
    existing_clients = repo.list()
    existing_by_name = {client.name for client in existing_clients}
    existing_host_numbers = {client.host_number for client in existing_clients}
    for client in clients:
        if client.name in existing_by_name:
            raise ToolError(f"Client name already exists: {client.name}", EXIT_DB)
        if client.host_number in existing_host_numbers:
            raise ToolError(f"Host number already exists: {client.host_number}", EXIT_DB)


def backup_existing_state(paths: Paths) -> None:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    for path in (paths.config, paths.db):
        if path.exists():
            backup_path = path.with_name(f"{path.name}.{timestamp}.bak")
            write_bytes_atomic(backup_path, path.read_bytes(), 0o600)


def write_imported_server_keys(paths: Paths, config: Config, server_keys: dict) -> None:
    write_text_atomic(paths.server_private_key(config), f"{server_keys['private_key']}\n", 0o600)
    write_text_atomic(paths.server_public_key(config), f"{server_keys['public_key']}\n", 0o644)


def next_host_number(repo: ClientRepository) -> int:
    used = set(repo.host_numbers())
    for host_number in range(2, 255):
        if host_number not in used:
            return host_number
    raise ToolError("No available host number.", EXIT_DB)


def config_show_command(args: argparse.Namespace) -> int:
    config = ConfigStore(Paths(Path(args.root))).load()
    emit(json.dumps(config.to_dict(), indent=2, sort_keys=True))
    return 0


def config_edit_command(args: argparse.Namespace) -> int:
    require_root()
    paths = Paths(Path(args.root))
    before = file_hash(paths.config)
    editor = os.environ.get("EDITOR") or os.environ.get("editor") or "vi"
    Runner(dry_run=args.dry_run).run(editor, str(paths.config))
    ConfigStore(paths).load()
    after = file_hash(paths.config)
    if before != after:
        emit_warning("Config changed. Restart service when needed.")
    return 0


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def status_command(args: argparse.Namespace) -> int:
    require_linux()
    config, repo, manager = load_config_and_manager(args)
    manager.runner.require("wg")
    emit(f"server endpoint: {config.server_endpoint}")
    emit(f"server port: {config.server_port}")
    emit(f"client gateway: {config.client_gateway}")
    emit(f"client DNS: {config.client_dns}")
    emit(f"MTU: {config.mtu}")
    emit("")
    clients = repo.list()
    pubkey_to_client = {client.public_key: client for client in clients}
    wg_output = manager.runner.capture("wg", check=False)
    for line in wg_output.splitlines():
        stripped = line.strip()
        if stripped.startswith("peer: "):
            public_key = stripped.split("peer: ", 1)[1]
            client = pubkey_to_client.get(public_key)
            if client:
                emit(f"name: {client.name}")
                emit(f"enable: {1 if client.enabled else 0}")
                if args.show_private_key:
                    emit(f"private key: {client.private_key}")
        emit(line)
    if wg_output:
        emit("")
    for client in [item for item in clients if not item.enabled]:
        emit(f"name: {client.name}")
        emit("enable: 0")
        if args.show_private_key:
            emit(f"private key: {client.private_key}")
        emit(f"peer: {client.public_key}")
        emit(f"ip: {config.client_ip(client.host_number)}")
        emit("")
    return 0


def migrate_from_shell_command(args: argparse.Namespace) -> int:
    require_root()
    paths = Paths(Path(args.root))
    settings = parse_shell_settings(paths.old_settings)
    if not settings:
        raise ToolError(f"Old settings not found or empty: {paths.old_settings}", EXIT_CONFIG)
    payload = {
        "interface": settings.get("interfaceName", DEFAULT_INTERFACE),
        "subnet": settings.get("subnet", DEFAULT_SUBNET),
        "server_ip": settings.get("serverIp", f"{settings.get('subnet', DEFAULT_SUBNET)}.1/24"),
        "server_endpoint": settings.get("serverEndpoint", ""),
        "server_port": int(settings.get("serverPort", "51820")),
        "client_gateway": settings.get("clientGateway", f"{settings.get('subnet', DEFAULT_SUBNET)}.2"),
        "client_dns": settings.get("clientDns", "1.1.1.1"),
        "allowed_ips": split_allowed_ips([settings.get("allowedIPs", ", ".join(DEFAULT_ALLOWED_IPS))]),
        "mtu": int(settings.get("MTU", str(DEFAULT_MTU))),
        "table_no": int(settings.get("tableNo", str(DEFAULT_TABLE_NO))),
        "server_private_key": settings.get("serverPrikey", SERVER_PRIVATE_KEY_NAME),
        "server_public_key": settings.get("serverPubkey", SERVER_PUBLIC_KEY_NAME),
    }
    config = Config.from_dict(payload)
    if paths.config.exists() and not args.force:
        raise ToolError(f"Config already exists: {paths.config}. Use --force to overwrite.", EXIT_CONFIG)
    ConfigStore(paths).save(config)
    if paths.old_db.exists():
        if paths.db.exists() and not args.force:
            raise ToolError(f"DB already exists: {paths.db}. Use --force to overwrite.", EXIT_DB)
        shutil.copy2(paths.old_db, paths.db)
    ClientRepository(paths.db).init()
    emit_success("Migration completed.")
    return 0


def parse_shell_settings(path: Path) -> dict:
    if not path.exists():
        return {}
    values = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        values[key] = expand_shell_value(value, values)
    return values


def expand_shell_value(value: str, values: dict) -> str:
    for key, known_value in values.items():
        value = value.replace(f"${{{key}}}", str(known_value))
    return value


def add_subparser(subparsers: argparse._SubParsersAction, name: str, help_text: str, **kwargs: object) -> argparse.ArgumentParser:
    kwargs.setdefault("formatter_class", argparse.RawTextHelpFormatter)
    return subparsers.add_parser(name, help=help_text, description=help_text, **kwargs)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wgtool",
        description="Manage a WireGuard server, clients, systemd hooks, and wgtool state backups.",
        epilog=(
            "Examples:\n"
            "  wgtool install --endpoint vpn.example.com --client-gateway 10.2.8.8\n"
            "  wgtool client add alice\n"
            "  wgtool client export alice --output alice.conf\n"
            "  wgtool state export --output backup.json\n"
            "  wgtool service restart"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("--root", default=str(WIREGUARD_ROOT), help="WireGuard data directory")
    parser.add_argument("--dry-run", action="store_true", help="show planned actions without writing")
    parser.add_argument("--no-color", action="store_true", help="disable colored output")
    subparsers = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)

    install_parser = add_subparser(subparsers, "install", "Install packages and create wgtool config/systemd hooks.")
    install_parser.add_argument("--interface", default=DEFAULT_INTERFACE, help=f"WireGuard interface name (default: {DEFAULT_INTERFACE})")
    install_parser.add_argument("--subnet", default=DEFAULT_SUBNET, help=f"WireGuard IPv4 /24 prefix (default: {DEFAULT_SUBNET})")
    install_parser.add_argument("--server-ip", help="server interface address, e.g. 10.10.10.1/24")
    install_parser.add_argument("--server-port", type=int, help="WireGuard listen port")
    install_parser.add_argument("--endpoint", help="public server endpoint")
    install_parser.add_argument("--client-gateway", help="policy-route gateway used by clients")
    install_parser.add_argument("--client-dns", help="DNS written to client configs")
    install_parser.add_argument("--allowed-ip", action="append", help="client AllowedIPs; may be repeated or comma-separated")
    install_parser.add_argument("--mtu", type=int, default=DEFAULT_MTU, help=f"WireGuard MTU (default: {DEFAULT_MTU})")
    install_parser.add_argument("--table-no", type=int, default=DEFAULT_TABLE_NO, help=f"policy routing table number (default: {DEFAULT_TABLE_NO})")
    install_parser.add_argument("--skip-packages", action="store_true", help="do not install missing system packages")
    install_parser.add_argument("--bin-path", default="/usr/local/bin/wgtool", help="symlink path for wgtool")
    install_parser.set_defaults(func=install_command)

    uninstall_parser = add_subparser(subparsers, "uninstall", "Remove wgtool systemd hooks, symlink, and optionally config.")
    uninstall_parser.add_argument("--yes", action="store_true", help="confirm uninstall")
    uninstall_parser.add_argument("--keep-config", action="store_true", help="keep wgtool root directory")
    uninstall_parser.add_argument("--bin-path", default="/usr/local/bin/wgtool", help="symlink path to remove")
    uninstall_parser.set_defaults(func=uninstall_command)

    service_parser = add_subparser(subparsers, "service", "Control the wg-quick systemd service.")
    service_subparsers = service_parser.add_subparsers(dest="service_action", metavar="ACTION", required=True)
    for action, help_text in (
        ("start", "start wg-quick service"),
        ("stop", "stop wg-quick service"),
        ("restart", "restart wg-quick service"),
        ("status", "show systemd service status"),
    ):
        action_parser = add_subparser(service_subparsers, action, help_text)
        action_parser.set_defaults(func=service_command)
    reload_parser = add_subparser(service_subparsers, "reload", "sync current wg-quick config into the running interface")
    reload_parser.set_defaults(func=service_command)

    hook_parser = add_subparser(subparsers, "hook", "Internal systemd hook commands.")
    hook_subparsers = hook_parser.add_subparsers(dest="hook_action", metavar="ACTION", required=True)
    for action, help_text in (
        ("start-pre", "render server config before wg-quick starts"),
        ("start-post", "add enabled clients after interface startup"),
        ("stop-post", "post-stop hook placeholder"),
    ):
        action_parser = add_subparser(hook_subparsers, action, help_text)
        action_parser.set_defaults(func=hook_command)

    client_parser = add_subparser(subparsers, "client", "Manage WireGuard clients.")
    client_subparsers = client_parser.add_subparsers(dest="client_action", metavar="ACTION", required=True)
    client_add_parser = add_subparser(client_subparsers, "add", "Create a client key pair and DB record.")
    client_add_parser.add_argument("name", help="client name")
    client_add_parser.add_argument("--host-number", help="last octet in the WireGuard subnet")
    client_add_parser.add_argument("--export", action="store_true", help="print/write client config after adding")
    client_add_parser.add_argument("--no-qr", action="store_true", help="do not print QR code")
    client_add_parser.add_argument("--output", help="write client config to file")
    client_add_parser.set_defaults(func=add_client_command)

    client_remove_parser = add_subparser(client_subparsers, "remove", "Remove a client from DB and live interface.")
    client_remove_parser.add_argument("name", help="client name")
    client_remove_parser.set_defaults(func=remove_client_command)

    client_enable_parser = add_subparser(client_subparsers, "enable", "Enable a client and add it to a running interface.")
    client_enable_parser.add_argument("name", help="client name")
    client_enable_parser.set_defaults(func=enable_client_command)

    client_disable_parser = add_subparser(client_subparsers, "disable", "Disable a client and remove it from a running interface.")
    client_disable_parser.add_argument("name", help="client name")
    client_disable_parser.set_defaults(func=disable_client_command)

    client_rename_parser = add_subparser(client_subparsers, "rename", "Rename a client.")
    client_rename_parser.add_argument("old_name", help="current client name")
    client_rename_parser.add_argument("new_name", help="new client name")
    client_rename_parser.set_defaults(func=rename_client_command)

    client_list_parser = add_subparser(client_subparsers, "list", "List clients.")
    client_list_parser.add_argument("--show-private-key", action="store_true", help="include client private keys")
    client_list_parser.set_defaults(func=list_clients_command)

    client_export_parser = add_subparser(client_subparsers, "export", "Export client config and print QR code by default.")
    client_export_parser.add_argument("name", help="client name")
    client_export_parser.add_argument("--output", help="write client config to file")
    client_export_parser.add_argument("--no-qr", action="store_true", help="do not print QR code")
    client_export_parser.set_defaults(func=export_client_command)

    state_parser = add_subparser(subparsers, "state", "Export or import wgtool state backups.")
    state_subparsers = state_parser.add_subparsers(dest="state_action", metavar="ACTION", required=True)
    state_export_parser = add_subparser(state_subparsers, "export", "Export config, server keys, and clients to JSON.")
    state_export_parser.add_argument("--output", help="write backup JSON to file")
    state_export_parser.add_argument("--force", action="store_true", help="overwrite existing output file")
    state_export_parser.add_argument("--public-only", action="store_true", help="omit all private keys")
    state_export_parser.set_defaults(func=state_export_command)

    state_import_parser = add_subparser(state_subparsers, "import", "Import a wgtool state backup JSON.")
    state_import_parser.add_argument("input", help="backup JSON path")
    state_import_parser.add_argument("--mode", choices=("merge", "replace"), default="merge", help="merge clients or replace full state")
    state_import_parser.add_argument("--yes", action="store_true", help="confirm replace import")
    state_import_parser.set_defaults(func=state_import_command)

    config_parser = add_subparser(subparsers, "config", "Show or edit wgtool JSON config.")
    config_subparsers = config_parser.add_subparsers(dest="config_action", metavar="ACTION", required=True)
    config_show_parser = add_subparser(config_subparsers, "show", "Print wgtool JSON config.")
    config_show_parser.set_defaults(func=config_show_command)
    config_edit_parser = add_subparser(config_subparsers, "edit", "Open wgtool JSON config in editor.")
    config_edit_parser.set_defaults(func=config_edit_command)

    status_parser = add_subparser(subparsers, "status", "Show wgtool config summary and wg status.")
    status_parser.add_argument("--show-private-key", action="store_true", help="include private keys in status output")
    status_parser.set_defaults(func=status_command)

    migrate_parser = add_subparser(subparsers, "migrate-from-shell", "Import old wireguard.sh settings/db into wgtool files.")
    migrate_parser.add_argument("--force", action="store_true", help="overwrite existing wgtool config/db")
    migrate_parser.set_defaults(func=migrate_from_shell_command)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.no_color:
        os.environ["NO_COLOR"] = "1"
    try:
        return int(args.func(args))
    except ToolError as exc:
        if str(exc):
            emit_err(str(exc))
        return exc.exit_code
    except KeyboardInterrupt:
        emit_err("Interrupted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
