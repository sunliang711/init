from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from .common import (
    AuditConfig,
    COLOR_GREEN,
    COLOR_RED,
    COLOR_YELLOW,
    CLIArgumentParser,
    CLIError,
    add_bool_argument,
    adopt_versioned_binary_layout,
    atomic_symlink,
    atomic_write_text,
    command_exists,
    color_text,
    current_script_dir,
    detect_arch,
    download_file,
    ensure_default_path,
    extract_zip,
    fetch_url,
    hcl_bool,
    hcl_list,
    hcl_string,
    http_status,
    install_text,
    kept_binary_versions,
    linked_binary_path,
    log_error,
    log_info,
    log_success,
    log_warn,
    missing_subcommand,
    prune_binary_versions,
    require_command,
    require_linux,
    run,
    run_root,
    run_with_audit,
    safe_remove_path,
    sha256_file,
    terminal_status_prefix,
    version_tuple,
    versioned_binary_path,
)


CONSUL_MANAGER_CMD = os.environ.get("CONSUL_MANAGER_CMD", "consul-manager")
DEFAULT_CONSUL_VERSION = "1.21.0"
CONSUL_USER = "consul"
CONSUL_GROUP = "consul"
CONSUL_ROOT_DIR = Path("/opt/consul")
BIN_DIR = CONSUL_ROOT_DIR / "bin"
BIN_PATH = BIN_DIR / "consul"
BINARY_VERSION_DIR = BIN_DIR / "versions"
BIN_ENTRY = Path("/usr/local/bin/consul")
CONFIG_DIR = CONSUL_ROOT_DIR / "etc" / "consul.d"
CONFIG_FILE = CONFIG_DIR / "consul.hcl"
DATA_DIR = CONSUL_ROOT_DIR / "data" / "consul"
CONSUL_AGENT_DATA_DIR = DATA_DIR / "agent"
SYSTEMD_SERVICE = Path("/etc/systemd/system/consul.service")
TOOL_DIR = CONSUL_ROOT_DIR / "lib" / "consul-init-tools"
TOOL_STATE_DIR = CONSUL_ROOT_DIR / "data" / "consul-init-tools"
TOOL_LOG_DIR = CONSUL_ROOT_DIR / "log" / "consul-init-tools"
TOOL_PATH = BIN_DIR / "consul-manager"
TOOL_ENTRY = Path("/usr/local/bin/consul-manager")
TOOL_VERSION_FILE = TOOL_DIR / "VERSION"
TOOL_MANIFEST_FILE = TOOL_DIR / "MANIFEST.sha256"
INSTALL_METADATA_FILE = TOOL_STATE_DIR / "install.json"
AUDIT_LOG_FILE = TOOL_LOG_DIR / "manager.audit.log"
DATA_POINTER_FILE = DATA_DIR / ".managed-by-consul-init-tools"
RELEASE_INDEX_URL = "https://releases.hashicorp.com/consul/"
CONSUL_ADDR = "http://127.0.0.1:8500"
DEFAULT_NOMAD_ADDR = "http://127.0.0.1:4646"
LOCAL_NO_PROXY = "127.0.0.1,localhost,::1"
MANAGED_MARKER = "# Managed by tools/consul/consul-manager"
TLS_CONFIG = CONFIG_DIR / "30-tls.hcl"
UI_CONFIG = CONFIG_DIR / "35-ui.hcl"
TELEMETRY_CONFIG = CONFIG_DIR / "40-telemetry.hcl"
DNS_CONFIG = CONFIG_DIR / "50-dns.hcl"
NOMAD_AGENT_TOKEN_FILE = CONFIG_DIR / "nomad-agent.token"
DEFAULT_DATACENTER = "dc1"
DEFAULT_BIND_ADDR = "127.0.0.1"
DEFAULT_CLIENT_ADDR = "127.0.0.1"
DEFAULT_HTTP_PORT = 8500
DEFAULT_GRPC_PORT = 8502
DEFAULT_DNS_PORT = 8600
NOMAD_AUTH_METHOD = "nomad-workloads"
NOMAD_AGENT_POLICY = "nomad-agent"
NOMAD_AGENT_TOKEN_DESCRIPTION = "Nomad agent token managed by consul-manager"
LOCAL_ADDRESSES = {"", "127.0.0.1", "localhost", "::1", "[::1]"}
DNS_TOKEN_CONFIG = CONFIG_DIR / "60-dns-token.hcl"
DNS_POLICY_NAME = "dns-read"
DNS_TOKEN_DESCRIPTION = "Consul DNS token managed by consul-manager"


def normalize_version(version: str) -> str:
    value = version.removeprefix("v")
    if not re.match(r"^[0-9]+[.][0-9]+[.][0-9]+$", value):
        raise CLIError(f"Invalid Consul version: {version}")
    return value


def parse_binary_version(output: str) -> str:
    """The version a consul binary reports, or "" when the output is unexpected."""
    match = re.search(r"Consul v([0-9]+[.][0-9]+[.][0-9]+)", output)
    return match.group(1) if match else ""


def installed_binary_version() -> str:
    """What the binary on this node reports, which upgrade trusts over metadata."""
    if not BIN_PATH.is_file():
        return ""
    return parse_binary_version(run([str(BIN_PATH), "version"], capture=True, check=False).stdout or "")


def fetch_latest_version() -> str:
    html = fetch_url(RELEASE_INDEX_URL, timeout=60).decode("utf-8", errors="replace")
    versions = re.findall(r'href="/consul/([0-9]+\.[0-9]+\.[0-9]+)/"', html)
    if not versions:
        raise CLIError("Failed to resolve latest Consul version")
    return normalize_version(versions[0])


def resolve_version(requested: str | None) -> str:
    if requested and requested != "latest":
        return normalize_version(requested)
    try:
        latest = fetch_latest_version()
        log_success(f"Resolved latest Consul version: {latest}")
        return latest
    except Exception:
        log_warn(f"Failed to resolve latest Consul version, fallback to {DEFAULT_CONSUL_VERSION}")
        return DEFAULT_CONSUL_VERSION


def resolve_upgrade_target(requested: str) -> str:
    """Resolve what to upgrade to, failing rather than guessing.

    resolve_version falls back to the pinned default when the release index is
    unreachable. That is fine for a fresh install, but here it would move a
    running node onto a version nobody asked for.
    """
    if requested and requested != "latest":
        return normalize_version(requested)
    try:
        latest = fetch_latest_version()
    except CLIError:
        raise
    except Exception as exc:
        raise CLIError(f"Cannot resolve the latest Consul version: {exc}. "
                       f"Pass --version to pick one explicitly") from exc
    log_success(f"Resolved latest Consul version: {latest}")
    return latest


def is_managed_file(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with path.open("r", encoding="utf-8") as handle:
            first_line = handle.readline().rstrip("\n")
    except OSError:
        return False
    return first_line == MANAGED_MARKER


def ensure_managed_or_absent(path: Path) -> None:
    if path.exists() and not is_managed_file(path):
        raise CLIError(f"Refuse to manage non-managed file: {path}")


def require_config_environment() -> None:
    require_linux()
    require_command("install")
    require_command("systemctl")
    if not BIN_PATH.exists():
        raise CLIError(f"Consul binary not found: {BIN_PATH}. Please run install first")
    run_root(["install", "-d", "-m", "0750", "-o", CONSUL_USER, "-g", CONSUL_GROUP, str(CONFIG_DIR)])


def validate_consul_config() -> None:
    run_root([str(BIN_PATH), "validate", str(CONFIG_DIR)])


def consul_leader_elected() -> bool:
    try:
        body = fetch_url(f"{CONSUL_ADDR}/v1/status/leader", timeout=2, no_proxy=True)
    except Exception:
        return False
    return body.decode("utf-8", errors="replace").strip() not in {"", '""'}


def wait_for_consul_api() -> bool:
    log_info("Waiting for Consul HTTP API and leader election")
    for _ in range(60):
        if consul_leader_elected():
            return True
        active = run_root(["systemctl", "is-active", "--quiet", "consul"], check=False)
        if active.returncode != 0:
            log_error("Consul service is not active")
            if command_exists("journalctl"):
                run_root(["journalctl", "-u", "consul", "-n", "80", "--no-pager"], check=False)
            return False
        time.sleep(2)
    if command_exists("journalctl"):
        run_root(["journalctl", "-u", "consul", "-n", "80", "--no-pager"], check=False)
    return False


def restart_consul_service() -> None:
    run_root(["systemctl", "restart", "consul"])
    time.sleep(2)
    if run_root(["systemctl", "is-active", "--quiet", "consul"], check=False).returncode != 0:
        if command_exists("journalctl"):
            run_root(["journalctl", "-u", "consul", "-n", "80", "--no-pager"], check=False)
        raise CLIError("Consul service failed to start")
    if not wait_for_consul_api():
        raise CLIError("Timed out waiting for Consul HTTP API")


def restore_managed_file(target: Path, backup: Path | None) -> None:
    if backup and backup.exists():
        run_root(["install", "-m", "0640", "-o", CONSUL_USER, "-g", CONSUL_GROUP, str(backup), str(target)])
    else:
        run_root(["rm", "-f", "--", str(target)])


def commit_managed_file(target: Path, content: str) -> None:
    require_config_environment()
    ensure_managed_or_absent(target)
    backup: Path | None = None
    if target.exists():
        backup_handle = tempfile.NamedTemporaryFile(delete=False)
        backup_handle.close()
        backup = Path(backup_handle.name)
        run_root(["cp", str(target), str(backup)])
        try:
            if target.read_text(encoding="utf-8") == content:
                backup.unlink(missing_ok=True)
                log_success(f"No config change: {target}")
                return
        except OSError:
            pass
    try:
        install_text(target, content, mode="0640", owner=CONSUL_USER, group=CONSUL_GROUP)
        validate_consul_config()
        restart_consul_service()
    except Exception as exc:
        restore_managed_file(target, backup)
        if backup:
            backup.unlink(missing_ok=True)
        raise CLIError(f"Consul config apply failed, rollback completed: {exc}") from exc
    if backup:
        backup.unlink(missing_ok=True)
    log_success(f"Config applied: {target}")


def remove_managed_file(target: Path) -> None:
    require_config_environment()
    if not target.exists():
        log_success(f"Config already absent: {target}")
        return
    ensure_managed_or_absent(target)
    backup_handle = tempfile.NamedTemporaryFile(delete=False)
    backup_handle.close()
    backup = Path(backup_handle.name)
    run_root(["cp", str(target), str(backup)])
    try:
        run_root(["rm", "-f", "--", str(target)])
        validate_consul_config()
        restart_consul_service()
    except Exception as exc:
        run_root(["install", "-m", "0640", "-o", CONSUL_USER, "-g", CONSUL_GROUP, str(backup), str(target)])
        raise CLIError(f"Consul config removal failed, rollback completed: {exc}") from exc
    finally:
        backup.unlink(missing_ok=True)
    log_success(f"Config removed: {target}")


def managed_config(body: str) -> str:
    return f"{MANAGED_MARKER}\n{body.rstrip()}\n"


def cmd_ui_enable(args: argparse.Namespace) -> int:
    lines = ["ui_config {", "  enabled = true"]
    if args.metrics_provider:
        lines.append(f"  metrics_provider = {hcl_string(args.metrics_provider)}")
    if args.metrics_proxy_base_url:
        lines.extend(
            [
                "",
                "  metrics_proxy {",
                f"    base_url = {hcl_string(args.metrics_proxy_base_url)}",
                "  }",
            ]
        )
    if args.dashboard_url_template:
        lines.append(f"  dashboard_url_templates = {{ service = {hcl_string(args.dashboard_url_template)} }}")
    lines.append("}")
    commit_managed_file(UI_CONFIG, managed_config("\n".join(lines)))
    return 0


def cmd_ui_disable(_: argparse.Namespace) -> int:
    commit_managed_file(UI_CONFIG, managed_config("ui_config {\n  enabled = false\n}"))
    return 0


def cmd_tls_enable(args: argparse.Namespace) -> int:
    body = "\n".join(
        [
            "tls {",
            "  defaults {",
            f"    ca_file         = {hcl_string(args.ca_file)}",
            f"    cert_file       = {hcl_string(args.cert_file)}",
            f"    key_file        = {hcl_string(args.key_file)}",
            f"    verify_incoming = {hcl_bool(args.verify_incoming)}",
            f"    verify_outgoing = {hcl_bool(args.verify_outgoing)}",
            "  }",
            "",
            "  internal_rpc {",
            f"    verify_server_hostname = {hcl_bool(args.verify_server_hostname)}",
            "  }",
            "}",
            "",
            f"auto_encrypt {{\n  allow_tls = {hcl_bool(args.auto_encrypt)}\n}}",
        ]
    )
    commit_managed_file(TLS_CONFIG, managed_config(body))
    return 0


def cmd_telemetry_enable(args: argparse.Namespace) -> int:
    body = "\n".join(
        [
            "telemetry {",
            f"  prometheus_retention_time = {hcl_string(args.retention)}",
            f"  disable_hostname          = {hcl_bool(args.disable_hostname)}",
            "}",
        ]
    )
    commit_managed_file(TELEMETRY_CONFIG, managed_config(body))
    return 0


DNS_POLICY_RULES = """# Managed by consul-manager
# Read-only access for the DNS interface. DNS queries carry no token, so Consul
# answers them with acl.tokens.dns; without it every lookup is anonymous and
# returns NXDOMAIN under default_policy = deny.
node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "read"
}

query_prefix "" {
  policy = "read"
}
"""


def configured_dns_token() -> str:
    """The DNS token from the managed fragment. Never print the return value."""
    text = read_config_text(DNS_TOKEN_CONFIG)
    if not text:
        return ""
    return hcl_text_value(hcl_block_body(hcl_block_body(text, "acl"), "tokens"), "dns")


def write_dns_policy(address: str, token: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".hcl") as handle:
        handle.write(DNS_POLICY_RULES)
        rules_path = handle.name
    try:
        exists = consul_cmd(address, token, ["acl", "policy", "read", "-name", DNS_POLICY_NAME],
                            capture=True, check=False).returncode == 0
        action = "update" if exists else "create"
        log_info(f"Consul ACL policy {action}: {DNS_POLICY_NAME}")
        consul_cmd(address, token, ["acl", "policy", action, "-name", DNS_POLICY_NAME,
                                    "-description", "DNS read access managed by consul-manager",
                                    "-rules", f"@{rules_path}"], capture=True)
    finally:
        Path(rules_path).unlink(missing_ok=True)


def dns_token_works(address: str, token: str) -> bool:
    """A DNS token that cannot list services resolves nothing."""
    if not token:
        return False
    result = consul_cmd(address, token, ["catalog", "services"], capture=True, check=False)
    return result.returncode == 0


def create_dns_token(address: str, management_token: str, *, force: bool = False) -> int:
    if not force and dns_token_works(address, configured_dns_token()):
        log_success(f"DNS token already configured: {DNS_TOKEN_CONFIG}")
        return 0
    write_dns_policy(address, management_token)
    log_info("Creating Consul ACL token for the DNS interface")
    result = consul_cmd(address, management_token,
                        ["acl", "token", "create", "-description", DNS_TOKEN_DESCRIPTION,
                         "-policy-name", DNS_POLICY_NAME, "-format", "json"], capture=True)
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise CLIError("Failed to parse the Consul token create output") from exc
    secret_id = payload.get("SecretID", "")
    if not secret_id:
        raise CLIError("Consul did not return a SecretID for the DNS token")
    body = "acl {\n  tokens {\n    dns = " + hcl_string(secret_id) + "\n  }\n}"
    commit_managed_file(DNS_TOKEN_CONFIG, managed_config(body))
    log_success(f"DNS token configured: {DNS_TOKEN_CONFIG}")
    return 0


def cmd_acl_dns_token(args: argparse.Namespace) -> int:
    address = args.address or CONSUL_ADDR
    if not consul_installed():
        raise CLIError(f"No consul-manager install found on this host: {CONFIG_FILE}")
    if not acl_enabled():
        log_success("Consul ACL is disabled; DNS resolves without a token")
        return 0
    token = resolve_consul_token(args)
    if not token:
        raise CLIError(
            f"A Consul management token is required. Pass --token/--token-file, export CONSUL_HTTP_TOKEN, "
            f"or source {target_token_file()}"
        )
    return create_dns_token(address, token, force=args.force)


def cmd_dns_enable(args: argparse.Namespace) -> int:
    lines: list[str] = []
    if args.recursor:
        lines.append(f"recursors = {hcl_list(args.recursor)}")
        lines.append("")
    lines.extend(
        [
            "dns_config {",
            f"  allow_stale  = {hcl_bool(args.allow_stale)}",
            f"  enable_truncate = {hcl_bool(args.enable_truncate)}",
            f"  only_passing = {hcl_bool(args.only_passing)}",
            "}",
        ]
    )
    commit_managed_file(DNS_CONFIG, managed_config("\n".join(lines)))
    return 0


def read_acl_file_token(path: Path) -> str:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"(?m)^\s*export\s+CONSUL_HTTP_TOKEN=(\S+)\s*$", content)
    return match.group(1) if match else ""


def target_token_file() -> Path:
    target_user = os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    try:
        target_home = Path(pwd.getpwnam(target_user).pw_dir)
    except KeyError:
        target_home = Path.home()
    if not target_home.is_dir():
        target_home = Path.home()
    return target_home / "consul.acl"


def resolve_consul_token(args: argparse.Namespace) -> str:
    token = getattr(args, "token", "") or ""
    if token:
        return token
    token_file = getattr(args, "token_file", "") or ""
    if token_file:
        path = Path(token_file)
        if not path.is_file():
            raise CLIError(f"Consul token file not found: {path}")
        value = path.read_text(encoding="utf-8").strip()
        if not value:
            raise CLIError(f"Consul token file is empty: {path}")
        return read_acl_file_token(path) or value.splitlines()[0].strip()
    env_token = os.environ.get("CONSUL_HTTP_TOKEN", "")
    if env_token:
        return env_token
    return read_acl_file_token(target_token_file())


def consul_env(address: str, token: str) -> dict[str, str]:
    env = os.environ.copy()
    env["CONSUL_HTTP_ADDR"] = address
    env["no_proxy"] = LOCAL_NO_PROXY
    env["NO_PROXY"] = LOCAL_NO_PROXY
    if token:
        env["CONSUL_HTTP_TOKEN"] = token
    else:
        env.pop("CONSUL_HTTP_TOKEN", None)
    return env


def consul_cmd(
    address: str,
    token: str,
    command: list[str],
    *,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    binary = str(BIN_PATH) if BIN_PATH.is_file() else "consul"
    return run([binary, *command], env=consul_env(address, token), capture=capture, check=check)


def doctor_check(status: str, message: str) -> None:
    labels = {
        "OK": (terminal_status_prefix(), COLOR_GREEN),
        "WARN": ("WARN", COLOR_YELLOW),
        "FAIL": ("FAIL", COLOR_RED),
        "INFO": ("INFO", ""),
    }
    label, color = labels.get(status, (status, ""))
    prefix = f"{label:<5}"
    print(f"{color_text(prefix, color) if color else prefix} {message}")


def doctor_info(message: str) -> None:
    """Report an effective setting. Informational only; never counted as a failure."""
    doctor_check("INFO", message)


def hcl_block_body(text: str, block: str) -> str:
    """Return the body of a `<block> {` ... `}` section from a Consul config."""
    match = re.search(rf"(?m)^\s*{re.escape(block)}\s*\{{", text)
    if not match:
        return ""
    start = text.index("{", match.start())
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:index]
    return ""


def hcl_text_value(text: str, key: str) -> str:
    match = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*(".*?"|true|false|\[[^\]]*\]|\S+)', text)
    return match.group(1).strip().strip('"') if match else ""


def read_config_text(path: Path) -> str:
    if not is_managed_file(path):
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def read_base_config_text() -> str:
    """The base config carries no managed marker; install owns it outright."""
    try:
        return CONFIG_FILE.read_text(encoding="utf-8")
    except OSError:
        return ""


def unset_label(value: str) -> str:
    return value if value else "<unset>"


def base_config_values() -> dict[str, str]:
    text = read_base_config_text()
    if not text:
        return {}
    ports = hcl_block_body(text, "ports")
    acl = hcl_block_body(text, "acl")
    return {
        "datacenter": hcl_text_value(text, "datacenter"),
        "data_dir": hcl_text_value(text, "data_dir"),
        "bind_addr": hcl_text_value(text, "bind_addr"),
        "client_addr": hcl_text_value(text, "client_addr"),
        "bootstrap_expect": hcl_text_value(text, "bootstrap_expect"),
        "log_level": hcl_text_value(text, "log_level"),
        # never surface the key itself, only whether gossip encryption is configured
        "gossip_encrypt": "true" if hcl_text_value(text, "encrypt") else "false",
        "http_port": hcl_text_value(ports, "http"),
        "grpc_port": hcl_text_value(ports, "grpc"),
        "dns_port": hcl_text_value(ports, "dns"),
        "connect": hcl_text_value(hcl_block_body(text, "connect"), "enabled"),
        "acl_enabled": hcl_text_value(acl, "enabled") or "false",
        "acl_default_policy": hcl_text_value(acl, "default_policy"),
    }


def tls_config_values() -> dict[str, str]:
    text = read_config_text(TLS_CONFIG)
    if not text:
        return {}
    defaults = hcl_block_body(text, "defaults")
    return {
        "ca_file": hcl_text_value(defaults, "ca_file"),
        "cert_file": hcl_text_value(defaults, "cert_file"),
        "key_file": hcl_text_value(defaults, "key_file"),
        "verify_incoming": hcl_text_value(defaults, "verify_incoming"),
        "verify_outgoing": hcl_text_value(defaults, "verify_outgoing"),
        "verify_server_hostname": hcl_text_value(hcl_block_body(text, "internal_rpc"), "verify_server_hostname"),
        "auto_encrypt": hcl_text_value(hcl_block_body(text, "auto_encrypt"), "allow_tls"),
    }


def ui_config_values() -> dict[str, str]:
    text = read_config_text(UI_CONFIG)
    if not text:
        return {}
    body = hcl_block_body(text, "ui_config")
    return {
        "enabled": hcl_text_value(body, "enabled"),
        "metrics_provider": hcl_text_value(body, "metrics_provider"),
        "metrics_proxy": hcl_text_value(hcl_block_body(body, "metrics_proxy"), "base_url"),
    }


def telemetry_config_values() -> dict[str, str]:
    text = read_config_text(TELEMETRY_CONFIG)
    if not text:
        return {}
    return {key: hcl_text_value(text, key) for key in ("prometheus_retention_time", "disable_hostname")}


def dns_config_values() -> dict[str, str]:
    text = read_config_text(DNS_CONFIG)
    if not text:
        return {}
    body = hcl_block_body(text, "dns_config")
    return {
        "recursors": hcl_text_value(text, "recursors"),
        "allow_stale": hcl_text_value(body, "allow_stale"),
        "enable_truncate": hcl_text_value(body, "enable_truncate"),
        "only_passing": hcl_text_value(body, "only_passing"),
    }


def hcl_file_string_value(path: Path, key: str) -> str:
    if not path.is_file():
        return ""
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"', path.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1) if match else ""


def doctor_config_file(path: Path, label: str) -> int:
    if not path.exists():
        doctor_check("WARN", f"{label} config absent: {path}")
        return 2
    if is_managed_file(path):
        doctor_check("OK", f"{label} config managed: {path}")
        return 0
    doctor_check("FAIL", f"{label} config exists but is not managed: {path}")
    return 1


def read_install_metadata() -> dict[str, Any]:
    try:
        data = json.loads(INSTALL_METADATA_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def acl_enabled_from_config() -> bool | None:
    if not CONFIG_FILE.is_file():
        return None
    try:
        content = CONFIG_FILE.read_text(encoding="utf-8")
    except OSError:
        return None
    if not re.search(r"(?m)^\s*acl\s*\{", content):
        return False
    match = re.search(r"(?ms)^\s*acl\s*\{.*?^\s*\}", content)
    block = match.group(0) if match else ""
    enabled = re.search(r"(?m)^\s*enabled\s*=\s*(true|false)", block)
    return enabled.group(1) == "true" if enabled else False


def consul_installed() -> bool:
    return CONFIG_FILE.is_file() or BIN_PATH.is_file() or bool(read_install_metadata())


def acl_state() -> bool | None:
    """True or False when the ACL mode is known, None when Consul is not installed here."""
    from_config = acl_enabled_from_config()
    if from_config is not None:
        return from_config
    value = read_install_metadata().get("acl_enabled")
    return value if isinstance(value, bool) else None


def acl_enabled() -> bool:
    state = acl_state()
    return True if state is None else state


def doctor_consul_config() -> int:
    if not BIN_PATH.exists():
        doctor_check("FAIL", f"Consul binary not found: {BIN_PATH}")
        return 1
    if not CONFIG_DIR.is_dir():
        doctor_check("FAIL", f"Consul config directory missing: {CONFIG_DIR}")
        return 1
    result = run([str(BIN_PATH), "validate", str(CONFIG_DIR)], check=False, capture=True)
    if result.returncode == 0:
        doctor_check("OK", f"Consul config validates: {CONFIG_DIR}")
        return 0
    doctor_check("FAIL", f"Consul config validation failed: {CONFIG_DIR}")
    return 1


def doctor_dns_token(address: str) -> int:
    """DNS answers with acl.tokens.dns, so a missing one breaks every lookup.

    The service registers fine, the HTTP API finds it, and dig returns NXDOMAIN.
    """
    state = acl_state()
    if state is None:
        doctor_info("DNS token: ACL mode unknown, skipping")
        return 0
    if not state:
        doctor_info("DNS token: not needed while ACL is disabled")
        return 0
    dns_token = configured_dns_token()
    if not dns_token:
        doctor_check("FAIL", f"ACL is enabled but no DNS token is configured: {DNS_TOKEN_CONFIG}")
        doctor_check("INFO", "Every DNS lookup is anonymous, so <service>.service.consul returns NXDOMAIN")
        doctor_check("INFO", f"Fix: {CONSUL_MANAGER_CMD} acl dns-token")
        return 1
    if dns_token_works(address, dns_token):
        doctor_check("OK", f"DNS token configured and able to read the catalog: {DNS_TOKEN_CONFIG}")
        return 0
    doctor_check("FAIL", "The configured DNS token cannot read the catalog; DNS lookups will return NXDOMAIN")
    doctor_check("INFO", f"Recreate it with: {CONSUL_MANAGER_CMD} acl dns-token --force")
    return 1


def doctor_acl(address: str, token: str) -> int:
    state = acl_state()
    if state is None:
        doctor_check("WARN", f"Consul config not found: {CONFIG_FILE}; ACL mode unknown")
        return 0
    if not state:
        doctor_check("WARN", "Consul ACL is disabled; anyone reaching the API has full access")
        return 0
    doctor_check("OK", "Consul ACL is enabled")
    failures = 0
    if not token:
        doctor_check("WARN", f"No Consul token available; pass --token/--token-file or source {target_token_file()}")
        return failures
    result = consul_cmd(address, token, ["acl", "token", "read", "-self"], capture=True, check=False)
    if result.returncode == 0:
        doctor_check("OK", "Consul token is valid")
    else:
        doctor_check("FAIL", "Consul token is not accepted by the cluster")
        failures += 1
    return failures


def doctor_nomad_integration(address: str, token: str) -> int:
    if not acl_enabled():
        doctor_check("WARN", "ACL disabled; Nomad needs no JWT auth method or agent token")
        return 0
    failures = 0
    if not token:
        doctor_check("WARN", "Skipping Nomad integration checks without a Consul token")
        return failures
    result = consul_cmd(address, token, ["acl", "auth-method", "read", "-name", NOMAD_AUTH_METHOD], capture=True, check=False)
    if result.returncode == 0:
        doctor_check("OK", f"Consul JWT auth method exists: {NOMAD_AUTH_METHOD}")
    else:
        doctor_check("FAIL", f"Consul JWT auth method missing: {NOMAD_AUTH_METHOD}. Run {CONSUL_MANAGER_CMD} nomad-jwt apply")
        failures += 1
    if NOMAD_AGENT_TOKEN_FILE.is_file():
        doctor_check("OK", f"Nomad agent token file present: {NOMAD_AGENT_TOKEN_FILE}")
    else:
        doctor_check("WARN", f"Nomad agent token file absent: {NOMAD_AGENT_TOKEN_FILE}. Run {CONSUL_MANAGER_CMD} nomad-jwt apply")
    return failures


def doctor_node_runtime() -> int:
    """Version, data directory and the tool copy this node runs from."""
    failures = 0
    recorded = read_installed_consul_version()
    doctor_info(f"recorded version = {recorded}")
    doctor_info(f"tool revision    = {read_installed_tool_revision()}")
    actual = installed_binary_version()
    if actual:
        doctor_info(f"binary version   = {actual}")
        if recorded not in {"unknown", actual}:
            doctor_check("WARN", f"Binary version {actual} differs from recorded {recorded}; "
                                 f"run {CONSUL_MANAGER_CMD} upgrade to install a known release")
    if CONSUL_AGENT_DATA_DIR.is_dir():
        doctor_check("OK", f"Data directory exists: {CONSUL_AGENT_DATA_DIR}")
    else:
        doctor_check("FAIL", f"Data directory missing: {CONSUL_AGENT_DATA_DIR}")
        failures += 1
    if TOOL_DIR.is_dir():
        doctor_check("OK", f"Tool copy present: {TOOL_DIR}")
    else:
        doctor_check("WARN", f"Tool copy missing: {TOOL_DIR}; this node was not installed by consul-manager")
    return failures


def doctor_base_configuration() -> int:
    values = base_config_values()
    if not values:
        doctor_check("FAIL", f"Base config not readable: {CONFIG_FILE}")
        return 1
    failures = 0
    doctor_info(f"datacenter   = {unset_label(values['datacenter'])}")
    doctor_info(f"bind_addr    = {unset_label(values['bind_addr'])}")
    doctor_info(f"client_addr  = {unset_label(values['client_addr'])}")
    doctor_info(f"ports        = http {unset_label(values['http_port'])}, "
                f"grpc {unset_label(values['grpc_port'])}, dns {unset_label(values['dns_port'])}")
    doctor_info(f"connect      = {values['connect'] or 'false'}")
    doctor_info(f"gossip encr. = {values['gossip_encrypt']}")
    doctor_info(f"acl          = {values['acl_enabled']}"
                + (f" (default_policy {unset_label(values['acl_default_policy'])})" if values["acl_enabled"] == "true" else ""))
    if values["connect"] == "true" and values["grpc_port"] in {"-1", ""}:
        doctor_check("FAIL", "Connect is enabled but the gRPC port is disabled; service mesh will not work")
        failures += 1
    if values["acl_enabled"] == "true" and values["acl_default_policy"] == "allow":
        doctor_check("WARN", "ACL default_policy is allow; tokens are issued but nothing is denied")
    # the HTTP API and the UI listen on client_addr; bind_addr is cluster traffic
    acl_off = values["acl_enabled"] != "true"
    if values["client_addr"] not in LOCAL_ADDRESSES and acl_off:
        doctor_check("FAIL", f"HTTP API and UI listen on {values['client_addr']} with ACL disabled")
        doctor_check("INFO", "Anyone who can reach the port can read and write the KV store and the catalog")
        failures += 1
    if values["bind_addr"] not in LOCAL_ADDRESSES and acl_off:
        doctor_check("WARN", f"Cluster traffic binds {values['bind_addr']} with ACL disabled")
    return failures


def doctor_node_configuration() -> int:
    failures = 0
    ui = ui_config_values()
    if ui:
        doctor_info(f"UI: enabled {unset_label(ui['enabled'])}, "
                    f"metrics_provider {unset_label(ui['metrics_provider'])}")
    else:
        doctor_info("UI: not configured")
    telemetry = telemetry_config_values()
    if telemetry:
        doctor_info(f"Telemetry: prometheus_retention_time {unset_label(telemetry['prometheus_retention_time'])}")
    else:
        doctor_info("Telemetry: not configured")
    dns = dns_config_values()
    if dns:
        doctor_info(f"DNS: recursors {unset_label(dns['recursors'])}, only_passing {unset_label(dns['only_passing'])}")
    else:
        doctor_info("DNS: not configured")
    tls = tls_config_values()
    if tls:
        doctor_info(f"TLS: verify_incoming {unset_label(tls['verify_incoming'])}, "
                    f"verify_outgoing {unset_label(tls['verify_outgoing'])}")
        for key in ("ca_file", "cert_file", "key_file"):
            value = tls.get(key, "")
            if not value:
                continue
            if Path(value).is_file():
                doctor_check("OK", f"TLS {key} exists: {value}")
            else:
                doctor_check("FAIL", f"TLS {key} missing: {value}; consul.service will not start")
                failures += 1
    else:
        doctor_info("TLS: not configured")
    return failures


def cmd_doctor(args: argparse.Namespace) -> int:
    failures = 0
    address = args.address or CONSUL_ADDR
    token = resolve_consul_token(args)
    doctor_check("OK" if sys.platform.startswith("linux") else "FAIL", f"platform: {sys.platform}")
    if not sys.platform.startswith("linux"):
        failures += 1
    if command_exists("systemctl"):
        doctor_check("OK", f"systemctl found: {shutil.which('systemctl')}")
        if run(["systemctl", "is-active", "--quiet", "consul"], check=False).returncode == 0:
            doctor_check("OK", "consul.service is active")
        else:
            doctor_check("FAIL", "consul.service is not active")
            failures += 1
    else:
        doctor_check("FAIL", "systemctl not found")
        failures += 1
    if BIN_PATH.is_file():
        doctor_check("OK", f"Consul binary found: {BIN_PATH}")
    else:
        doctor_check("FAIL", f"Consul binary missing: {BIN_PATH}")
        failures += 1
    if BIN_ENTRY.exists() or BIN_ENTRY.is_symlink():
        doctor_check("OK", f"Consul entry exists: {BIN_ENTRY}")
    else:
        doctor_check("WARN", f"Consul entry missing: {BIN_ENTRY}")
    if SYSTEMD_SERVICE.is_file():
        doctor_check("OK", f"systemd service file found: {SYSTEMD_SERVICE}")
    else:
        doctor_check("FAIL", f"systemd service file missing: {SYSTEMD_SERVICE}")
        failures += 1
    failures += doctor_consul_config()
    code = http_status(f"{address.rstrip('/')}/v1/status/leader")
    if code == 200:
        doctor_check("OK", f"Consul HTTP API reachable: {address}")
    else:
        doctor_check("FAIL", f"Consul HTTP API not reachable: {address} ({code})")
        failures += 1
    if consul_leader_elected():
        doctor_check("OK", "Consul has an elected leader")
    else:
        doctor_check("FAIL", "Consul has no elected leader")
        failures += 1
    print("\nNode runtime:")
    failures += doctor_node_runtime()
    print("\nBase configuration:")
    failures += doctor_base_configuration()
    print("\nManaged config fragments:")
    for path, label in ((TLS_CONFIG, "TLS"), (UI_CONFIG, "UI"), (TELEMETRY_CONFIG, "Telemetry"),
                        (DNS_CONFIG, "DNS"), (DNS_TOKEN_CONFIG, "DNS token")):
        if doctor_config_file(path, label) == 1:
            failures += 1
    failures += doctor_node_configuration()
    print("\nACL checks:")
    failures += doctor_acl(address, token)
    failures += doctor_dns_token(address)
    if args.integrations or NOMAD_AGENT_TOKEN_FILE.is_file():
        print("\nNomad integration checks:")
        failures += doctor_nomad_integration(address, token)
    if failures == 0:
        print("\nAll checks passed.")
    return 0 if failures == 0 else 1


def status_line(key: str, value: str) -> None:
    print(f"  {key:<22} {value}")


def cmd_status(args: argparse.Namespace) -> int:
    """Show what is configured. doctor answers whether it is healthy."""
    address = args.address or CONSUL_ADDR
    token = resolve_consul_token(args)
    base = base_config_values()

    print("Install:")
    status_line("recorded version", read_installed_consul_version())
    if BIN_PATH.is_file():
        status_line("binary version", installed_binary_version() or "unknown")
    status_line("binary", str(BIN_PATH) if BIN_PATH.is_file() else "<not installed>")
    linked = linked_binary_path(BIN_PATH)
    if linked:
        status_line("binary release", str(linked))
    kept = [item.name for item in kept_binary_versions(BINARY_VERSION_DIR, "consul")]
    if kept:
        status_line("kept releases", ", ".join(kept))
    status_line("config dir", str(CONFIG_DIR))
    status_line("data dir", str(CONSUL_AGENT_DATA_DIR))
    status_line("tool dir", str(TOOL_DIR) if TOOL_DIR.is_dir() else "<not installed>")
    status_line("tool revision", read_installed_tool_revision())
    if command_exists("systemctl"):
        status_line("service", (run(["systemctl", "is-active", "consul"], check=False, capture=True).stdout or "").strip() or "unknown")
    status_line("api", f"{address} ({http_status(f'{address.rstrip(chr(47))}/v1/status/leader')})")
    status_line("acl token file", str(target_token_file()) if target_token_file().is_file() else "<absent>")

    print("\nBase configuration:")
    if not base:
        print(f"  <not readable: {CONFIG_FILE}>")
    else:
        status_line("datacenter", unset_label(base["datacenter"]))
        status_line("bind / client", f"{unset_label(base['bind_addr'])} / {unset_label(base['client_addr'])}")
        status_line("ports", f"http {unset_label(base['http_port'])}, grpc {unset_label(base['grpc_port'])}, "
                             f"dns {unset_label(base['dns_port'])}")
        status_line("connect", base["connect"] or "false")
        status_line("gossip encryption", base["gossip_encrypt"])
        status_line("acl", base["acl_enabled"] + (f" (default_policy {base['acl_default_policy']})"
                                                  if base["acl_enabled"] == "true" else ""))

    print("\nManaged configuration:")
    ui = ui_config_values()
    status_line("ui", f"enabled {unset_label(ui['enabled'])}, metrics {unset_label(ui['metrics_provider'])}"
                if ui else "<not configured>")
    tls = tls_config_values()
    status_line("tls", f"verify_incoming {unset_label(tls['verify_incoming'])}, "
                       f"ca {unset_label(tls['ca_file'])}" if tls else "<not configured>")
    telemetry = telemetry_config_values()
    status_line("telemetry", f"retention {unset_label(telemetry['prometheus_retention_time'])}"
                if telemetry else "<not configured>")
    dns = dns_config_values()
    status_line("dns", f"recursors {unset_label(dns['recursors'])}, only_passing {unset_label(dns['only_passing'])}"
                if dns else "<not configured>")

    status_line("dns token", "configured" if configured_dns_token() else "<absent>")

    print("\nNomad integration:")
    if not acl_enabled():
        status_line("workload identity", "not needed (ACL disabled)")
    else:
        status_line("agent token file", str(NOMAD_AGENT_TOKEN_FILE) if NOMAD_AGENT_TOKEN_FILE.is_file() else "<absent>")
        status_line("jwt auth method", NOMAD_AUTH_METHOD)

    if BIN_PATH.is_file() or command_exists("consul"):
        print("\nConsul members:")
        consul_cmd(address, token, ["members"], check=False)
        print("\nRaft peers:")
        consul_cmd(address, token, ["operator", "raft", "list-peers"], check=False)
    else:
        print(f"\nConsul binary not found: {BIN_PATH}; skipping members and raft peers")
    print(f"\nRun '{CONSUL_MANAGER_CMD} doctor' to check whether any of this is broken.")
    return 0


def create_install_tmpdir(prefix: str) -> Path:
    parent = Path(os.environ.get("TMPDIR", "/var/tmp"))
    if not parent.is_dir() or not os.access(parent, os.W_OK):
        raise CLIError(f"Temporary directory parent is not writable: {parent}. Set TMPDIR to a writable directory with enough space")
    path = Path(tempfile.mkdtemp(prefix=f"{prefix}.", dir=str(parent)))
    log_info(f"Using install temporary directory: {path}")
    return path


def verify_checksum(zip_file: Path, sums_file: Path) -> None:
    expected = ""
    for raw in sums_file.read_text(encoding="utf-8").splitlines():
        parts = raw.split()
        if len(parts) >= 2 and parts[1] == zip_file.name:
            expected = parts[0]
            break
    if not expected:
        raise CLIError(f"Checksum entry not found for {zip_file.name}")
    actual = sha256_file(zip_file)
    if expected != actual:
        raise CLIError(f"Checksum mismatch for {zip_file.name}")
    log_success(f"Checksum verified: {zip_file.name}")


def download_consul(version: str, arch: str, tmpdir: Path) -> None:
    zip_name = f"consul_{version}_linux_{arch}.zip"
    sums_name = f"consul_{version}_SHA256SUMS"
    base_url = f"https://releases.hashicorp.com/consul/{version}"
    zip_file = tmpdir / zip_name
    sums_file = tmpdir / sums_name
    log_info(f"Downloading Consul {version} for linux_{arch}")
    download_file(f"{base_url}/{zip_name}", zip_file, timeout=300)
    download_file(f"{base_url}/{sums_name}", sums_file, timeout=300)
    verify_checksum(zip_file, sums_file)
    extract_dir = tmpdir / "extract"
    extract_dir.mkdir(parents=True, exist_ok=True)
    extract_zip(zip_file, extract_dir)
    if not (extract_dir / "consul").is_file():
        raise CLIError("Consul binary not found in archive")


def ensure_consul_user() -> None:
    if run(["id", CONSUL_USER], check=False, capture=True).returncode == 0:
        return
    log_info(f"Creating system user: {CONSUL_USER}")
    run_root(["useradd", "--system", "--home", str(CONSUL_ROOT_DIR), "--shell", "/bin/false", CONSUL_USER])


def install_directories() -> None:
    log_info("Creating Consul directories")
    for path, mode, owner, group in [
        (CONSUL_ROOT_DIR, "0755", "root", "root"),
        (BIN_DIR, "0755", "root", "root"),
        (CONSUL_ROOT_DIR / "etc", "0755", "root", "root"),
        (CONSUL_ROOT_DIR / "data", "0755", "root", "root"),
        (CONSUL_ROOT_DIR / "lib", "0755", "root", "root"),
        (CONSUL_ROOT_DIR / "log", "0750", "root", "root"),
        (CONFIG_DIR, "0750", CONSUL_USER, CONSUL_GROUP),
        (DATA_DIR, "0750", CONSUL_USER, CONSUL_GROUP),
        (CONSUL_AGENT_DATA_DIR, "0750", CONSUL_USER, CONSUL_GROUP),
    ]:
        run_root(["install", "-d", "-m", mode, "-o", owner, "-g", group, str(path)])


def stage_binary(tmpdir: Path, version: str) -> Path:
    """Put one release in place under its version and check it runs.

    The release is checked here, before anything points at it, so a bad archive
    fails while the running binary is still the one in use.
    """
    target = versioned_binary_path(BINARY_VERSION_DIR, "consul", version)
    log_info(f"Installing binary: {target}")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BINARY_VERSION_DIR)])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(tmpdir / "extract" / "consul"), str(target)])
    reported = parse_binary_version(run([str(target), "version"], capture=True, check=False).stdout or "")
    if reported != version:
        raise CLIError(f"Installed binary reports version {reported or 'unknown'}, expected {version}")
    return target


def install_binary(tmpdir: Path, version: str) -> None:
    target = stage_binary(tmpdir, version)
    atomic_symlink(target, BIN_PATH)
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_ENTRY.parent)])
    run_root(["ln", "-sfn", str(BIN_PATH), str(BIN_ENTRY)])
    log_success(f"Consul binary entry installed: {BIN_ENTRY}")
    run([str(BIN_PATH), "version"])


def write_systemd_service() -> None:
    content = f"""[Unit]
Description=Consul
Documentation=https://developer.hashicorp.com/consul/docs
Wants=network-online.target
After=network-online.target
ConditionFileNotEmpty={CONFIG_FILE}

[Service]
User={CONSUL_USER}
Group={CONSUL_GROUP}
ExecStart={BIN_PATH} agent -config-dir={CONFIG_DIR}
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
LimitNOFILE=65536
Restart=on-failure
RestartSec=2
TasksMax=infinity

[Install]
WantedBy=multi-user.target
"""
    log_info(f"Installing systemd service: {SYSTEMD_SERVICE}")
    install_text(SYSTEMD_SERVICE, content, mode="0644")


def read_existing_encrypt_key() -> str:
    return hcl_file_string_value(CONFIG_FILE, "encrypt")


def generate_gossip_key() -> str:
    """Use the installed binary; install_binary has already run by this point.

    The extracted copy under the temporary directory is not executable, because
    zipfile does not preserve the mode recorded in the archive.
    """
    result = run([str(BIN_PATH), "keygen"], capture=True)
    key = (result.stdout or "").strip()
    if not key:
        raise CLIError("Failed to generate a Consul gossip encryption key")
    return key


def write_consul_config(args: argparse.Namespace, encrypt_key: str) -> None:
    lines = [
        f"datacenter = {hcl_string(args.datacenter)}",
        f'data_dir   = {hcl_string(str(CONSUL_AGENT_DATA_DIR))}',
        f"log_level  = {hcl_string(args.log_level)}",
        "",
        "server           = true",
        "bootstrap_expect = 1",
        "",
        f"bind_addr   = {hcl_string(args.bind)}",
        f"client_addr = {hcl_string(args.client)}",
    ]
    if encrypt_key:
        lines.append(f"encrypt     = {hcl_string(encrypt_key)}")
    lines.extend(
        [
            "",
            "ports {",
            f"  http = {args.http_port}",
            f"  grpc = {args.grpc_port if args.connect else -1}",
            f"  dns  = {args.dns_port}",
            "}",
            "",
            "connect {",
            f"  enabled = {hcl_bool(args.connect)}",
            "}",
        ]
    )
    if args.acl:
        lines.extend(
            [
                "",
                "acl {",
                "  enabled                  = true",
                f"  default_policy           = {hcl_string(args.acl_default_policy)}",
                "  down_policy              = \"extend-cache\"",
                "  enable_token_persistence = true",
                "}",
            ]
        )
    log_info(f"Installing Consul config: {CONFIG_FILE}")
    install_text(CONFIG_FILE, "\n".join(lines) + "\n", mode="0640", owner=CONSUL_USER, group=CONSUL_GROUP)


def write_default_managed_configs(args: argparse.Namespace) -> None:
    log_info("Installing default managed configs")
    install_text(
        UI_CONFIG,
        managed_config(f"ui_config {{\n  enabled = {hcl_bool(args.ui)}\n}}"),
        mode="0640",
        owner=CONSUL_USER,
        group=CONSUL_GROUP,
    )
    install_text(
        TELEMETRY_CONFIG,
        managed_config('telemetry {\n  prometheus_retention_time = "24h"\n  disable_hostname          = true\n}'),
        mode="0640",
        owner=CONSUL_USER,
        group=CONSUL_GROUP,
    )


def write_tool_manifest() -> None:
    path = TOOL_DIR / "consul-manager"
    lines = [f"{sha256_file(path)}  consul-manager"] if path.is_file() else []
    install_text(TOOL_MANIFEST_FILE, "\n".join(lines) + "\n", mode="0644")


def source_tool_revision(script_dir: Path) -> tuple[str, bool]:
    """The git revision of the source tree the snapshot is taken from.

    Returns ("unknown", False) when git is unavailable or the source is not a
    checkout. Dirtiness is scoped to the tool directory, so unrelated edits
    elsewhere in the repository do not mark the snapshot as modified.
    """
    if not command_exists("git"):
        return "unknown", False
    revision = run(["git", "-C", str(script_dir), "rev-parse", "--short", "HEAD"],
                   capture=True, check=False)
    if revision.returncode != 0:
        return "unknown", False
    # the pathspec is resolved relative to -C, so it must be "." and not script_dir
    status = run(["git", "-C", str(script_dir), "status", "--porcelain", "--", "."],
                 capture=True, check=False)
    dirty = status.returncode == 0 and bool((status.stdout or "").strip())
    return (revision.stdout or "").strip() or "unknown", dirty


def read_installed_tool_revision() -> str:
    metadata = read_install_metadata()
    revision = metadata.get("tool_revision")
    if isinstance(revision, str) and revision.strip():
        return revision.strip() + ("-dirty" if metadata.get("tool_revision_dirty") else "")
    values: dict[str, str] = {}
    try:
        for line in TOOL_VERSION_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value.strip()
    except OSError:
        return "unknown"
    revision = values.get("tool_revision", "")
    if not revision:
        return "unknown"
    return revision + ("-dirty" if values.get("tool_revision_dirty") == "true" else "")


def write_install_metadata(version: str, args: argparse.Namespace, revision: str = "unknown", dirty: bool = False) -> None:
    metadata = {
        "tool": "consul-manager",
        "root_dir": str(CONSUL_ROOT_DIR),
        "tool_dir": str(TOOL_DIR),
        "manager_path": str(TOOL_PATH),
        "manager_entry": str(TOOL_ENTRY),
        "consul_binary": str(BIN_PATH),
        "consul_entry": str(BIN_ENTRY),
        "config_dir": str(CONFIG_DIR),
        "config_file": str(CONFIG_FILE),
        "data_dir": str(DATA_DIR),
        "agent_data_dir": str(CONSUL_AGENT_DATA_DIR),
        "service": str(SYSTEMD_SERVICE),
        "consul_version": version,
        "datacenter": args.datacenter,
        "bind_addr": args.bind,
        "client_addr": args.client,
        "http_port": args.http_port,
        "grpc_port": args.grpc_port if args.connect else -1,
        "dns_port": args.dns_port,
        "acl_enabled": bool(args.acl),
        "acl_default_policy": args.acl_default_policy if args.acl else "",
        "connect_enabled": bool(args.connect),
        "gossip_encrypt": bool(args.gossip_encrypt),
        "installed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tool_revision": revision,
        "tool_revision_dirty": dirty,
        "manifest_file": str(TOOL_MANIFEST_FILE),
        "manifest_sha256": sha256_file(TOOL_MANIFEST_FILE) if TOOL_MANIFEST_FILE.is_file() else "",
        "audit_log": str(AUDIT_LOG_FILE),
    }
    run_root(["install", "-d", "-m", "0750", "-o", "root", "-g", "root", str(TOOL_STATE_DIR)])
    install_text(INSTALL_METADATA_FILE, json.dumps(metadata, indent=2, sort_keys=True) + "\n", mode="0644")


def write_data_pointer() -> None:
    content = "\n".join(
        [
            "Managed by consul-manager",
            f"Install metadata: {INSTALL_METADATA_FILE}",
            f"Tool dir: {TOOL_DIR}",
            f"Config dir: {CONFIG_DIR}",
            f"Audit log: {AUDIT_LOG_FILE}",
            "",
        ]
    )
    install_text(DATA_POINTER_FILE, content, mode="0644", owner=CONSUL_USER, group=CONSUL_GROUP)


def install_tool_snapshot(version: str, script_dir: Path, args: argparse.Namespace) -> None:
    revision, dirty = source_tool_revision(script_dir)
    log_info(f"Installing Consul init tools snapshot: {TOOL_DIR} (source revision {revision}{'-dirty' if dirty else ''})")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_DIR)])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(script_dir / "consul-manager"), str(TOOL_DIR / "consul-manager")])
    safe_remove_path(TOOL_DIR / "consul_tools")
    run_root(["cp", "-R", str(script_dir / "consul_tools"), str(TOOL_DIR / "consul_tools")])
    run_root(["chown", "-R", "root:root", str(TOOL_DIR / "consul_tools")])
    install_text(
        TOOL_VERSION_FILE,
        f"tool=consul-manager\nconsul_version={version}\ntool_revision={revision}\n"
        f"tool_revision_dirty={str(dirty).lower()}\n"
        f"installed_at={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\nsource_dir={script_dir}\n",
        mode="0644",
    )
    write_tool_manifest()
    write_install_metadata(version, args, revision, dirty)
    write_data_pointer()
    run_root(["ln", "-sfn", str(TOOL_DIR / "consul-manager"), str(TOOL_PATH)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_ENTRY.parent)])
    run_root(["ln", "-sfn", str(TOOL_PATH), str(TOOL_ENTRY)])
    log_success(f"Consul manager entry installed: {TOOL_ENTRY}")


def read_installed_consul_version() -> str:
    metadata = read_install_metadata()
    version = metadata.get("consul_version")
    if isinstance(version, str) and version.strip():
        return version.strip()
    try:
        for line in TOOL_VERSION_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key == "consul_version" and value.strip():
                return value.strip()
    except OSError:
        pass
    return "unknown"


def metadata_install_args() -> argparse.Namespace:
    metadata = read_install_metadata()
    return argparse.Namespace(
        datacenter=metadata.get("datacenter", DEFAULT_DATACENTER),
        bind=metadata.get("bind_addr", DEFAULT_BIND_ADDR),
        client=metadata.get("client_addr", DEFAULT_CLIENT_ADDR),
        http_port=metadata.get("http_port", DEFAULT_HTTP_PORT),
        grpc_port=metadata.get("grpc_port", DEFAULT_GRPC_PORT),
        dns_port=metadata.get("dns_port", DEFAULT_DNS_PORT),
        acl=bool(metadata.get("acl_enabled", acl_enabled())),
        acl_default_policy=metadata.get("acl_default_policy", "deny") or "deny",
        connect=bool(metadata.get("connect_enabled", True)),
        gossip_encrypt=bool(metadata.get("gossip_encrypt", True)),
    )


def running_from_installed_copy(script_dir: Path) -> bool:
    """True when the running script is the copy that install placed under TOOL_DIR.

    Updating from there would copy the directory onto itself and change nothing.
    """
    try:
        resolved = Path(script_dir).resolve()
        tool_dir = TOOL_DIR.resolve()
    except OSError:
        return False
    return resolved == tool_dir or tool_dir in resolved.parents


def require_tool_source(script_dir: Path) -> None:
    missing: list[str] = []
    if not (script_dir / "consul-manager").is_file():
        missing.append(str(script_dir / "consul-manager"))
    if not (script_dir / "consul_tools").is_dir():
        missing.append(str(script_dir / "consul_tools"))
    if missing:
        raise CLIError(f"Tool source is incomplete: {', '.join(missing)}")


def cmd_tools_update(args: argparse.Namespace) -> int:
    require_linux()
    require_command("install")
    script_dir = current_script_dir(__file__).parent
    if running_from_installed_copy(script_dir):
        raise CLIError(
            f"Refusing to update from the installed copy at {TOOL_DIR}: it would copy onto itself "
            f"and change nothing. Run tools update from a source checkout instead"
        )
    require_tool_source(script_dir)
    version = normalize_version(args.consul_version) if args.consul_version else read_installed_consul_version()
    if version == "unknown":
        log_warn("Installed Consul version metadata not found; recording unknown")
    log_info(f"Updating Consul init tool files from: {script_dir}")
    install_tool_snapshot(version, script_dir, metadata_install_args())
    log_success("Consul init tools updated")
    return 0


def write_acl_token_file(output: str, address: str) -> str:
    token_file = target_token_file()
    match = re.search(r"(?im)^\s*SecretID\s*:\s*(\S+)", output)
    secret_id = match.group(1) if match else ""
    content = "# Generated by consul-manager\n# Source this file to use the bootstrapped ACL token.\n"
    content += f"export CONSUL_HTTP_ADDR={address}\n"
    if secret_id:
        content += f"export CONSUL_HTTP_TOKEN={secret_id}\n"
    content += "\n" + "\n".join(f"# {line}" for line in output.splitlines()) + "\n"
    atomic_write_text(token_file, content, mode=0o600)
    target_user = os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    if os.geteuid() == 0 and target_user != "root":
        try:
            user_info = pwd.getpwnam(target_user)
            os.chown(token_file, user_info.pw_uid, user_info.pw_gid)
        except Exception:
            pass
    log_success(f"ACL token saved to {token_file}")
    return secret_id


def remove_acl_token_file() -> None:
    token_file = target_token_file()
    if not token_file.is_file():
        return
    with token_file.open("r", encoding="utf-8") as handle:
        first = handle.readline().rstrip("\n")
    if first != "# Generated by consul-manager":
        log_warn(f"Skip removing ACL token file without generated marker: {token_file}")
        return
    token_file.unlink()
    log_success(f"Removed ACL token file: {token_file}")


def bootstrap_acl(enabled: bool, address: str = CONSUL_ADDR) -> str:
    if not enabled:
        log_info("Skipping ACL bootstrap")
        return ""
    log_info("Bootstrapping Consul ACL")
    result = consul_cmd(address, "", ["acl", "bootstrap"], capture=True, check=False)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode == 0:
        return write_acl_token_file(output, address)
    if "already been bootstrapped" in output.lower() or "already bootstrapped" in output.lower():
        log_warn("Consul ACL has already been bootstrapped")
    else:
        log_warn("Consul ACL bootstrap failed. Check service status and run acl bootstrap manually if needed")
    return ""


def cmd_acl_bootstrap(args: argparse.Namespace) -> int:
    address = args.address or CONSUL_ADDR
    if not consul_installed():
        raise CLIError(f"No consul-manager install found on this host: {CONFIG_FILE}")
    if not acl_enabled():
        raise CLIError("Consul ACL is disabled in the current config; nothing to bootstrap")
    if not bootstrap_acl(True, address):
        return 1
    return 0


def cmd_install(args: argparse.Namespace) -> int:
    require_linux()
    for command in ("install", "systemctl", "useradd"):
        require_command(command)
    if args.acl_default_policy not in {"deny", "allow"}:
        raise CLIError(f"Invalid ACL default policy: {args.acl_default_policy}")
    version = resolve_version(args.version)
    arch = detect_arch()
    tmpdir = create_install_tmpdir("consul-install")
    try:
        download_consul(version, arch, tmpdir)
        install_binary(tmpdir, version)
        ensure_consul_user()
        install_directories()
        encrypt_key = ""
        if args.gossip_encrypt:
            encrypt_key = read_existing_encrypt_key()
            if encrypt_key:
                log_info("Reusing existing gossip encryption key")
            else:
                encrypt_key = generate_gossip_key()
                log_success("Generated a new gossip encryption key")
        write_systemd_service()
        write_consul_config(args, encrypt_key)
        write_default_managed_configs(args)
        script_dir = current_script_dir(__file__).parent
        if running_from_installed_copy(script_dir):
            log_warn(f"Running the copy installed at {TOOL_DIR}; the tool files will not change")
            log_warn("Run install from a source checkout to update consul-manager as well")
        install_tool_snapshot(version, script_dir, args)
        log_info("Enabling Consul service")
        run_root(["systemctl", "daemon-reload"])
        run_root(["systemctl", "enable", "consul"])
        run_root(["systemctl", "restart", "consul"])
        if not wait_for_consul_api():
            raise CLIError("Timed out waiting for Consul HTTP API")
        if args.acl:
            management_token = bootstrap_acl(not args.no_acl_bootstrap)
            if management_token:
                # DNS carries no token, so without this every lookup is anonymous
                create_dns_token(CONSUL_ADDR, management_token)
            else:
                log_warn("No management token available; the DNS token was not created")
                log_warn(f"Create it later with: {CONSUL_MANAGER_CMD} acl dns-token")
        else:
            log_warn("Consul ACL is disabled; the HTTP API has no authentication")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    log_success("Consul installation completed")
    print_install_next_steps(args)
    return 0


def read_install_metadata_as_root() -> dict[str, Any]:
    """install.json sits in a root-only directory, so a sudoer can only read it through sudo."""
    result = run_root(["cat", str(INSTALL_METADATA_FILE)], capture=True, check=False)
    if result.returncode != 0:
        return {}
    try:
        data = json.loads(result.stdout or "")
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def record_tool_version_file(version: str) -> None:
    """doctor and status fall back to this file when install.json cannot be read."""
    key = "consul_version="
    try:
        lines = TOOL_VERSION_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    if not any(line.startswith(key) for line in lines):
        return
    install_text(
        TOOL_VERSION_FILE,
        "\n".join(f"{key}{version}" if line.startswith(key) else line for line in lines) + "\n",
        mode="0644",
    )


def record_upgrade_metadata(previous: str, version: str) -> None:
    """Move the recorded version forward without rewriting the whole install record."""
    metadata = read_install_metadata() or read_install_metadata_as_root()
    if not metadata:
        log_warn(f"Install metadata not readable: {INSTALL_METADATA_FILE}; the recorded version was not updated")
        return
    metadata["consul_version"] = version
    metadata["previous_consul_version"] = previous
    metadata["upgraded_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    run_root(["install", "-d", "-m", "0750", "-o", "root", "-g", "root", str(TOOL_STATE_DIR)])
    install_text(INSTALL_METADATA_FILE, json.dumps(metadata, indent=2, sort_keys=True) + "\n", mode="0644")
    record_tool_version_file(version)


def upgrade_plan_lines(current: str, target: str, keep: int) -> list[str]:
    lines = [
        "Consul upgrade plan:",
        f"  Current version:  {current}",
        f"  Target version:   {target}",
        f"  Download:         https://releases.hashicorp.com/consul/{target}/consul_{target}_linux_{detect_arch()}.zip",
        f"  Install release:  {versioned_binary_path(BINARY_VERSION_DIR, 'consul', target)}",
        f"  Switch symlink:   {BIN_PATH}",
        "  Restart service:  consul.service",
        f"  Keep releases:    {keep} (older ones are removed once the new one is running)",
        "  Left untouched:   config, data directory, gossip key, ACL tokens and the tool files",
        "",
        "  A single-server datacenter has no leader while the agent restarts, so DNS,",
        "  the catalog and the KV store are unavailable in that window. A restart that",
        "  fails is rolled back to the current release.",
    ]
    if version_tuple(target) < version_tuple(current):
        lines.extend([
            "",
            f"  Downgrade: {current} may have written raft state that {target} cannot read,",
            "  so the older release can fail to start even though the binary is restored.",
        ])
    return lines


def warn_on_version_span(current: str, target: str) -> None:
    """Consul supports one minor version at a time; larger jumps are the user's call."""
    cur = version_tuple(current)
    tgt = version_tuple(target)
    if tgt[0] != cur[0]:
        log_warn(f"Major version change {current} -> {target}; read the upgrade guide first")
    elif tgt[1] - cur[1] > 1:
        log_warn(f"{current} -> {target} skips {tgt[1] - cur[1] - 1} minor release(s); "
                 "Consul expects one minor version at a time")


def warn_on_multiple_servers(address: str, token: str) -> None:
    """Several servers have to be upgraded one node at a time, which this command does not do.

    Only advisory, so a datacenter that cannot be queried must not stop the upgrade.
    """
    try:
        result = consul_cmd(address, token, ["operator", "raft", "list-peers"], capture=True, check=False)
    except Exception:
        return
    if result.returncode != 0:
        return
    rows = [line for line in (result.stdout or "").splitlines() if line.strip()]
    peers = rows[1:] if rows and rows[0].lstrip().startswith("Node") else []
    if len(peers) > 1:
        log_warn(f"This datacenter has {len(peers)} raft peers; upgrade one server at a time "
                 "and wait for the cluster to be healthy in between")


def confirm_upgrade(assume_yes: bool) -> None:
    if assume_yes:
        return
    try:
        answer = input("Proceed with the upgrade? Type yes to continue: ")
    except EOFError as exc:
        raise CLIError("Upgrade requires confirmation. Re-run with --yes for non-interactive use") from exc
    if answer != "yes":
        raise CLIError("Upgrade cancelled")


def cmd_upgrade(args: argparse.Namespace) -> int:
    require_linux()
    for command in ("install", "systemctl"):
        require_command(command)
    if args.keep < 1:
        raise CLIError("--keep must be at least 1")
    if not BIN_PATH.exists():
        raise CLIError(f"Consul is not installed at {BIN_PATH}; run {CONSUL_MANAGER_CMD} install first")
    current = installed_binary_version() or read_installed_consul_version()
    if not current or current == "unknown":
        raise CLIError(f"Cannot determine the installed Consul version from {BIN_PATH}")
    target = resolve_upgrade_target(args.version)
    if target == current:
        log_success(f"Consul {current} is already installed; nothing to upgrade")
        recorded = read_installed_consul_version()
        if recorded != current:
            # doctor sends the operator here when the two disagree, so settle it instead of only reporting it
            log_info(f"Recording the installed version over {recorded}")
            record_upgrade_metadata(recorded, current)
        return 0
    if version_tuple(target) < version_tuple(current) and not args.allow_downgrade:
        raise CLIError(f"Refusing to downgrade Consul {current} to {target}; re-run with --allow-downgrade")
    print("\n".join(upgrade_plan_lines(current, target, args.keep)))
    warn_on_version_span(current, target)
    warn_on_multiple_servers(args.address or CONSUL_ADDR, resolve_consul_token(args))
    if args.dry_run:
        return 0
    confirm_upgrade(args.yes)
    arch = detect_arch()
    previous = linked_binary_path(BIN_PATH)
    if previous is None:
        log_info(f"Moving the installed binary into {BINARY_VERSION_DIR}")
        previous = adopt_versioned_binary_layout(BIN_PATH, BINARY_VERSION_DIR, "consul", current)
    tmpdir = create_install_tmpdir("consul-upgrade")
    try:
        download_consul(target, arch, tmpdir)
        staged = stage_binary(tmpdir, target)
        log_info(f"Switching {BIN_PATH} to {staged.name}")
        atomic_symlink(staged, BIN_PATH)
        try:
            log_info("Restarting Consul on the new binary")
            restart_consul_service()
        except (CLIError, subprocess.CalledProcessError) as exc:
            log_error(f"Consul did not come back on {target}: {exc}")
            log_warn(f"Rolling back to {previous.name}")
            atomic_symlink(previous, BIN_PATH)
            try:
                restart_consul_service()
            except (CLIError, subprocess.CalledProcessError) as rollback_error:
                raise CLIError(f"Upgrade to {target} failed and the rollback to {current} also failed: "
                               f"{rollback_error}") from exc
            raise CLIError(f"Upgrade to {target} failed and was rolled back to {current}") from exc
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    record_upgrade_metadata(current, target)
    for removed in prune_binary_versions(BINARY_VERSION_DIR, "consul", keep=args.keep, current=staged):
        log_info(f"Removed old release: {removed}")
    log_success(f"Consul upgraded: {current} -> {target}")
    print(f"\nVerify with: {CONSUL_MANAGER_CMD} doctor")
    return 0


def print_install_next_steps(args: argparse.Namespace) -> None:
    print("\nNext steps:")
    if args.acl:
        print(f"  1. source {target_token_file()}")
        print(f"  2. {CONSUL_MANAGER_CMD} nomad-jwt apply       # configure the Consul side for Nomad")
        print("  3. nomad-manager consul setup-local")
        print(f"  4. {CONSUL_MANAGER_CMD} doctor")
    else:
        print("  1. nomad-manager consul setup-local           # ACL is off, no token needed")
        print(f"  2. {CONSUL_MANAGER_CMD} doctor")


def remove_tool_snapshot() -> None:
    log_info("Removing Consul init tools")
    for path in uninstall_tool_paths():
        if Path(path).exists() or Path(path).is_symlink():
            safe_remove_path(path)


def purge_tool_state() -> None:
    log_warn("Purging Consul init tool metadata and audit logs")
    safe_remove_path(TOOL_STATE_DIR)
    safe_remove_path(TOOL_LOG_DIR)


def uninstall_runtime_paths() -> list[Path]:
    return [SYSTEMD_SERVICE, BIN_ENTRY, BIN_PATH, BINARY_VERSION_DIR, CONFIG_DIR, DATA_DIR]


def uninstall_tool_paths() -> list[Path]:
    return [TOOL_ENTRY, TOOL_PATH, TOOL_DIR]


def print_uninstall_plan(args: argparse.Namespace) -> None:
    print("Consul uninstall plan:")
    print("  Stop and disable service:")
    print("    - consul.service")
    print("  Remove runtime paths:")
    for path in uninstall_runtime_paths():
        suffix = "   <-- destroys the KV store, service catalog and ACL tokens" if path == DATA_DIR else ""
        print(f"    - {path}{suffix}")
    print("  Remove generated ACL token if present:")
    print(f"    - {target_token_file()}")
    if args.remove_tools or args.purge:
        print("  Remove tool paths:")
        for path in uninstall_tool_paths():
            print(f"    - {path}")
    else:
        print("  Preserve tool paths:")
        print(f"    - {TOOL_DIR}")
    if args.purge:
        print("  Purge tool state:")
        print(f"    - {TOOL_STATE_DIR}")
        print(f"    - {TOOL_LOG_DIR}")
    else:
        print("  Preserve tool state:")
        print(f"    - {TOOL_STATE_DIR}")
        print(f"    - {TOOL_LOG_DIR}")


def confirm_uninstall(args: argparse.Namespace) -> None:
    if args.yes:
        return
    try:
        answer = input("Proceed with uninstall? Type yes to continue: ")
    except EOFError as exc:
        raise CLIError("Uninstall requires confirmation. Re-run with --yes for non-interactive use") from exc
    if answer != "yes":
        raise CLIError("Uninstall cancelled")


def cmd_uninstall(args: argparse.Namespace) -> int:
    print_uninstall_plan(args)
    if args.dry_run:
        return 0
    confirm_uninstall(args)
    require_linux()
    require_command("systemctl")
    log_info("Stopping Consul service")
    run_root(["systemctl", "stop", "consul"], check=False)
    run_root(["systemctl", "disable", "consul"], check=False)
    log_info("Removing Consul files")
    for path in uninstall_runtime_paths():
        if Path(path).exists() or Path(path).is_symlink():
            safe_remove_path(path)
    remove_acl_token_file()
    if args.remove_tools or args.purge:
        remove_tool_snapshot()
    else:
        log_warn(f"Consul init tools preserved: {TOOL_DIR}. Use --remove-tools to remove them")
    if args.purge:
        purge_tool_state()
    else:
        log_warn(f"Consul init tool metadata preserved: {TOOL_STATE_DIR}")
        log_warn(f"Consul init tool audit logs preserved: {TOOL_LOG_DIR}")
    run_root(["systemctl", "daemon-reload"])
    run_root(["systemctl", "reset-failed", "consul"], check=False)
    if run(["id", CONSUL_USER], check=False, capture=True).returncode == 0:
        log_info(f"Removing system user: {CONSUL_USER}")
        run_root(["userdel", CONSUL_USER], check=False)
    log_success("Consul uninstallation completed")
    return 0


NOMAD_AGENT_POLICY_RULES = """# Managed by consul-manager
# Minimal policy for the Nomad agent itself under Consul workload identity.
# Task and service tokens are issued through the JWT auth method instead.
agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "write"
}
"""


def nomad_binary() -> str:
    for candidate in ("/opt/nomad/bin/nomad", "/usr/local/bin/nomad"):
        if Path(candidate).is_file():
            return candidate
    if command_exists("nomad"):
        return shutil.which("nomad") or "nomad"
    raise CLIError("Nomad binary not found; install Nomad before configuring the Consul side")


def nomad_setup_help() -> str:
    result = run([nomad_binary(), "setup", "consul", "-help"], capture=True, check=False)
    if result.returncode != 0:
        raise CLIError(
            "This Nomad build has no 'nomad setup consul' subcommand. "
            "Upgrade Nomad, or create the Consul JWT auth method and binding rules manually"
        )
    return (result.stdout or "") + (result.stderr or "")


def nomad_setup_env(address: str, token: str, nomad_addr: str) -> dict[str, str]:
    env = consul_env(address, token)
    env["NOMAD_ADDR"] = nomad_addr
    return env


def run_nomad_setup(address: str, token: str, nomad_addr: str, extra: list[str]) -> subprocess.CompletedProcess[str]:
    return run(
        [nomad_binary(), "setup", "consul", *extra],
        env=nomad_setup_env(address, token, nomad_addr),
        check=False,
    )


def require_management_token(token: str) -> str:
    if not token:
        raise CLIError(
            f"A Consul management token is required. Pass --token/--token-file, export CONSUL_HTTP_TOKEN, "
            f"or source {target_token_file()}"
        )
    return token


def consul_policy_exists(address: str, token: str, name: str) -> bool:
    result = consul_cmd(address, token, ["acl", "policy", "read", "-name", name], capture=True, check=False)
    return result.returncode == 0


def write_nomad_agent_policy(address: str, token: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".hcl") as handle:
        handle.write(NOMAD_AGENT_POLICY_RULES)
        rules_path = handle.name
    try:
        action = "update" if consul_policy_exists(address, token, NOMAD_AGENT_POLICY) else "create"
        log_info(f"Consul ACL policy {action}: {NOMAD_AGENT_POLICY}")
        consul_cmd(
            address,
            token,
            [
                "acl",
                "policy",
                action,
                "-name",
                NOMAD_AGENT_POLICY,
                "-description",
                "Nomad agent policy managed by consul-manager",
                "-rules",
                f"@{rules_path}",
            ],
            capture=True,
        )
    finally:
        Path(rules_path).unlink(missing_ok=True)


def nomad_agent_token_valid(address: str) -> bool:
    if not NOMAD_AGENT_TOKEN_FILE.is_file():
        return False
    try:
        existing = NOMAD_AGENT_TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    if not existing:
        return False
    return consul_cmd(address, existing, ["acl", "token", "read", "-self"], capture=True, check=False).returncode == 0


def create_nomad_agent_token(address: str, token: str, *, force: bool) -> None:
    if not force and nomad_agent_token_valid(address):
        log_success(f"Nomad agent token already valid: {NOMAD_AGENT_TOKEN_FILE}")
        return
    write_nomad_agent_policy(address, token)
    log_info("Creating Consul ACL token for the Nomad agent")
    result = consul_cmd(
        address,
        token,
        [
            "acl",
            "token",
            "create",
            "-description",
            NOMAD_AGENT_TOKEN_DESCRIPTION,
            "-policy-name",
            NOMAD_AGENT_POLICY,
            "-format",
            "json",
        ],
        capture=True,
    )
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise CLIError("Failed to parse the Consul token create output") from exc
    secret_id = payload.get("SecretID", "")
    if not secret_id:
        raise CLIError("Consul did not return a SecretID for the Nomad agent token")
    install_text(NOMAD_AGENT_TOKEN_FILE, f"{secret_id}\n", mode="0600", owner="root", group="root")
    log_success(f"Nomad agent token written: {NOMAD_AGENT_TOKEN_FILE}")


def nomad_jwt_skip_when_acl_disabled() -> bool:
    if acl_enabled():
        return False
    log_success("Consul ACL is disabled; no JWT auth method or agent token is needed")
    log_info("Run 'nomad-manager consul enable --no-workload-identity' on the Nomad side")
    return True


def cmd_nomad_jwt_plan(args: argparse.Namespace) -> int:
    address = args.address or CONSUL_ADDR
    nomad_addr = args.nomad_addr or DEFAULT_NOMAD_ADDR
    if nomad_jwt_skip_when_acl_disabled():
        return 0
    token = require_management_token(resolve_consul_token(args))
    help_text = nomad_setup_help()
    print("Consul side changes for Nomad workload identity:")
    print(f"  Consul address : {address}")
    print(f"  Nomad address  : {nomad_addr}")
    print(f"  JWT auth method: {NOMAD_AUTH_METHOD} (JWKS from {nomad_addr}/.well-known/jwks.json)")
    print("  Binding rules  : created by 'nomad setup consul'")
    print(f"  Agent policy   : {NOMAD_AGENT_POLICY}")
    print(f"  Agent token    : {NOMAD_AGENT_TOKEN_FILE}")
    print("\nCommands that apply would run:")
    print(f"  nomad setup consul -y")
    print(f"  consul acl policy create -name {NOMAD_AGENT_POLICY} -rules @<generated>")
    print(f"  consul acl token create -policy-name {NOMAD_AGENT_POLICY}")
    if "-check" in help_text:
        print("\nRunning 'nomad setup consul -check':\n")
        result = run_nomad_setup(address, token, nomad_addr, ["-check"])
        if result.returncode != 0:
            log_warn("nomad setup consul -check reported pending or failing steps")
    return 0


def cmd_nomad_jwt_apply(args: argparse.Namespace) -> int:
    address = args.address or CONSUL_ADDR
    nomad_addr = args.nomad_addr or DEFAULT_NOMAD_ADDR
    if nomad_jwt_skip_when_acl_disabled():
        return 0
    token = require_management_token(resolve_consul_token(args))
    nomad_setup_help()  # raises when this Nomad build has no 'setup consul' subcommand
    if not consul_leader_elected():
        raise CLIError(f"Consul has no elected leader at {address}; start Consul before applying")
    log_info("Running: nomad setup consul -y")
    result = run_nomad_setup(address, token, nomad_addr, ["-y"])
    if result.returncode != 0:
        raise CLIError("nomad setup consul failed; no agent token was created")
    log_success(f"Consul JWT auth method configured: {NOMAD_AUTH_METHOD}")
    create_nomad_agent_token(address, token, force=args.force)
    print("\nNext step on the Nomad side:")
    print(f"  nomad-manager consul setup-local")
    print(f"  # or: nomad-manager consul token set --token-file {NOMAD_AGENT_TOKEN_FILE}")
    return 0


def cmd_nomad_jwt_doctor(args: argparse.Namespace) -> int:
    address = args.address or CONSUL_ADDR
    if not acl_enabled():
        doctor_check("WARN", "Consul ACL is disabled; Nomad needs no JWT auth method")
        return 0
    token = resolve_consul_token(args)
    return doctor_nomad_integration(address, token)


def cmd_quickstart(_: argparse.Namespace) -> int:
    print(
        f"""Consul manager quickstart, in the order the commands are meant to be used.

1. Set up the node
     {CONSUL_MANAGER_CMD} install --version latest
     source {target_token_file()}
     {CONSUL_MANAGER_CMD} doctor

   Or for a throwaway lab node with no authentication:
     {CONSUL_MANAGER_CMD} install --no-acl

2. Connect Nomad
     {CONSUL_MANAGER_CMD} nomad-jwt plan
     {CONSUL_MANAGER_CMD} nomad-jwt apply
     nomad-manager consul setup-local

   With --no-acl, apply is a no-op and only the nomad-manager step is needed.

3. Tune the node
     {CONSUL_MANAGER_CMD} ui enable --metrics-provider prometheus
     {CONSUL_MANAGER_CMD} dns enable --recursor 1.1.1.1

4. Check everything at once
     {CONSUL_MANAGER_CMD} doctor --integrations
     {CONSUL_MANAGER_CMD} status

5. Review before removing anything
     {CONSUL_MANAGER_CMD} uninstall --dry-run

Run '{CONSUL_MANAGER_CMD} tutor <topic>' for the reasoning behind each step.
"""
    )
    return 0


TUTOR_TOPICS = {
    "overview": f"""Consul manager tutor.

Manage a single-node Consul install and the Consul side of the Nomad
integration. Every enable/disable command validates the config and restarts
consul.service, rolling back automatically when validation fails.

Start here:
  {CONSUL_MANAGER_CMD} quickstart
  {CONSUL_MANAGER_CMD} doctor

Topics, in the same order as the commands:
  1. Set up          install, acl
  2. Connect Nomad   nomad
  3. When it breaks  troubleshoot
""",
    "install": f"""Install a single-node Consul:

  {CONSUL_MANAGER_CMD} install                     # latest, ACL on, default_policy deny
  {CONSUL_MANAGER_CMD} install 1.21.0              # pin a version
  {CONSUL_MANAGER_CMD} install --no-acl            # ACL off
  {CONSUL_MANAGER_CMD} install --acl-default-policy allow
  {CONSUL_MANAGER_CMD} install --bind 0.0.0.0 --client 0.0.0.0

Defaults bind to 127.0.0.1 only. Widen them only when another host must reach
this Consul, and keep ACL enabled when you do.

Layout:
  binary : {BIN_PATH} -> {BIN_ENTRY}
  config : {CONFIG_FILE} plus managed fragments in {CONFIG_DIR}
  data   : {CONSUL_AGENT_DATA_DIR}
  service: {SYSTEMD_SERVICE}
  tool   : {TOOL_DIR} -> {TOOL_ENTRY}

There is no separate installer for this tool. install copies consul-manager
into the node and links it onto PATH, so run it from a source checkout the
first time:

  ./tools/consul/consul-manager install

Later, to update the tool without touching Consul itself, again from a checkout:

  ./tools/consul/consul-manager tools update
""",
    "acl": f"""ACL modes:

  install               acl.enabled = true, default_policy = "deny"
  install --acl-default-policy allow
                        acl.enabled = true, default_policy = "allow"
  install --no-acl      no acl block at all

With ACL on, install runs 'consul acl bootstrap' and writes the management
token to {target_token_file()} (mode 0600):

  source {target_token_file()}
  consul members

If bootstrap was skipped or failed:
  {CONSUL_MANAGER_CMD} acl bootstrap

Consul only allows one bootstrap per cluster. A second attempt reports that the
ACL system has already been bootstrapped; recover the existing token instead.
""",
    "nomad": f"""Connect Nomad to this Consul.

With ACL enabled, Nomad needs two things on the Consul side:
  1. a JWT auth method plus binding rules, so tasks can exchange their workload
     identity for a Consul token
  2. an ACL token for the Nomad agent itself

Both are created by:
  {CONSUL_MANAGER_CMD} nomad-jwt apply

Resolving services over DNS needs a third thing, which install sets up:
  {CONSUL_MANAGER_CMD} acl dns-token

Then on the Nomad side:
  nomad-manager consul setup-local

Without ACL, none of that applies:
  nomad-manager consul enable --no-workload-identity

Verify:
  {CONSUL_MANAGER_CMD} doctor --integrations
  nomad-manager consul doctor
""",
    "troubleshoot": f"""Troubleshooting:

  systemctl status consul
  journalctl -u consul -n 100 --no-pager
  {BIN_PATH} validate {CONFIG_DIR}
  {CONSUL_MANAGER_CMD} doctor --integrations

No leader after install:
  check bind_addr reachability and 'consul info' raft state

403 Permission denied:
  the token is missing or lacks rights; source {target_token_file()}

DNS returns NXDOMAIN for a service that is registered and healthy:
  DNS queries carry no token, so Consul answers them with acl.tokens.dns.
  Without it every lookup is anonymous and sees nothing under default_policy
  deny, while the HTTP API still finds the service because you pass a token.
  doctor reports this. Fix it with:
    {CONSUL_MANAGER_CMD} acl dns-token

Nomad tasks fail to register services:
  confirm the JWT auth method exists
  {CONSUL_MANAGER_CMD} nomad-jwt doctor
""",
}


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    if topic not in TUTOR_TOPICS:
        raise CLIError(f"Unknown tutor topic: {topic}. Available: {', '.join(sorted(TUTOR_TOPICS))}")
    print(TUTOR_TOPICS[topic])
    return 0


def add_client_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--address", help=f"Consul HTTP address (default: {CONSUL_ADDR})")
    parser.add_argument("--token", default="", help="Consul ACL token")
    parser.add_argument("--token-file", default="", help=f"File holding a Consul ACL token (default: {target_token_file()})")


COMMAND_GROUPS: list[tuple[str, str, list[tuple[str, str]]]] = [
    (
        "Set up the node",
        "",
        [
            ("install", "Install Consul and this tool, choose the ACL mode"),
            ("acl", "Bootstrap ACL when install could not"),
            ("doctor", "Check the node, the ACL state and the Nomad integration"),
            ("status", "Show members, raft peers and install metadata"),
        ],
    ),
    (
        "Connect Nomad",
        "",
        [
            ("nomad-jwt", "Consul side of Nomad workload identity"),
        ],
    ),
    (
        "Tune the node",
        "",
        [
            ("ui", "Consul UI on/off and dashboard links"),
            ("dns", "DNS behaviour and upstream recursors"),
            ("tls", "TLS for the HTTP and RPC listeners"),
            ("telemetry", "Prometheus metrics"),
        ],
    ),
    (
        "Maintain and remove",
        "",
        [
            ("upgrade", "Install another Consul release and restart the agent"),
            ("tools", "Update the installed consul-manager files"),
            ("uninstall", "Remove Consul, after showing a removal plan"),
        ],
    ),
    (
        "Learn",
        "",
        [
            ("quickstart", "A copyable end-to-end setup workflow"),
            ("tutor", "Per-topic guidance with explanations"),
        ],
    ),
]


def grouped_command_names() -> list[str]:
    return [name for _, _, commands in COMMAND_GROUPS for name, _ in commands]


def registered_command_names(parser: argparse.ArgumentParser) -> list[str]:
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            return list(action.choices)
    return []


def command_group_help() -> str:
    """Render the command list grouped by the order the commands are used in."""
    lines: list[str] = []
    for index, (title, note, commands) in enumerate(COMMAND_GROUPS, start=1):
        lines.append(f"{index}. {title}")
        if note:
            lines.append(f"     {note}")
        for name, summary in commands:
            lines.append(f"     {name:<14} {summary}")
        lines.append("")
    return "\n".join(lines).rstrip()


def build_parser() -> argparse.ArgumentParser:
    parser = CLIArgumentParser(
        prog=CONSUL_MANAGER_CMD,
        description="Manage a single-node Consul install, in the order you actually use it.\n"
        "\n"
        f"{command_group_help()}\n"
        "\n"
        f"Run '{CONSUL_MANAGER_CMD} <command> --help' for what a command does and when to use it,\n"
        f"or '{CONSUL_MANAGER_CMD} quickstart' for the whole path end to end.",
        epilog=f"""Examples:
  {CONSUL_MANAGER_CMD} install --version latest
  {CONSUL_MANAGER_CMD} install --no-acl
  {CONSUL_MANAGER_CMD} nomad-jwt apply
  {CONSUL_MANAGER_CMD} ui enable --metrics-provider prometheus
  {CONSUL_MANAGER_CMD} doctor --integrations
  {CONSUL_MANAGER_CMD} uninstall --dry-run
""",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    parser.set_defaults(func=lambda _: missing_subcommand(parser, CONSUL_MANAGER_CMD))

    install = sub.add_parser(
        "install",
        description="Install Consul, write managed config and start consul.service.\n"
        "\n"
        "ACL is enabled by default with default_policy deny; install bootstraps it and saves\n"
        "the management token to ~/consul.acl (mode 0600). Pass --no-acl for a node with no\n"
        "authentication at all, which also makes the Nomad JWT setup unnecessary.\n"
        "\n"
        "bind_addr and client_addr default to 127.0.0.1. Widen them only when another host\n"
        "must reach this Consul, and keep ACL enabled when you do.\n"
        "\n"
        "Re-running install reuses the existing gossip encryption key, so it does not break\n"
        "an already running node.\n"
        "\n"
        "install also copies this tool itself into the node: consul-manager and the\n"
        f"consul_tools package go to {TOOL_DIR},\n"
        f"linked onto PATH as {TOOL_ENTRY}.\n"
        "The node then runs its own copy, unaffected by the source tree moving or changing.\n"
        "Refresh that copy later with 'tools update'.",
    )
    install.add_argument("version_pos", nargs="?", help="Consul version, for example 1.21.0 or latest")
    install.add_argument("--version", dest="version_opt", help="Consul version; overrides the positional version")
    install.add_argument("--datacenter", default=DEFAULT_DATACENTER, help=f"Consul datacenter (default: {DEFAULT_DATACENTER})")
    install.add_argument("--bind", default=DEFAULT_BIND_ADDR, help=f"Consul bind address (default: {DEFAULT_BIND_ADDR})")
    install.add_argument("--client", default=DEFAULT_CLIENT_ADDR, help=f"Consul client address (default: {DEFAULT_CLIENT_ADDR})")
    install.add_argument("--log-level", default="INFO", help="Consul log level (default: INFO)")
    install.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT, help=f"Consul HTTP port (default: {DEFAULT_HTTP_PORT})")
    install.add_argument("--grpc-port", type=int, default=DEFAULT_GRPC_PORT, help=f"Consul gRPC port used by Connect (default: {DEFAULT_GRPC_PORT})")
    install.add_argument("--dns-port", type=int, default=DEFAULT_DNS_PORT, help=f"Consul DNS port (default: {DEFAULT_DNS_PORT})")
    add_bool_argument(install, "--acl", default=True, help_text="Enable Consul ACL and bootstrap a management token", no_help="Disable Consul ACL entirely")
    install.add_argument("--acl-default-policy", choices=("deny", "allow"), default="deny", help="ACL default policy when ACL is enabled (default: deny)")
    install.add_argument("--no-acl-bootstrap", action="store_true", help="Skip automatic ACL bootstrap after install")
    add_bool_argument(install, "--gossip-encrypt", default=True, help_text="Generate and use a gossip encryption key", no_help="Do not configure gossip encryption")
    add_bool_argument(install, "--ui", default=True, help_text="Enable the Consul UI", no_help="Disable the Consul UI")
    add_bool_argument(install, "--connect", default=True, help_text="Enable Connect and the gRPC port", no_help="Disable Connect and the gRPC port")
    install.set_defaults(
        func=lambda args: cmd_install(
            argparse.Namespace(
                version=args.version_opt or args.version_pos,
                datacenter=args.datacenter,
                bind=args.bind,
                client=args.client,
                log_level=args.log_level,
                http_port=args.http_port,
                grpc_port=args.grpc_port,
                dns_port=args.dns_port,
                acl=args.acl,
                acl_default_policy=args.acl_default_policy,
                no_acl_bootstrap=args.no_acl_bootstrap,
                gossip_encrypt=args.gossip_encrypt,
                ui=args.ui,
                connect=args.connect,
            )
        )
    )

    acl = sub.add_parser(
        "acl",
        description="Bootstrap the Consul ACL system and save the management token.\n"
        "\n"
        "install already does this when ACL is enabled, so run it only when the bootstrap was\n"
        "skipped or failed. Consul allows one bootstrap per cluster; a second attempt reports\n"
        "that the system is already bootstrapped rather than issuing a new token.",
    )
    acl_sub = acl.add_subparsers(dest="acl_command")
    acl.set_defaults(func=lambda _: missing_subcommand(acl, f"{CONSUL_MANAGER_CMD} acl"))
    acl_bootstrap = acl_sub.add_parser("bootstrap", help="Bootstrap Consul ACL and save the management token")
    acl_bootstrap.add_argument("--address", help=f"Consul HTTP address (default: {CONSUL_ADDR})")
    acl_bootstrap.set_defaults(func=cmd_acl_bootstrap)
    acl_dns = acl_sub.add_parser(
        "dns-token",
        help="Create the token the DNS interface answers with",
        description="Create a read-only token and record it as acl.tokens.dns.\n"
        "\n"
        "DNS queries carry no token, so Consul answers them with this one. Without it every\n"
        "lookup runs as the anonymous token and <service>.service.consul returns NXDOMAIN,\n"
        "even though the service is registered and healthy.\n"
        "\n"
        "install does this automatically; run it here for a node installed earlier, or after\n"
        "the token was revoked. A no-op when ACL is disabled.",
    )
    add_client_args(acl_dns)
    acl_dns.add_argument("--force", action="store_true", help="Recreate the token even if the current one works")
    acl_dns.set_defaults(func=cmd_acl_dns_token)

    doctor = sub.add_parser(
        "doctor",
        description="Check the managed Consul install, service status, ACL state and Nomad integration.\n"
        "\n"
        "Read-only. ACL and Nomad checks adapt to the ACL mode recorded at install time, so a\n"
        "node installed with --no-acl is not reported as broken.",
    )
    add_client_args(doctor)
    doctor.add_argument("--integrations", action="store_true", help="Run Nomad integration checks even when no agent token file exists")
    doctor.set_defaults(func=cmd_doctor)

    status = sub.add_parser("status")
    add_client_args(status)
    status.set_defaults(func=cmd_status)

    nomad_jwt = sub.add_parser(
        "nomad-jwt",
        description="Create the Consul JWT auth method, binding rules and Nomad agent token, so\n"
        "Nomad tasks can exchange their workload identity for a Consul token.\n"
        "\n"
        "This touches the Consul side only; wire the Nomad side afterwards with\n"
        "'nomad-manager consul setup-local'. Needs a Consul management token and a Nomad\n"
        "build that has 'nomad setup consul'.\n"
        "\n"
        "When Consul ACL is disabled none of this is needed, so apply prints a note and\n"
        "exits successfully instead of failing.",
    )
    jwt_sub = nomad_jwt.add_subparsers(dest="nomad_jwt_command")
    nomad_jwt.set_defaults(func=lambda _: missing_subcommand(nomad_jwt, f"{CONSUL_MANAGER_CMD} nomad-jwt"))
    jwt_plan = jwt_sub.add_parser("plan", help="Preview the Consul side changes")
    add_client_args(jwt_plan)
    jwt_plan.add_argument("--nomad-addr", help=f"Nomad HTTP address (default: {DEFAULT_NOMAD_ADDR})")
    jwt_plan.set_defaults(func=cmd_nomad_jwt_plan)
    jwt_apply = jwt_sub.add_parser("apply", help="Apply the Consul side changes")
    add_client_args(jwt_apply)
    jwt_apply.add_argument("--nomad-addr", help=f"Nomad HTTP address (default: {DEFAULT_NOMAD_ADDR})")
    jwt_apply.add_argument("--force", action="store_true", help="Recreate the Nomad agent token even when the existing one is valid")
    jwt_apply.set_defaults(func=cmd_nomad_jwt_apply)
    jwt_doctor = jwt_sub.add_parser("doctor", help="Check the Consul side of the Nomad integration")
    add_client_args(jwt_doctor)
    jwt_doctor.set_defaults(func=cmd_nomad_jwt_doctor)

    ui = sub.add_parser("ui", description="Manage the Consul UI. enable and disable rewrite 35-ui.hcl and restart consul.service;\nreset removes the managed file entirely.")
    ui_sub = ui.add_subparsers(dest="ui_command")
    ui.set_defaults(func=lambda _: missing_subcommand(ui, f"{CONSUL_MANAGER_CMD} ui"))
    ui_enable = ui_sub.add_parser("enable", help="Write managed UI config")
    ui_enable.add_argument("--metrics-provider", default="", help="UI metrics provider, for example prometheus")
    ui_enable.add_argument("--metrics-proxy-base-url", default="", help="Base URL proxied for UI metrics")
    ui_enable.add_argument("--dashboard-url-template", default="", help="Service dashboard URL template")
    ui_enable.set_defaults(func=cmd_ui_enable)
    ui_disable = ui_sub.add_parser("disable", help="Disable the Consul UI")
    ui_disable.set_defaults(func=cmd_ui_disable)
    ui_reset = ui_sub.add_parser("reset", help="Remove managed UI config")
    ui_reset.set_defaults(func=lambda _: remove_managed_file(UI_CONFIG) or 0)

    dns = sub.add_parser("dns", description="Manage Consul DNS behaviour in 50-dns.hcl, including upstream recursors. Both commands\nrestart consul.service.")
    dns_sub = dns.add_subparsers(dest="dns_command")
    dns.set_defaults(func=lambda _: missing_subcommand(dns, f"{CONSUL_MANAGER_CMD} dns"))
    dns_enable = dns_sub.add_parser("enable", help="Write managed DNS config")
    dns_enable.add_argument("--recursor", action="append", default=[], help="Upstream DNS recursor; repeatable")
    add_bool_argument(dns_enable, "--allow-stale", default=True, help_text="Allow stale DNS reads", no_help="Require leader-consistent DNS reads")
    add_bool_argument(dns_enable, "--enable-truncate", default=True, help_text="Set the truncate bit on large DNS responses", no_help="Do not set the truncate bit")
    add_bool_argument(dns_enable, "--only-passing", default=False, help_text="Return only passing services from DNS", no_help="Return warning services from DNS as well")
    dns_enable.set_defaults(func=cmd_dns_enable)
    dns_disable = dns_sub.add_parser("disable", help="Remove managed DNS config")
    dns_disable.set_defaults(func=lambda _: remove_managed_file(DNS_CONFIG) or 0)

    tls = sub.add_parser("tls", description="Manage the managed TLS config. enable and disable rewrite 30-tls.hcl and restart\nconsul.service.\n\nCertificates are not generated here; point the options at files that already exist.")
    tls_sub = tls.add_subparsers(dest="tls_command")
    tls.set_defaults(func=lambda _: missing_subcommand(tls, f"{CONSUL_MANAGER_CMD} tls"))
    tls_enable = tls_sub.add_parser("enable", help="Write managed TLS config")
    tls_enable.add_argument("--ca-file", required=True, help="Consul CA certificate file")
    tls_enable.add_argument("--cert-file", required=True, help="Consul certificate file")
    tls_enable.add_argument("--key-file", required=True, help="Consul private key file")
    add_bool_argument(tls_enable, "--verify-incoming", default=False, help_text="Verify incoming TLS connections", no_help="Do not verify incoming TLS connections")
    add_bool_argument(tls_enable, "--verify-outgoing", default=True, help_text="Verify outgoing TLS connections", no_help="Do not verify outgoing TLS connections")
    add_bool_argument(tls_enable, "--verify-server-hostname", default=True, help_text="Verify server hostnames for internal RPC", no_help="Do not verify server hostnames for internal RPC")
    add_bool_argument(tls_enable, "--auto-encrypt", default=False, help_text="Allow auto_encrypt TLS distribution to clients", no_help="Disable auto_encrypt TLS distribution")
    tls_enable.set_defaults(func=cmd_tls_enable)
    tls_disable = tls_sub.add_parser("disable", help="Remove managed TLS config")
    tls_disable.set_defaults(func=lambda _: remove_managed_file(TLS_CONFIG) or 0)

    telemetry = sub.add_parser("telemetry", description="Manage the managed telemetry config. enable and disable rewrite 40-telemetry.hcl and\nrestart consul.service.")
    telemetry_sub = telemetry.add_subparsers(dest="telemetry_command")
    telemetry.set_defaults(func=lambda _: missing_subcommand(telemetry, f"{CONSUL_MANAGER_CMD} telemetry"))
    telemetry_enable = telemetry_sub.add_parser("enable", help="Write managed telemetry config")
    telemetry_enable.add_argument("--retention", default="24h", help="Prometheus retention time (default: 24h)")
    add_bool_argument(telemetry_enable, "--disable-hostname", default=True, help_text="Disable hostname labels in telemetry", no_help="Keep hostname labels in telemetry", no_option="--keep-hostname")
    telemetry_enable.set_defaults(func=cmd_telemetry_enable)
    telemetry_disable = telemetry_sub.add_parser("disable", help="Remove managed telemetry config")
    telemetry_disable.set_defaults(func=lambda _: remove_managed_file(TELEMETRY_CONFIG) or 0)

    upgrade = sub.add_parser(
        "upgrade",
        help="Install another Consul release and restart the agent",
        description="Replace the Consul binary with another release and restart consul.service.\n"
        "\n"
        "Only the binary changes: config, the data directory, the gossip key, ACL tokens and\n"
        "the installed tool files are left alone. The replaced release stays on disk, so an\n"
        "agent that fails to come back is switched to it again automatically.\n"
        "\n"
        "Run --dry-run first to see the plan.",
    )
    add_client_args(upgrade)
    upgrade.add_argument("--version", default="latest", help="Target Consul version, or latest (default: latest)")
    upgrade.add_argument("--keep", type=int, default=2, metavar="N",
                         help="Releases to keep on disk, including the running one (default: 2)")
    upgrade.add_argument("--allow-downgrade", action="store_true", help="Allow installing an older release than the running one")
    upgrade.add_argument("--dry-run", action="store_true", help="Print the upgrade plan without changing anything")
    upgrade.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    upgrade.set_defaults(func=cmd_upgrade)

    tools = sub.add_parser("tools")
    tools_sub = tools.add_subparsers(dest="tools_command")
    tools.set_defaults(func=lambda _: missing_subcommand(tools, f"{CONSUL_MANAGER_CMD} tools"))
    tools_update = tools_sub.add_parser(
        "update",
        help="Update consul-manager files only",
        description="Refresh the tool copy that install placed on this node, without touching the\n"
        "Consul binary, config or service state.\n"
        "\n"
        "The new files are read from the directory of the script you invoke, so run this from\n"
        f"a source checkout. Running the installed {TOOL_ENTRY} would copy\n"
        "the node's own copy onto itself and change nothing.",
    )
    tools_update.add_argument("--consul-version",
                              help="Consul version recorded in tool metadata; defaults to existing metadata. "
                                   "This only records a version, it does not change the binary: use upgrade for that")
    tools_update.set_defaults(func=cmd_tools_update)

    uninstall = sub.add_parser(
        "uninstall",
        description="Stop Consul and remove runtime files after showing a removal plan.\n"
        "\n"
        "Run --dry-run first: the real uninstall deletes the data directory, which destroys\n"
        "the KV store, the service catalog and every ACL token. Installed tools and audit\n"
        "logs are preserved unless --remove-tools or --purge is given.",
    )
    uninstall.add_argument("--remove-tools", action="store_true", help="Also remove consul-manager from the managed install")
    uninstall.add_argument("--purge", action="store_true", help="Remove runtime files, tools, metadata and audit logs")
    uninstall.add_argument("--dry-run", action="store_true", help="Print the uninstall plan without changing files")
    uninstall.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    uninstall.set_defaults(func=cmd_uninstall)

    quickstart = sub.add_parser("quickstart")
    quickstart.set_defaults(func=cmd_quickstart)

    tutor = sub.add_parser("tutor")
    tutor.add_argument("topic", nargs="?", help=f"Topic name: {', '.join(sorted(TUTOR_TOPICS))}")
    tutor.set_defaults(func=cmd_tutor)

    return parser


def dispatch(argv: list[str]) -> int:
    parser = build_parser()
    if argv and argv[0] == "help":
        argv = ["--help", *argv[1:]]
    args = parser.parse_args(argv)
    return int(args.func(args))


def main(argv: list[str] | None = None) -> int:
    ensure_default_path()
    config = AuditConfig("consul-manager", AUDIT_LOG_FILE, {"tool_dir": str(TOOL_DIR)})
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
