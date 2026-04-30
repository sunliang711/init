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
    CLIError,
    atomic_write_text,
    command_exists,
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
    log_error,
    log_info,
    log_warn,
    parse_bool,
    parse_csv,
    require_command,
    require_linux,
    run,
    run_root,
    run_with_audit,
    safe_remove_path,
    sha256_file,
    validate_hcl_key,
    validate_name,
    wait_http,
    with_default_scheme,
)


NOMAD_MANAGER_CMD = os.environ.get("NOMAD_MANAGER_CMD", "nomad-manager")
DEFAULT_NOMAD_VERSION = "2.0.0"
NOMAD_USER = "nomad"
NOMAD_GROUP = "nomad"
NOMAD_ROOT_DIR = Path("/opt/nomad")
BIN_DIR = NOMAD_ROOT_DIR / "bin"
BIN_PATH = BIN_DIR / "nomad"
BIN_ENTRY = Path("/usr/local/bin/nomad")
CONFIG_DIR = NOMAD_ROOT_DIR / "etc" / "nomad.d"
DATA_DIR = NOMAD_ROOT_DIR / "data" / "nomad"
NOMAD_AGENT_DATA_DIR = DATA_DIR / "agent"
SYSTEMD_SERVICE = Path("/etc/systemd/system/nomad.service")
TOOL_DIR = NOMAD_ROOT_DIR / "lib" / "nomad-init-tools"
TOOL_STATE_DIR = NOMAD_ROOT_DIR / "data" / "nomad-init-tools"
TOOL_LOG_DIR = NOMAD_ROOT_DIR / "log" / "nomad-init-tools"
TOOL_PATH = BIN_DIR / "nomad-manager"
JOB_PATH = BIN_DIR / "nomad-job"
TOOL_ENTRY = Path("/usr/local/bin/nomad-manager")
JOB_ENTRY = Path("/usr/local/bin/nomad-job")
LEGACY_TOOL_ENTRY = Path("/usr/local/sbin/nomad-manager")
LEGACY_JOB_ENTRY = Path("/usr/local/sbin/nomad-job")
TOOL_VERSION_FILE = TOOL_DIR / "VERSION"
TOOL_MANIFEST_FILE = TOOL_DIR / "MANIFEST.sha256"
INSTALL_METADATA_FILE = TOOL_STATE_DIR / "install.json"
AUDIT_LOG_FILE = TOOL_LOG_DIR / "manager.audit.log"
DATA_POINTER_FILE = DATA_DIR / ".managed-by-nomad-init-tools"
RELEASE_INDEX_URL = "https://releases.hashicorp.com/nomad/"
NOMAD_ADDR = "http://127.0.0.1:4646"
LOCAL_NO_PROXY = "127.0.0.1,localhost,::1"
MANAGED_MARKER = "# Managed by tools/nomad/nomad-manager"
TLS_CONFIG = CONFIG_DIR / "30-tls.hcl"
UI_CONFIG = CONFIG_DIR / "35-ui.hcl"
TELEMETRY_CONFIG = CONFIG_DIR / "40-telemetry.hcl"
VAULT_CONFIG = CONFIG_DIR / "60-vault.hcl"
CONSUL_CONFIG = CONFIG_DIR / "60-consul.hcl"
META_CONFIG = CONFIG_DIR / "72-client-meta.hcl"
DOCKER_CONFIG = CONFIG_DIR / "80-docker.hcl"
RAW_EXEC_CONFIG = CONFIG_DIR / "81-raw-exec.hcl"
DRIVER_DENYLIST_CONFIG = CONFIG_DIR / "82-driver-denylist.hcl"
VAULT_JWT_PROFILE_DIR = Path(os.environ.get("VAULT_JWT_PROFILE_DIR", str(NOMAD_ROOT_DIR / "data" / "vault-jwt")))
REDACTED_PATH_LABEL = "<set>"


def bool_arg(value: str) -> bool:
    try:
        return parse_bool(value)
    except CLIError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def normalize_version(version: str) -> str:
    value = version.removeprefix("v")
    if not re.match(r"^[0-9]+[.][0-9]+[.][0-9]+$", value):
        raise CLIError(f"Invalid Nomad version: {version}")
    return value


def fetch_latest_version() -> str:
    html = fetch_url(RELEASE_INDEX_URL, timeout=60).decode("utf-8", errors="replace")
    match = re.search(r'href="/nomad/([0-9]+\.[0-9]+\.[0-9]+)/"', html)
    if not match:
        raise CLIError("Failed to resolve latest Nomad version")
    return normalize_version(match.group(1))


def resolve_version(requested: str | None) -> str:
    if requested and requested != "latest":
        return normalize_version(requested)
    try:
        latest = fetch_latest_version()
        log_info(f"Resolved latest Nomad version: {latest}")
        return latest
    except Exception:
        log_warn(f"Failed to resolve latest Nomad version, fallback to {DEFAULT_NOMAD_VERSION}")
        return DEFAULT_NOMAD_VERSION


def is_managed_file(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        first_line = path.open("r", encoding="utf-8").readline().rstrip("\n")
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
        raise CLIError(f"Nomad binary not found: {BIN_PATH}. Please run install first")
    run_root(["install", "-d", "-m", "0755", str(CONFIG_DIR)])


def validate_nomad_config() -> None:
    run_root([str(BIN_PATH), "config", "validate", str(CONFIG_DIR)])


def wait_for_nomad_api() -> bool:
    log_info("Waiting for Nomad HTTP API")
    for _ in range(60):
        try:
            fetch_url(f"{NOMAD_ADDR}/v1/status/leader", timeout=2, no_proxy=True)
            return True
        except Exception:
            active = run_root(["systemctl", "is-active", "--quiet", "nomad"], check=False)
            if active.returncode != 0:
                log_error("Nomad service is not active")
                if command_exists("journalctl"):
                    run_root(["journalctl", "-u", "nomad", "-n", "80", "--no-pager"], check=False)
                return False
            time.sleep(2)
    if command_exists("journalctl"):
        run_root(["journalctl", "-u", "nomad", "-n", "80", "--no-pager"], check=False)
    return False


def restart_nomad_service() -> None:
    run_root(["systemctl", "restart", "nomad"])
    time.sleep(2)
    if run_root(["systemctl", "is-active", "--quiet", "nomad"], check=False).returncode != 0:
        if command_exists("journalctl"):
            run_root(["journalctl", "-u", "nomad", "-n", "80", "--no-pager"], check=False)
        raise CLIError("Nomad service failed to start")
    if not wait_for_nomad_api():
        raise CLIError("Timed out waiting for Nomad HTTP API")


def restore_managed_file(target: Path, backup: Path | None) -> None:
    if backup and backup.exists():
        run_root(["install", "-m", "0644", str(backup), str(target)])
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
                log_info(f"No config change: {target}")
                return
        except OSError:
            pass
    try:
        install_text(target, content, mode="0644")
        validate_nomad_config()
        restart_nomad_service()
    except Exception as exc:
        restore_managed_file(target, backup)
        if backup:
            backup.unlink(missing_ok=True)
        raise CLIError(f"Nomad config apply failed, rollback completed: {exc}") from exc
    if backup:
        backup.unlink(missing_ok=True)
    log_info(f"Config applied: {target}")


def remove_managed_file(target: Path) -> None:
    require_config_environment()
    if not target.exists():
        log_info(f"Config already absent: {target}")
        return
    ensure_managed_or_absent(target)
    backup_handle = tempfile.NamedTemporaryFile(delete=False)
    backup_handle.close()
    backup = Path(backup_handle.name)
    run_root(["cp", str(target), str(backup)])
    try:
        run_root(["rm", "-f", "--", str(target)])
        validate_nomad_config()
        restart_nomad_service()
    except Exception as exc:
        run_root(["install", "-m", "0644", str(backup), str(target)])
        raise CLIError(f"Nomad config removal failed, rollback completed: {exc}") from exc
    finally:
        backup.unlink(missing_ok=True)
    log_info(f"Config removed: {target}")


def managed_config(body: str) -> str:
    return f"{MANAGED_MARKER}\n{body.rstrip()}\n"


def cmd_vault_enable(args: argparse.Namespace) -> int:
    lines = ["vault {", "  enabled = true", f"  address = {hcl_string(args.address)}"]
    if args.namespace:
        lines.append(f"  namespace = {hcl_string(args.namespace)}")
    if args.jwt_auth_backend_path:
        lines.append(f"  jwt_auth_backend_path = {hcl_string(args.jwt_auth_backend_path)}")
    for key in ("ca_file", "ca_path", "cert_file", "key_file"):
        value = getattr(args, key)
        if value:
            lines.append(f"  {key} = {hcl_string(value)}")
    lines.extend(
        [
            "",
            "  default_identity {",
            f"    aud  = {hcl_list(parse_csv(args.aud))}",
            f"    env  = {hcl_bool(args.env)}",
            f"    file = {hcl_bool(args.file)}",
            f"    ttl  = {hcl_string(args.ttl)}",
            "  }",
            "}",
        ]
    )
    commit_managed_file(VAULT_CONFIG, managed_config("\n".join(lines)))
    return 0


def cmd_consul_enable(args: argparse.Namespace) -> int:
    lines = ["consul {", f"  address    = {hcl_string(args.address)}", f"  ssl        = {hcl_bool(args.ssl)}", f"  verify_ssl = {hcl_bool(args.verify)}"]
    for key in ("grpc_address", "ca_file", "cert_file", "key_file"):
        value = getattr(args, key)
        if value:
            lines.append(f"  {key} = {hcl_string(value)}")
    lines.extend(
        [
            "",
            "  service_identity {",
            f"    aud = {hcl_list(parse_csv(args.aud))}",
            f"    ttl = {hcl_string(args.ttl)}",
            "  }",
            "",
            "  task_identity {",
            f"    aud = {hcl_list(parse_csv(args.aud))}",
            f"    ttl = {hcl_string(args.ttl)}",
            "  }",
            "}",
        ]
    )
    commit_managed_file(CONSUL_CONFIG, managed_config("\n".join(lines)))
    return 0


def cmd_telemetry_enable(args: argparse.Namespace) -> int:
    body = "\n".join(
        [
            "telemetry {",
            f"  collection_interval        = {hcl_string(args.interval)}",
            f"  disable_hostname           = {hcl_bool(args.disable_hostname)}",
            f"  prometheus_metrics         = {hcl_bool(args.prometheus)}",
            f"  publish_allocation_metrics = {hcl_bool(args.alloc)}",
            f"  publish_node_metrics       = {hcl_bool(args.node)}",
            "}",
        ]
    )
    commit_managed_file(TELEMETRY_CONFIG, managed_config(body))
    return 0


def cmd_tls_enable(args: argparse.Namespace) -> int:
    body = "\n".join(
        [
            "tls {",
            f"  http = {hcl_bool(args.http)}",
            f"  rpc  = {hcl_bool(args.rpc)}",
            f"  ca_file   = {hcl_string(args.ca_file)}",
            f"  cert_file = {hcl_string(args.cert_file)}",
            f"  key_file  = {hcl_string(args.key_file)}",
            f"  verify_server_hostname = {hcl_bool(args.verify_server_hostname)}",
            f"  verify_https_client    = {hcl_bool(args.verify_https_client)}",
            "}",
        ]
    )
    commit_managed_file(TLS_CONFIG, managed_config(body))
    return 0


def cmd_ui_enable(args: argparse.Namespace) -> int:
    lines = ["ui {", "  enabled = true", f"  show_cli_hints = {hcl_bool(args.show_cli_hints)}"]
    if args.consul_url:
        lines.extend(["  consul {", f"    ui_url = {hcl_string(args.consul_url)}", "  }"])
    if args.vault_url:
        lines.extend(["  vault {", f"    ui_url = {hcl_string(args.vault_url)}", "  }"])
    if args.label or args.label_background or args.label_color:
        lines.append("  label {")
        if args.label:
            lines.append(f"    text = {hcl_string(args.label)}")
        if args.label_background:
            lines.append(f"    background_color = {hcl_string(args.label_background)}")
        if args.label_color:
            lines.append(f"    text_color = {hcl_string(args.label_color)}")
        lines.append("  }")
    lines.append("}")
    commit_managed_file(UI_CONFIG, managed_config("\n".join(lines)))
    return 0


def cmd_ui_disable(_: argparse.Namespace) -> int:
    commit_managed_file(UI_CONFIG, managed_config("ui {\n  enabled = false\n}"))
    return 0


def cmd_docker_enable(args: argparse.Namespace) -> int:
    lines = [
        'plugin "docker" {',
        "  config {",
        f"    allow_privileged = {hcl_bool(args.allow_privileged)}",
        "",
        "    volumes {",
        f"      enabled = {hcl_bool(args.volumes)}",
        "    }",
    ]
    if args.auth_config:
        lines.extend(["", "    auth {", f"      config = {hcl_string(args.auth_config)}", "    }"])
    lines.extend(
        [
            "",
            "    gc {",
            f"      image = {hcl_bool(args.image_gc)}",
            f"      image_delay = {hcl_string(args.image_delay)}",
            "      container = true",
            "",
            "      dangling_containers {",
            "        enabled = true",
            "        dry_run = false",
            '        period = "10m"',
            '        creation_grace = "10m"',
            "      }",
            "    }",
            "",
            '    extra_labels = ["job_name", "task_group_name", "task_name", "namespace", "node_name", "short_alloc_id"]',
            "  }",
            "}",
        ]
    )
    commit_managed_file(DOCKER_CONFIG, managed_config("\n".join(lines)))
    return 0


def cmd_raw_exec_enable(_: argparse.Namespace) -> int:
    body = 'plugin "raw_exec" {\n  config {\n    enabled = true\n  }\n}'
    commit_managed_file(RAW_EXEC_CONFIG, managed_config(body))
    return 0


def read_driver_denylist() -> list[str]:
    if not DRIVER_DENYLIST_CONFIG.is_file() or not is_managed_file(DRIVER_DENYLIST_CONFIG):
        return []
    text = DRIVER_DENYLIST_CONFIG.read_text(encoding="utf-8")
    match = re.search(r'"driver\.denylist"\s*=\s*"([^"]*)"', text)
    if not match:
        return []
    return [item for item in match.group(1).split(",") if item]


def write_driver_denylist(items: list[str]) -> None:
    if not items:
        remove_managed_file(DRIVER_DENYLIST_CONFIG)
        return
    body = f'client {{\n  options = {{\n    "driver.denylist" = {hcl_string(",".join(items))}\n  }}\n}}'
    commit_managed_file(DRIVER_DENYLIST_CONFIG, managed_config(body))


def cmd_driver_deny(args: argparse.Namespace) -> int:
    driver = validate_name(args.driver, "driver name")
    items = read_driver_denylist()
    if driver in items:
        log_info(f"Driver already denied: {driver}")
        return 0
    write_driver_denylist([*items, driver])
    return 0


def cmd_driver_allow(args: argparse.Namespace) -> int:
    driver = validate_name(args.driver, "driver name")
    items = [item for item in read_driver_denylist() if item != driver]
    write_driver_denylist(items)
    return 0


def host_volume_config_path(name: str) -> Path:
    validate_name(name, "host volume name")
    return CONFIG_DIR / f"70-host-volume-{name}.hcl"


def cmd_host_volume_add(args: argparse.Namespace) -> int:
    validate_name(args.name, "host volume name")
    path = Path(args.path)
    if not path.is_absolute():
        raise CLIError(f"Host volume path must be absolute: {path}")
    if args.create:
        run_root(["install", "-d", "-m", "0755", str(path)])
    elif not path.is_dir():
        raise CLIError(f"Host volume path does not exist: {path}. Use --create to create it")
    body = "\n".join(
        [
            "client {",
            f'  host_volume "{args.name}" {{',
            f"    path      = {hcl_string(path)}",
            f"    read_only = {hcl_bool(args.read_only)}",
            "  }",
            "}",
        ]
    )
    commit_managed_file(host_volume_config_path(args.name), managed_config(body))
    return 0


def read_meta_pairs() -> dict[str, str]:
    if not META_CONFIG.is_file() or not is_managed_file(META_CONFIG):
        return {}
    pairs: dict[str, str] = {}
    for key, value in re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"', META_CONFIG.read_text(encoding="utf-8"), re.MULTILINE):
        pairs[key] = value
    return pairs


def write_meta_pairs(pairs: dict[str, str]) -> None:
    if not pairs:
        remove_managed_file(META_CONFIG)
        return
    lines = ["client {", "  meta {"]
    for key in sorted(pairs):
        lines.append(f"    {key} = {hcl_string(pairs[key])}")
    lines.extend(["  }", "}"])
    commit_managed_file(META_CONFIG, managed_config("\n".join(lines)))


def cmd_meta_set(args: argparse.Namespace) -> int:
    key = validate_hcl_key(args.key)
    pairs = read_meta_pairs()
    pairs[key] = args.value
    write_meta_pairs(pairs)
    return 0


def cmd_meta_unset(args: argparse.Namespace) -> int:
    key = validate_hcl_key(args.key)
    pairs = read_meta_pairs()
    pairs.pop(key, None)
    write_meta_pairs(pairs)
    return 0


def doctor_check(status: str, message: str) -> None:
    print(f"{status:<5} {message}")


def hcl_file_string_value(path: Path, key: str) -> str:
    if not path.is_file():
        return ""
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"', path.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1) if match else ""


def hcl_file_bool_value(path: Path, key: str) -> str:
    if not path.is_file():
        return ""
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*(true|false)", path.read_text(encoding="utf-8"), re.MULTILINE)
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


def doctor_nomad_config() -> int:
    if not BIN_PATH.exists():
        doctor_check("FAIL", f"Nomad binary not found: {BIN_PATH}")
        return 1
    if not CONFIG_DIR.is_dir():
        doctor_check("FAIL", f"Nomad config directory missing: {CONFIG_DIR}")
        return 1
    result = run([str(BIN_PATH), "config", "validate", str(CONFIG_DIR)], check=False, capture=True)
    if result.returncode == 0:
        doctor_check("OK", f"Nomad config validates: {CONFIG_DIR}")
        return 0
    doctor_check("FAIL", f"Nomad config validation failed: {CONFIG_DIR}")
    return 1


def cmd_vault_doctor(args: argparse.Namespace) -> int:
    failures = 0
    if doctor_config_file(VAULT_CONFIG, "Vault") == 1:
        failures += 1
    address = args.address or hcl_file_string_value(VAULT_CONFIG, "address")
    namespace = args.namespace or hcl_file_string_value(VAULT_CONFIG, "namespace")
    failures += doctor_nomad_config()
    if command_exists("vault"):
        doctor_check("OK", f"vault CLI found: {shutil.which('vault')}")
    else:
        doctor_check("WARN", "vault CLI not found; Nomad can still use a remote Vault address")
    if not address:
        doctor_check("FAIL", "Vault address missing; pass --address or run vault enable first")
        failures += 1
    else:
        base = with_default_scheme(address, "http")
        health_url = f"{base.rstrip('/')}/v1/sys/health"
        code = http_status(health_url)
        if code in {200, 429, 472, 473}:
            doctor_check("OK", f"Vault health endpoint reachable: {health_url} ({code})")
        elif code in {501, 503}:
            doctor_check("WARN", f"Vault health endpoint reachable but not ready: {health_url} ({code})")
        else:
            doctor_check("FAIL", f"Vault health endpoint returned {code}: {health_url}")
            failures += 1
        if command_exists("vault"):
            env = os.environ.copy()
            env["VAULT_ADDR"] = base
            if namespace:
                env["VAULT_NAMESPACE"] = namespace
            if run(["vault", "status"], check=False, env=env, capture=True).returncode == 0:
                doctor_check("OK", "vault status succeeded")
            else:
                doctor_check("WARN", "vault status failed; check token, TLS and namespace")
    return failures


def cmd_consul_doctor(args: argparse.Namespace) -> int:
    failures = 0
    if doctor_config_file(CONSUL_CONFIG, "Consul") == 1:
        failures += 1
    address = args.address or hcl_file_string_value(CONSUL_CONFIG, "address")
    ssl_value = args.ssl
    if ssl_value is None:
        ssl_value = parse_bool(hcl_file_bool_value(CONSUL_CONFIG, "ssl") or "false")
    failures += doctor_nomad_config()
    if command_exists("consul"):
        doctor_check("OK", f"consul CLI found: {shutil.which('consul')}")
    else:
        doctor_check("WARN", "consul CLI not found; Nomad can still use a remote Consul address")
    if not address:
        doctor_check("FAIL", "Consul address missing; pass --address or run consul enable first")
        return failures + 1
    base = with_default_scheme(address, "https" if ssl_value else "http")
    leader_url = f"{base.rstrip('/')}/v1/status/leader"
    code = http_status(leader_url)
    if code == 200:
        doctor_check("OK", f"Consul leader endpoint reachable: {leader_url}")
    else:
        doctor_check("FAIL", f"Consul leader endpoint not healthy: {leader_url} ({code})")
        failures += 1
    if command_exists("consul"):
        env = os.environ.copy()
        env["CONSUL_HTTP_ADDR"] = base
        if run(["consul", "info"], check=False, env=env, capture=True).returncode == 0:
            doctor_check("OK", "consul info succeeded")
        else:
            doctor_check("WARN", "consul info failed; check ACL token and TLS")
    return failures


def cmd_docker_doctor(_: argparse.Namespace) -> int:
    failures = 0
    if doctor_config_file(DOCKER_CONFIG, "Docker") == 1:
        failures += 1
    failures += doctor_nomad_config()
    if "docker" in read_driver_denylist():
        doctor_check("FAIL", f"Docker driver is denied by {DRIVER_DENYLIST_CONFIG}")
        failures += 1
    else:
        doctor_check("OK", "Docker driver is not denied")
    if command_exists("docker"):
        doctor_check("OK", f"docker CLI found: {shutil.which('docker')}")
        if run(["docker", "info"], check=False, capture=True).returncode == 0:
            doctor_check("OK", "Docker daemon is reachable")
        else:
            doctor_check("FAIL", "Docker daemon is not reachable by current user")
            failures += 1
    else:
        doctor_check("FAIL", "docker CLI not found")
        failures += 1
    if Path("/var/run/docker.sock").is_socket():
        doctor_check("OK", "Docker socket exists: /var/run/docker.sock")
    else:
        doctor_check("WARN", "Docker socket not found at /var/run/docker.sock")
    return failures


def profile_path(profile: str) -> Path:
    validate_name(profile, "vault-jwt profile")
    return VAULT_JWT_PROFILE_DIR / f"{profile}.json"


def load_profile(profile: str) -> dict[str, Any]:
    path = profile_path(profile)
    if not path.is_file():
        raise CLIError(f"Profile missing: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def prepare_profile(args: argparse.Namespace) -> dict[str, Any]:
    profile = args.profile
    existing: dict[str, Any] = {}
    path = profile_path(profile)
    if path.is_file():
        existing = json.loads(path.read_text(encoding="utf-8"))
    data = {
        "profile": profile,
        "vault_addr": args.vault_addr or existing.get("vault_addr"),
        "vault_namespace": args.vault_namespace if args.vault_namespace is not None else existing.get("vault_namespace", ""),
        "nomad_addr": args.nomad_addr or existing.get("nomad_addr"),
        "nomad_jwks_url": args.nomad_jwks_url or existing.get("nomad_jwks_url"),
        "auth_path": args.auth_path or existing.get("auth_path", "jwt-nomad"),
        "role": args.role or existing.get("role", "nomad-workloads"),
        "policy": args.policy or existing.get("policy", "nomad-workloads"),
        "aud": args.aud or existing.get("aud", "vault.io"),
        "ttl": args.ttl or existing.get("ttl", "1h"),
        "secret_paths": args.secret_path or existing.get("secret_paths", ["kv/data/*"]),
        "policy_file": args.policy_file if args.policy_file is not None else existing.get("policy_file", ""),
    }
    if not data["nomad_jwks_url"] and data["nomad_addr"]:
        data["nomad_jwks_url"] = f"{str(data['nomad_addr']).rstrip('/')}/.well-known/jwks.json"
    for key, label in (("vault_addr", "vault-jwt requires --vault-addr or an existing profile"), ("nomad_addr", "vault-jwt requires --nomad-addr or an existing profile"), ("nomad_jwks_url", "vault-jwt requires --nomad-jwks-url or --nomad-addr")):
        if not data[key]:
            raise CLIError(label)
    validate_name(data["auth_path"], "Vault auth path")
    validate_name(data["role"], "Vault role")
    validate_name(data["policy"], "Vault policy")
    if existing and not args.force:
        comparable = dict(existing)
        comparable["profile"] = profile
        if comparable != data:
            raise CLIError(f"Profile {profile} already exists with different values. Use --force to replace it")
    return data


def profile_summary(data: dict[str, Any]) -> str:
    path = profile_path(data["profile"])
    secret_paths = ",".join(data["secret_paths"])
    return "\n".join(
        [
            f"Profile:          {data['profile']}",
            f"Profile file:     {path}",
            f"Vault address:    {data['vault_addr']}",
            f"Vault namespace:  {data.get('vault_namespace') or '<none>'}",
            f"Nomad address:    {data['nomad_addr']}",
            f"Nomad JWKS URL:   {data['nomad_jwks_url']}",
            f"Auth path:        {data['auth_path']}",
            f"Role:             {data['role']}",
            f"Policy:           {data['policy']}",
            f"Audience:         {data['aud']}",
            f"TTL:              {data['ttl']}",
            f"Secret paths:     {secret_paths}",
            f"Policy file:      {data.get('policy_file') or '<generated>'}",
        ]
    )


def cmd_vault_jwt_plan(args: argparse.Namespace) -> int:
    data = prepare_profile(args)
    print(profile_summary(data))
    print(
        "\nPlan:\n"
        f"  [1/7] Write Nomad vault config {VAULT_CONFIG}\n"
        "  [2/7] Validate Nomad config and restart nomad.service\n"
        f"  [3/7] Enable Vault JWT auth at auth/{data['auth_path']} if missing\n"
        f"  [4/7] Write Vault JWT config with jwks_url={data['nomad_jwks_url']}\n"
        f"  [5/7] Write Vault policy {data['policy']}\n"
        f"  [6/7] Write Vault role {data['role']}\n"
        f"  [7/7] Save profile {profile_path(data['profile'])}\n\n"
        f"Next:\n  {NOMAD_MANAGER_CMD} vault-jwt apply --profile {data['profile']}"
    )
    return 0


def write_profile(data: dict[str, Any]) -> None:
    run_root(["install", "-d", "-m", "0700", str(VAULT_JWT_PROFILE_DIR)])
    install_text(profile_path(data["profile"]), json.dumps(data, indent=2, sort_keys=True) + "\n", mode="0600")
    log_info(f"Vault JWT profile saved: {profile_path(data['profile'])}")


def vault_env(data: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    env["VAULT_ADDR"] = data["vault_addr"]
    if data.get("vault_namespace"):
        env["VAULT_NAMESPACE"] = data["vault_namespace"]
    return env


def vault_cmd(data: dict[str, Any], command: list[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["vault", *command], env=vault_env(data), capture=capture, check=check)


def vault_auth_type(data: dict[str, Any]) -> str:
    result = vault_cmd(data, ["auth", "list", "-format=json"], capture=True, check=False)
    if result.returncode != 0:
        return ""
    parsed = json.loads(result.stdout or "{}")
    return parsed.get(f"{data['auth_path'].rstrip('/')}/", {}).get("type", "")


def generate_policy(data: dict[str, Any]) -> str:
    policy_file = data.get("policy_file")
    if policy_file:
        path = Path(policy_file)
        if not path.is_file():
            raise CLIError(f"Policy file not found: {path}")
        return path.read_text(encoding="utf-8")
    lines: list[str] = []
    for secret_path in data["secret_paths"]:
        lines.extend([f"path {hcl_string(secret_path)} {{", '  capabilities = ["read"]', "}", ""])
        if "/data/" in secret_path:
            metadata_path = secret_path.replace("/data/", "/metadata/", 1)
            lines.extend([f"path {hcl_string(metadata_path)} {{", '  capabilities = ["read", "list"]', "}", ""])
    return "\n".join(lines)


def generate_role_json(data: dict[str, Any]) -> str:
    audiences = parse_csv(data["aud"])
    if not audiences:
        raise CLIError("Missing audience")
    payload = {
        "role_type": "jwt",
        "bound_audiences": audiences,
        "user_claim": "/nomad_job_id",
        "user_claim_json_pointer": True,
        "claim_mappings": {
            "nomad_namespace": "nomad_namespace",
            "nomad_job_id": "nomad_job_id",
            "nomad_task": "nomad_task",
        },
        "token_type": "service",
        "token_policies": [data["policy"]],
        "token_period": data["ttl"],
        "token_explicit_max_ttl": 0,
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def cmd_vault_jwt_apply(args: argparse.Namespace) -> int:
    data = prepare_profile(args)
    require_command("vault")
    cmd_vault_enable(
        argparse.Namespace(
            address=data["vault_addr"],
            namespace=data.get("vault_namespace", ""),
            jwt_auth_backend_path=data["auth_path"],
            aud=data["aud"],
            ttl=data["ttl"],
            env=False,
            file=True,
            ca_file="",
            ca_path="",
            cert_file="",
            key_file="",
        )
    )
    log_info(f"Waiting for Nomad JWKS URL: {data['nomad_jwks_url']}")
    if not wait_http(data["nomad_jwks_url"], attempts=30, delay=2):
        raise CLIError(f"Timed out waiting for Nomad JWKS URL: {data['nomad_jwks_url']}")
    auth_type = vault_auth_type(data)
    if not auth_type:
        log_info(f"Enabling Vault JWT auth: {data['auth_path']}")
        vault_cmd(data, ["auth", "enable", f"-path={data['auth_path']}", "jwt"])
    elif auth_type != "jwt":
        raise CLIError(f"Vault auth path {data['auth_path']} already exists with type {auth_type}")
    else:
        log_info(f"Vault JWT auth already enabled: {data['auth_path']}")
    log_info("Writing Vault JWT auth config")
    vault_cmd(data, ["write", f"auth/{data['auth_path']}/config", f"jwks_url={data['nomad_jwks_url']}", "jwt_supported_algs=RS256,EdDSA", f"default_role={data['role']}"])
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as policy:
        policy.write(generate_policy(data))
        policy_path = policy.name
    try:
        log_info(f"Writing Vault policy: {data['policy']}")
        vault_cmd(data, ["policy", "write", data["policy"], policy_path])
    finally:
        Path(policy_path).unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as role:
        role.write(generate_role_json(data))
        role_path = role.name
    try:
        log_info(f"Writing Vault JWT role: {data['role']}")
        vault_cmd(data, ["write", f"auth/{data['auth_path']}/role/{data['role']}", f"@{role_path}"])
    finally:
        Path(role_path).unlink(missing_ok=True)
    write_profile(data)
    return 0


def vault_jwt_status_impl(profile: str) -> int:
    data = load_profile(profile)
    failures = 0
    doctor_check("OK", f"profile loaded: {profile_path(profile)}")
    if VAULT_CONFIG.is_file() and f'jwt_auth_backend_path = "{data["auth_path"]}"' in VAULT_CONFIG.read_text(encoding="utf-8"):
        doctor_check("OK", f"Nomad vault config uses auth path {data['auth_path']}")
    else:
        doctor_check("FAIL", f"Nomad vault config missing or mismatched: {VAULT_CONFIG}")
        failures += 1
    if wait_http(data["nomad_jwks_url"], attempts=1, delay=0):
        doctor_check("OK", f"Nomad JWKS URL reachable: {data['nomad_jwks_url']}")
    else:
        doctor_check("FAIL", f"Nomad JWKS URL not reachable from this host: {data['nomad_jwks_url']}")
        failures += 1
    if command_exists("vault"):
        if vault_auth_type(data) == "jwt":
            doctor_check("OK", f"Vault auth path {data['auth_path']} type jwt")
        else:
            doctor_check("FAIL", f"Vault auth path {data['auth_path']} missing or not jwt")
            failures += 1
        if vault_cmd(data, ["policy", "read", data["policy"]], check=False, capture=True).returncode == 0:
            doctor_check("OK", f"Vault policy exists: {data['policy']}")
        else:
            doctor_check("FAIL", f"Vault policy missing: {data['policy']}")
            failures += 1
        if vault_cmd(data, ["read", f"auth/{data['auth_path']}/role/{data['role']}"], check=False, capture=True).returncode == 0:
            doctor_check("OK", f"Vault role exists: {data['role']}")
        else:
            doctor_check("FAIL", f"Vault role missing: {data['role']}")
            failures += 1
    else:
        doctor_check("FAIL", "vault command is required for Vault checks")
        failures += 1
    return failures


def cmd_vault_jwt_status(args: argparse.Namespace) -> int:
    return vault_jwt_status_impl(args.profile)


def cmd_vault_jwt_doctor(args: argparse.Namespace) -> int:
    failures = vault_jwt_status_impl(args.profile)
    if failures == 0:
        print("\nAll checks passed.")
        return 0
    print(f"\nFix:\n  {NOMAD_MANAGER_CMD} vault-jwt apply --profile {args.profile}")
    return 1


def cmd_vault_jwt_job_example(args: argparse.Namespace) -> int:
    data = load_profile(args.profile)
    validate_name(args.job, "job name")
    content = f"""# Generated by nomad-manager vault-jwt job-example
job {hcl_string(args.job)} {{
  type        = "service"
  datacenters = ["dc1"]

  group {hcl_string(args.job)} {{
    count = 1

    task {hcl_string(args.job)} {{
      driver = "docker"

      config {{
        image   = {hcl_string(args.image)}
        command = "sh"
        args    = ["-c", "env | sort && sleep 3600"]
      }}

      identity {{
        name = "vault_default"
        aud  = [{hcl_string(data["aud"])}]
        file = true
        ttl  = {hcl_string(data["ttl"])}
      }}

      vault {{
        cluster = "default"
        role    = {hcl_string(data["role"])}
      }}

      template {{
        destination = "secrets/vault.env"
        env         = true
        data = <<EOH
{{{{ with secret {hcl_string(args.secret)} }}}}
{{{{ with index .Data.data "value" }}}}SECRET_VALUE={{{{ . }}}}
{{{{ end }}}}{{{{ with index .Data.data "username" }}}}APP_USERNAME={{{{ . }}}}
{{{{ end }}}}{{{{ with index .Data.data "password" }}}}APP_PASSWORD={{{{ . }}}}
{{{{ end }}}}{{{{ with index .Data.data "api_key" }}}}APP_API_KEY={{{{ . }}}}
{{{{ end }}}}{{{{ end }}}}
EOH
      }}

      resources {{
        cpu    = 100
        memory = 128
      }}
    }}
  }}
}}
"""
    if args.out == "-":
        print(content, end="")
    else:
        atomic_write_text(args.out, content, force=args.force)
        log_info(f"Job example written: {args.out}")
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
    log_info(f"Checksum verified: {zip_file.name}")


def download_nomad(version: str, arch: str, tmpdir: Path) -> None:
    zip_name = f"nomad_{version}_linux_{arch}.zip"
    sums_name = f"nomad_{version}_SHA256SUMS"
    base_url = f"https://releases.hashicorp.com/nomad/{version}"
    zip_file = tmpdir / zip_name
    sums_file = tmpdir / sums_name
    log_info(f"Downloading Nomad {version} for linux_{arch}")
    download_file(f"{base_url}/{zip_name}", zip_file, timeout=300)
    download_file(f"{base_url}/{sums_name}", sums_file, timeout=300)
    verify_checksum(zip_file, sums_file)
    extract_dir = tmpdir / "extract"
    extract_dir.mkdir(parents=True, exist_ok=True)
    extract_zip(zip_file, extract_dir)
    if not (extract_dir / "nomad").is_file():
        raise CLIError("Nomad binary not found in archive")


def ensure_nomad_user() -> None:
    if run(["id", NOMAD_USER], check=False, capture=True).returncode == 0:
        return
    log_info(f"Creating system user: {NOMAD_USER}")
    run_root(["useradd", "--system", "--home", str(NOMAD_ROOT_DIR), "--shell", "/bin/false", NOMAD_USER])


def install_directories() -> None:
    log_info("Creating Nomad directories")
    for path, mode, owner, group in [
        (NOMAD_ROOT_DIR, "0755", "root", "root"),
        (BIN_DIR, "0755", "root", "root"),
        (NOMAD_ROOT_DIR / "etc", "0755", "root", "root"),
        (NOMAD_ROOT_DIR / "data", "0755", "root", "root"),
        (NOMAD_ROOT_DIR / "lib", "0755", "root", "root"),
        (NOMAD_ROOT_DIR / "log", "0750", "root", "root"),
        (CONFIG_DIR, "0755", NOMAD_USER, NOMAD_GROUP),
        (DATA_DIR, "0755", NOMAD_USER, NOMAD_GROUP),
        (NOMAD_AGENT_DATA_DIR, "0755", NOMAD_USER, NOMAD_GROUP),
    ]:
        run_root(["install", "-d", "-m", mode, "-o", owner, "-g", group, str(path)])


def write_systemd_service() -> None:
    content = f"""[Unit]
Description=Nomad
Documentation=https://developer.hashicorp.com/nomad/docs
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
ExecReload=/bin/kill -HUP $MAINPID
ExecStart={BIN_PATH} agent -config {CONFIG_DIR}
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=2
TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
"""
    log_info(f"Installing systemd service: {SYSTEMD_SERVICE}")
    install_text(SYSTEMD_SERVICE, content, mode="0644")


def write_nomad_config() -> None:
    content = f"""datacenter = "dc1"
data_dir   = "{NOMAD_AGENT_DATA_DIR}"
bind_addr  = "0.0.0.0"
log_level  = "INFO"

server {{
  enabled          = true
  bootstrap_expect = 1
}}

client {{
  enabled = true
  servers = ["127.0.0.1:4647"]
}}

acl {{
  enabled = true
}}
"""
    log_info(f"Installing Nomad config: {CONFIG_DIR / 'nomad.hcl'}")
    install_text(CONFIG_DIR / "nomad.hcl", content, mode="0644")
    run_root(["chown", f"{NOMAD_USER}:{NOMAD_GROUP}", str(CONFIG_DIR / "nomad.hcl")])


def write_default_managed_configs() -> None:
    telemetry = managed_config(
        """telemetry {
  collection_interval        = "1s"
  disable_hostname           = false
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}"""
    )
    docker = managed_config(
        '''plugin "docker" {
  config {
    allow_privileged = true

    volumes {
      enabled = true
    }

    gc {
      image = true
      image_delay = "100h"
      container = true

      dangling_containers {
        enabled = true
        dry_run = false
        period = "10m"
        creation_grace = "10m"
      }
    }

    extra_labels = ["job_name", "task_group_name", "task_name", "namespace", "node_name", "short_alloc_id"]
  }
}'''
    )
    log_info("Installing default managed configs")
    install_text(TELEMETRY_CONFIG, telemetry, mode="0644")
    install_text(DOCKER_CONFIG, docker, mode="0644")


def install_binary(tmpdir: Path) -> None:
    log_info(f"Installing binary: {BIN_PATH}")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(tmpdir / "extract" / "nomad"), str(BIN_PATH)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_ENTRY.parent)])
    run_root(["ln", "-sfn", str(BIN_PATH), str(BIN_ENTRY)])
    log_info(f"Nomad binary entry installed: {BIN_ENTRY}")
    run([str(BIN_PATH), "version"])


def write_tool_manifest() -> None:
    lines: list[str] = []
    for name in ("nomad-manager", "nomad-job"):
        path = TOOL_DIR / name
        if path.is_file():
            lines.append(f"{sha256_file(path)}  {name}")
    install_text(TOOL_MANIFEST_FILE, "\n".join(lines) + "\n", mode="0644")


def write_install_metadata(version: str) -> None:
    metadata = {
        "tool": "nomad-manager",
        "root_dir": str(NOMAD_ROOT_DIR),
        "tool_dir": str(TOOL_DIR),
        "manager_path": str(TOOL_PATH),
        "manager_entry": str(TOOL_ENTRY),
        "job_path": str(JOB_PATH),
        "job_entry": str(JOB_ENTRY),
        "nomad_binary": str(BIN_PATH),
        "nomad_entry": str(BIN_ENTRY),
        "config_dir": str(CONFIG_DIR),
        "data_dir": str(DATA_DIR),
        "agent_data_dir": str(NOMAD_AGENT_DATA_DIR),
        "service": str(SYSTEMD_SERVICE),
        "nomad_version": version,
        "installed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "manifest_file": str(TOOL_MANIFEST_FILE),
        "manifest_sha256": sha256_file(TOOL_MANIFEST_FILE) if TOOL_MANIFEST_FILE.is_file() else "",
        "audit_log": str(AUDIT_LOG_FILE),
    }
    run_root(["install", "-d", "-m", "0750", "-o", "root", "-g", "root", str(TOOL_STATE_DIR)])
    install_text(INSTALL_METADATA_FILE, json.dumps(metadata, indent=2, sort_keys=True) + "\n", mode="0644")


def write_data_pointer() -> None:
    content = "\n".join(
        [
            "Managed by nomad-manager",
            f"Install metadata: {INSTALL_METADATA_FILE}",
            f"Tool dir: {TOOL_DIR}",
            f"Config dir: {CONFIG_DIR}",
            f"Audit log: {AUDIT_LOG_FILE}",
            "",
        ]
    )
    install_text(DATA_POINTER_FILE, content, mode="0644")


def install_tool_snapshot(version: str, script_dir: Path) -> None:
    log_info(f"Installing Nomad init tools snapshot: {TOOL_DIR}")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_DIR)])
    for old_name in ("manager.sh", "job"):
        safe_remove_path(TOOL_DIR / old_name)
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(script_dir / "nomad-manager"), str(TOOL_DIR / "nomad-manager")])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(script_dir / "nomad-job"), str(TOOL_DIR / "nomad-job")])
    safe_remove_path(TOOL_DIR / "nomad_tools")
    run_root(["cp", "-R", str(script_dir / "nomad_tools"), str(TOOL_DIR / "nomad_tools")])
    run_root(["chown", "-R", "root:root", str(TOOL_DIR / "nomad_tools")])
    install_text(TOOL_VERSION_FILE, f"tool=nomad-manager\nnomad_version={version}\ninstalled_at={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\nsource_dir={script_dir}\n", mode="0644")
    write_tool_manifest()
    write_install_metadata(version)
    write_data_pointer()
    run_root(["ln", "-sfn", str(TOOL_DIR / "nomad-manager"), str(TOOL_PATH)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_ENTRY.parent)])
    run_root(["ln", "-sfn", str(TOOL_PATH), str(TOOL_ENTRY)])
    run_root(["ln", "-sfn", str(TOOL_DIR / "nomad-job"), str(JOB_PATH)])
    run_root(["ln", "-sfn", str(JOB_PATH), str(JOB_ENTRY)])
    if LEGACY_TOOL_ENTRY.is_symlink():
        safe_remove_path(LEGACY_TOOL_ENTRY)
    if LEGACY_JOB_ENTRY.is_symlink():
        safe_remove_path(LEGACY_JOB_ENTRY)
    log_info(f"Nomad manager entry installed: {TOOL_ENTRY}")
    log_info(f"Nomad job entry installed: {JOB_ENTRY}")


def target_token_file() -> Path:
    target_user = os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    try:
        target_home = Path(pwd.getpwnam(target_user).pw_dir)
    except KeyError:
        target_home = Path.home()
    if not target_home.is_dir():
        target_home = Path.home()
    return target_home / "nomad.acl"


def write_acl_token_file(output: str) -> None:
    token_file = target_token_file()
    match = re.search(r"(?im)^\s*Secret ID\s*=\s*(\S+)", output)
    secret_id = match.group(1) if match else ""
    content = "# Generated by nomad-manager\n# Source this file to use the bootstrapped ACL token.\n"
    content += f"export NOMAD_ADDR={NOMAD_ADDR}\n"
    if secret_id:
        content += f"export NOMAD_TOKEN={secret_id}\n"
    content += "\n" + "\n".join(f"# {line}" for line in output.splitlines()) + "\n"
    atomic_write_text(token_file, content, mode=0o600)
    target_user = os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    if os.geteuid() == 0 and target_user != "root":
        try:
            user_info = pwd.getpwnam(target_user)
            os.chown(token_file, user_info.pw_uid, user_info.pw_gid)
        except Exception:
            pass
    log_info(f"ACL token saved to {token_file}")


def remove_acl_token_file() -> None:
    token_file = target_token_file()
    if not token_file.is_file():
        return
    first = token_file.open("r", encoding="utf-8").readline().rstrip("\n")
    if first != "# Generated by nomad-manager":
        log_warn(f"Skip removing ACL token file without generated marker: {token_file}")
        return
    token_file.unlink()
    log_info(f"Removed ACL token file: {token_file}")


def bootstrap_acl(enabled: bool) -> None:
    if not enabled:
        log_info("Skipping ACL bootstrap")
        return
    env = os.environ.copy()
    env["NOMAD_ADDR"] = NOMAD_ADDR
    env["no_proxy"] = LOCAL_NO_PROXY
    env["NO_PROXY"] = LOCAL_NO_PROXY
    log_info("Bootstrapping Nomad ACL")
    result = run([str(BIN_PATH), "acl", "bootstrap"], env=env, capture=True, check=False)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode == 0:
        write_acl_token_file(output)
    elif "already" in output.lower():
        log_warn("Nomad ACL has already been bootstrapped")
    else:
        log_warn("Nomad ACL bootstrap failed. Check service status and run manually if needed")


def cmd_install(args: argparse.Namespace) -> int:
    require_linux()
    for command in ("install", "systemctl", "useradd"):
        require_command(command)
    version = resolve_version(args.version)
    arch = detect_arch()
    tmpdir = create_install_tmpdir("nomad-install")
    try:
        download_nomad(version, arch, tmpdir)
        install_binary(tmpdir)
        ensure_nomad_user()
        install_directories()
        write_systemd_service()
        write_nomad_config()
        write_default_managed_configs()
        install_tool_snapshot(version, current_script_dir(__file__).parent)
        log_info("Enabling Nomad service")
        run_root(["systemctl", "daemon-reload"])
        run_root(["systemctl", "enable", "nomad"])
        run_root(["systemctl", "restart", "nomad"])
        if not wait_for_nomad_api():
            raise CLIError("Timed out waiting for Nomad HTTP API")
        bootstrap_acl(not args.no_acl_bootstrap)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    log_info("Nomad installation completed")
    return 0


def remove_tool_snapshot() -> None:
    log_info("Removing Nomad init tools")
    for path in (TOOL_ENTRY, JOB_ENTRY, LEGACY_TOOL_ENTRY, LEGACY_JOB_ENTRY, TOOL_PATH, JOB_PATH, TOOL_DIR):
        if Path(path).exists() or Path(path).is_symlink():
            safe_remove_path(path)


def purge_tool_state() -> None:
    log_warn("Purging Nomad init tool metadata and audit logs")
    safe_remove_path(TOOL_STATE_DIR)
    safe_remove_path(TOOL_LOG_DIR)


def cmd_uninstall(args: argparse.Namespace) -> int:
    require_linux()
    require_command("systemctl")
    log_info("Stopping Nomad service")
    run_root(["systemctl", "stop", "nomad"], check=False)
    run_root(["systemctl", "disable", "nomad"], check=False)
    log_info("Removing Nomad files")
    for path in (SYSTEMD_SERVICE, BIN_ENTRY, BIN_PATH, CONFIG_DIR, DATA_DIR):
        if Path(path).exists() or Path(path).is_symlink():
            safe_remove_path(path)
    remove_acl_token_file()
    if args.remove_tools or args.purge:
        remove_tool_snapshot()
    else:
        log_warn(f"Nomad init tools preserved: {TOOL_DIR}. Use --remove-tools to remove them")
    if args.purge:
        purge_tool_state()
    else:
        log_warn(f"Nomad init tool metadata preserved: {TOOL_STATE_DIR}")
        log_warn(f"Nomad init tool audit logs preserved: {TOOL_LOG_DIR}")
    run_root(["systemctl", "daemon-reload"])
    run_root(["systemctl", "reset-failed", "nomad"], check=False)
    if run(["id", NOMAD_USER], check=False, capture=True).returncode == 0:
        log_info(f"Removing system user: {NOMAD_USER}")
        run_root(["userdel", NOMAD_USER], check=False)
    log_info("Nomad uninstallation completed")
    return 0


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    topics = {
        "overview": "nomad-manager manages node setup and integrations. Use nomad-job for job files.",
        "install": f"Install a single node with: {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}",
        "docker": f"Enable Docker support with: {NOMAD_MANAGER_CMD} docker enable --allow-privileged true --volumes true",
        "vault": f"Point Nomad at Vault with: {NOMAD_MANAGER_CMD} vault enable --address http://127.0.0.1:8200",
        "vault-jwt": f"Link workload identity with: {NOMAD_MANAGER_CMD} vault-jwt apply --profile default --vault-addr http://127.0.0.1:8200 --nomad-addr http://127.0.0.1:4646",
        "consul": f"Point Nomad at Consul with: {NOMAD_MANAGER_CMD} consul enable --address 127.0.0.1:8500",
        "ui": f"Enable UI settings with: {NOMAD_MANAGER_CMD} ui enable",
        "job": "Use nomad-job scaffold docker, validate, plan and apply for job workflows.",
        "uninstall": f"Remove runtime files with: {NOMAD_MANAGER_CMD} uninstall; add --purge only for full cleanup.",
        "troubleshoot": "Run docker doctor, vault doctor, consul doctor and inspect systemctl status nomad.",
    }
    if topic not in topics:
        raise CLIError(f"Unknown tutor topic: {topic}")
    print(topics[topic])
    return 0


def add_common_vault_jwt_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile", required=True)
    parser.add_argument("--vault-addr")
    parser.add_argument("--vault-namespace")
    parser.add_argument("--nomad-addr")
    parser.add_argument("--nomad-jwks-url")
    parser.add_argument("--auth-path")
    parser.add_argument("--role")
    parser.add_argument("--policy")
    parser.add_argument("--aud")
    parser.add_argument("--ttl")
    parser.add_argument("--secret-path", action="append")
    parser.add_argument("--policy-file")
    parser.add_argument("--force", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=NOMAD_MANAGER_CMD, description="Install and manage a single-node Nomad setup.")
    sub = parser.add_subparsers(dest="command")

    install = sub.add_parser("install", help="Install Nomad")
    install.add_argument("version_pos", nargs="?")
    install.add_argument("--version", dest="version_opt")
    install.add_argument("--no-acl-bootstrap", action="store_true")
    install.set_defaults(func=lambda args: cmd_install(argparse.Namespace(version=args.version_opt or args.version_pos, no_acl_bootstrap=args.no_acl_bootstrap)))

    uninstall = sub.add_parser("uninstall", help="Uninstall Nomad")
    uninstall.add_argument("--remove-tools", action="store_true")
    uninstall.add_argument("--purge", action="store_true")
    uninstall.set_defaults(func=cmd_uninstall)

    vault = sub.add_parser("vault", help="Manage Vault integration")
    vault_sub = vault.add_subparsers(dest="vault_command")
    vault_enable = vault_sub.add_parser("enable")
    vault_enable.add_argument("--address", required=True)
    vault_enable.add_argument("--ca-file", default="")
    vault_enable.add_argument("--ca-path", default="")
    vault_enable.add_argument("--cert-file", default="")
    vault_enable.add_argument("--key-file", default="")
    vault_enable.add_argument("--namespace", default="")
    vault_enable.add_argument("--jwt-auth-backend-path", default="jwt-nomad")
    vault_enable.add_argument("--aud", default="vault.io")
    vault_enable.add_argument("--ttl", default="1h")
    vault_enable.add_argument("--env", type=bool_arg, default=False)
    vault_enable.add_argument("--file", type=bool_arg, default=True)
    vault_enable.set_defaults(func=cmd_vault_enable)
    vault_disable = vault_sub.add_parser("disable")
    vault_disable.set_defaults(func=lambda _: remove_managed_file(VAULT_CONFIG) or 0)
    vault_doctor = vault_sub.add_parser("doctor")
    vault_doctor.add_argument("--address")
    vault_doctor.add_argument("--namespace")
    vault_doctor.set_defaults(func=cmd_vault_doctor)

    consul = sub.add_parser("consul", help="Manage Consul integration")
    consul_sub = consul.add_subparsers(dest="consul_command")
    consul_enable = consul_sub.add_parser("enable")
    consul_enable.add_argument("--address", required=True)
    consul_enable.add_argument("--grpc-address", default="")
    consul_enable.add_argument("--ca-file", default="")
    consul_enable.add_argument("--cert-file", default="")
    consul_enable.add_argument("--key-file", default="")
    consul_enable.add_argument("--ssl", type=bool_arg, default=False)
    consul_enable.add_argument("--verify", type=bool_arg, default=True)
    consul_enable.add_argument("--aud", default="consul.io")
    consul_enable.add_argument("--ttl", default="1h")
    consul_enable.set_defaults(func=cmd_consul_enable)
    consul_disable = consul_sub.add_parser("disable")
    consul_disable.set_defaults(func=lambda _: remove_managed_file(CONSUL_CONFIG) or 0)
    consul_doctor = consul_sub.add_parser("doctor")
    consul_doctor.add_argument("--address")
    consul_doctor.add_argument("--ssl", type=bool_arg)
    consul_doctor.set_defaults(func=cmd_consul_doctor)

    telemetry = sub.add_parser("telemetry", help="Manage telemetry config")
    telemetry_sub = telemetry.add_subparsers(dest="telemetry_command")
    telemetry_enable = telemetry_sub.add_parser("enable")
    telemetry_enable.add_argument("--prometheus", type=bool_arg, default=True)
    telemetry_enable.add_argument("--alloc", type=bool_arg, default=True)
    telemetry_enable.add_argument("--node", type=bool_arg, default=True)
    telemetry_enable.add_argument("--interval", default="1s")
    telemetry_enable.add_argument("--disable-hostname", type=bool_arg, default=False)
    telemetry_enable.set_defaults(func=cmd_telemetry_enable)
    telemetry_disable = telemetry_sub.add_parser("disable")
    telemetry_disable.set_defaults(func=lambda _: remove_managed_file(TELEMETRY_CONFIG) or 0)

    tls = sub.add_parser("tls", help="Manage TLS config")
    tls_sub = tls.add_subparsers(dest="tls_command")
    tls_enable = tls_sub.add_parser("enable")
    tls_enable.add_argument("--ca-file", required=True)
    tls_enable.add_argument("--cert-file", required=True)
    tls_enable.add_argument("--key-file", required=True)
    tls_enable.add_argument("--http", type=bool_arg, default=True)
    tls_enable.add_argument("--rpc", type=bool_arg, default=True)
    tls_enable.add_argument("--verify-server-hostname", type=bool_arg, default=False)
    tls_enable.add_argument("--verify-https-client", type=bool_arg, default=False)
    tls_enable.set_defaults(func=cmd_tls_enable)
    tls_disable = tls_sub.add_parser("disable")
    tls_disable.set_defaults(func=lambda _: remove_managed_file(TLS_CONFIG) or 0)

    ui = sub.add_parser("ui", help="Manage UI config")
    ui_sub = ui.add_subparsers(dest="ui_command")
    ui_enable = ui_sub.add_parser("enable")
    ui_enable.add_argument("--consul-url")
    ui_enable.add_argument("--vault-url")
    ui_enable.add_argument("--label")
    ui_enable.add_argument("--label-background")
    ui_enable.add_argument("--label-color")
    ui_enable.add_argument("--show-cli-hints", type=bool_arg, default=True)
    ui_enable.set_defaults(func=cmd_ui_enable)
    ui_disable = ui_sub.add_parser("disable")
    ui_disable.set_defaults(func=cmd_ui_disable)
    ui_reset = ui_sub.add_parser("reset")
    ui_reset.set_defaults(func=lambda _: remove_managed_file(UI_CONFIG) or 0)

    docker = sub.add_parser("docker", help="Manage Docker driver config")
    docker_sub = docker.add_subparsers(dest="docker_command")
    docker_enable = docker_sub.add_parser("enable")
    docker_enable.add_argument("--allow-privileged", type=bool_arg, default=True)
    docker_enable.add_argument("--volumes", type=bool_arg, default=True)
    docker_enable.add_argument("--image-gc", type=bool_arg, default=True)
    docker_enable.add_argument("--image-delay", default="100h")
    docker_enable.add_argument("--auth-config")
    docker_enable.set_defaults(func=cmd_docker_enable)
    docker_disable = docker_sub.add_parser("disable")
    docker_disable.set_defaults(func=lambda _: remove_managed_file(DOCKER_CONFIG) or 0)
    docker_disable_driver = docker_sub.add_parser("disable-driver")
    docker_disable_driver.set_defaults(func=lambda _: cmd_driver_deny(argparse.Namespace(driver="docker")))
    docker_enable_driver = docker_sub.add_parser("enable-driver")
    docker_enable_driver.set_defaults(func=lambda _: cmd_driver_allow(argparse.Namespace(driver="docker")))
    docker_doctor = docker_sub.add_parser("doctor")
    docker_doctor.set_defaults(func=cmd_docker_doctor)

    raw_exec = sub.add_parser("raw-exec", help="Manage raw_exec driver config")
    raw_sub = raw_exec.add_subparsers(dest="raw_exec_command")
    raw_enable = raw_sub.add_parser("enable")
    raw_enable.set_defaults(func=cmd_raw_exec_enable)
    raw_disable = raw_sub.add_parser("disable")
    raw_disable.set_defaults(func=lambda _: remove_managed_file(RAW_EXEC_CONFIG) or 0)

    driver = sub.add_parser("driver", help="Manage driver denylist")
    driver_sub = driver.add_subparsers(dest="driver_command")
    driver_deny = driver_sub.add_parser("deny")
    driver_deny.add_argument("driver")
    driver_deny.set_defaults(func=cmd_driver_deny)
    driver_allow = driver_sub.add_parser("allow")
    driver_allow.add_argument("driver")
    driver_allow.set_defaults(func=cmd_driver_allow)

    host_volume = sub.add_parser("host-volume", help="Manage host volumes")
    hv_sub = host_volume.add_subparsers(dest="host_volume_command")
    hv_add = hv_sub.add_parser("add")
    hv_add.add_argument("name")
    hv_add.add_argument("--path", required=True)
    hv_add.add_argument("--read-only", action="store_true", dest="read_only")
    hv_add.add_argument("--read-write", action="store_false", dest="read_only")
    hv_add.set_defaults(read_only=False)
    hv_add.add_argument("--create", action="store_true")
    hv_add.set_defaults(func=cmd_host_volume_add)
    hv_remove = hv_sub.add_parser("remove")
    hv_remove.add_argument("name")
    hv_remove.set_defaults(func=lambda args: remove_managed_file(host_volume_config_path(args.name)) or 0)

    meta = sub.add_parser("meta", help="Manage client meta")
    meta_sub = meta.add_subparsers(dest="meta_command")
    meta_set = meta_sub.add_parser("set")
    meta_set.add_argument("key")
    meta_set.add_argument("value")
    meta_set.set_defaults(func=cmd_meta_set)
    meta_unset = meta_sub.add_parser("unset")
    meta_unset.add_argument("key")
    meta_unset.set_defaults(func=cmd_meta_unset)

    vault_jwt = sub.add_parser("vault-jwt", help="Manage Vault JWT workload identity")
    jwt_sub = vault_jwt.add_subparsers(dest="vault_jwt_command")
    jwt_plan = jwt_sub.add_parser("plan")
    add_common_vault_jwt_args(jwt_plan)
    jwt_plan.set_defaults(func=cmd_vault_jwt_plan)
    jwt_apply = jwt_sub.add_parser("apply")
    add_common_vault_jwt_args(jwt_apply)
    jwt_apply.set_defaults(func=cmd_vault_jwt_apply)
    jwt_status = jwt_sub.add_parser("status")
    jwt_status.add_argument("--profile", required=True)
    jwt_status.set_defaults(func=cmd_vault_jwt_status)
    jwt_doctor = jwt_sub.add_parser("doctor")
    jwt_doctor.add_argument("--profile", required=True)
    jwt_doctor.set_defaults(func=cmd_vault_jwt_doctor)
    jwt_job = jwt_sub.add_parser("job-example")
    jwt_job.add_argument("--profile", required=True)
    jwt_job.add_argument("--job", required=True)
    jwt_job.add_argument("--secret", required=True)
    jwt_job.add_argument("--out", default="-")
    jwt_job.add_argument("--image", default="alpine:3.20")
    jwt_job.add_argument("--force", action="store_true")
    jwt_job.set_defaults(func=cmd_vault_jwt_job_example)

    tutor = sub.add_parser("tutor", help="Show short workflow guidance")
    tutor.add_argument("topic", nargs="?")
    tutor.set_defaults(func=cmd_tutor)
    return parser


def dispatch(argv: list[str]) -> int:
    parser = build_parser()
    if argv and argv[0] == "help":
        argv = ["--help", *argv[1:]]
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        parser.print_help()
        return 0
    return int(args.func(args))


def main(argv: list[str] | None = None) -> int:
    ensure_default_path()
    config = AuditConfig("nomad-manager", AUDIT_LOG_FILE, {"tool_dir": str(TOOL_DIR)})
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
