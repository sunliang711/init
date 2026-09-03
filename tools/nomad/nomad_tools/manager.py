from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
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
    parse_bool,
    parse_csv,
    prune_binary_versions,
    require_command,
    require_linux,
    run,
    run_root,
    run_with_audit,
    safe_remove_path,
    sha256_file,
    terminal_status_prefix,
    terminal_supports_checkmark,
    validate_hcl_key,
    validate_name,
    version_tuple,
    versioned_binary_path,
    wait_http,
    with_default_scheme,
)


NOMAD_MANAGER_CMD = os.environ.get("NOMAD_MANAGER_CMD", "nomad-manager")
DEFAULT_NOMAD_VERSION = "2.0.0"
NOMAD_USER = "nomad"
NOMAD_GROUP = "nomad"
NOMAD_ROOT_DIR = Path("/opt/nomad")
HOST_VOLUME_DIR = NOMAD_ROOT_DIR / "volumes"
BIN_DIR = NOMAD_ROOT_DIR / "bin"
BIN_PATH = BIN_DIR / "nomad"
BINARY_VERSION_DIR = BIN_DIR / "versions"
BIN_ENTRY = Path("/usr/local/bin/nomad")
CONFIG_DIR = NOMAD_ROOT_DIR / "etc" / "nomad.d"
NOMAD_CONFIG_FILE = CONFIG_DIR / "nomad.hcl"
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
# Nomad garbage-collects dead jobs after 4h by default; keep their history instead
DEFAULT_JOB_GC_THRESHOLD = "87600h"
LOCAL_ADDRESSES = {"", "127.0.0.1", "localhost", "::1", "[::1]"}
DEFAULT_VAULT_ADDR = "http://127.0.0.1:8200"
LOCAL_NO_PROXY = "127.0.0.1,localhost,::1"
MANAGED_MARKER = "# Managed by tools/nomad/nomad-manager"
TLS_CONFIG = CONFIG_DIR / "30-tls.hcl"
UI_CONFIG = CONFIG_DIR / "35-ui.hcl"
TELEMETRY_CONFIG = CONFIG_DIR / "40-telemetry.hcl"
VAULT_CONFIG = CONFIG_DIR / "60-vault.hcl"
VAULT_CLIENT_ENV_FILE = Path("/opt/vault/etc/vault.d/client.env")
CONSUL_CONFIG = CONFIG_DIR / "60-consul.hcl"
DEFAULT_CONSUL_ADDR = "127.0.0.1:8500"
CONSUL_TOKEN_ENV_FILE = NOMAD_ROOT_DIR / "etc" / "consul.env"
CONSUL_TOKEN_DROPIN_DIR = Path("/etc/systemd/system/nomad.service.d")
CONSUL_TOKEN_DROPIN = CONSUL_TOKEN_DROPIN_DIR / "10-consul-token.conf"
CONSUL_ROOT_DIR = Path("/opt/consul")
CONSUL_INSTALL_METADATA_FILE = CONSUL_ROOT_DIR / "data" / "consul-init-tools" / "install.json"
CONSUL_NOMAD_AGENT_TOKEN_FILE = CONSUL_ROOT_DIR / "etc" / "consul.d" / "nomad-agent.token"
META_CONFIG = CONFIG_DIR / "72-client-meta.hcl"
DOCKER_CONFIG = CONFIG_DIR / "80-docker.hcl"
RAW_EXEC_CONFIG = CONFIG_DIR / "81-raw-exec.hcl"
DRIVER_DENYLIST_CONFIG = CONFIG_DIR / "82-driver-denylist.hcl"
CNI_CLIENT_CONFIG = CONFIG_DIR / "83-cni.hcl"
CNI_BIN_DIR = Path("/opt/cni/bin")
CNI_CONFIG_DIR = Path("/opt/cni/config")
CNI_SYSCTL_CONFIG = Path("/etc/sysctl.d/99-nomad-cni-bridge.conf")
CNI_MODULES_CONFIG = Path("/etc/modules-load.d/99-nomad-cni.conf")
DEFAULT_CNI_PLUGIN_VERSION = "v1.6.2"
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


def parse_binary_version(output: str) -> str:
    """The version a nomad binary reports, or "" when the output is unexpected."""
    match = re.search(r"Nomad v([0-9]+[.][0-9]+[.][0-9]+)", output)
    return match.group(1) if match else ""


def installed_binary_version() -> str:
    """What the binary on this node reports, which upgrade trusts over metadata."""
    if not BIN_PATH.is_file():
        return ""
    return parse_binary_version(run([str(BIN_PATH), "version"], capture=True, check=False).stdout or "")


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
        log_success(f"Resolved latest Nomad version: {latest}")
        return latest
    except Exception:
        log_warn(f"Failed to resolve latest Nomad version, fallback to {DEFAULT_NOMAD_VERSION}")
        return DEFAULT_NOMAD_VERSION


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
        raise CLIError(f"Cannot resolve the latest Nomad version: {exc}. "
                       f"Pass --version to pick one explicitly") from exc
    log_success(f"Resolved latest Nomad version: {latest}")
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
                log_success(f"No config change: {target}")
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
        validate_nomad_config()
        restart_nomad_service()
    except Exception as exc:
        run_root(["install", "-m", "0644", str(backup), str(target)])
        raise CLIError(f"Nomad config removal failed, rollback completed: {exc}") from exc
    finally:
        backup.unlink(missing_ok=True)
    log_success(f"Config removed: {target}")


def managed_config(body: str) -> str:
    return f"{MANAGED_MARKER}\n{body.rstrip()}\n"


def vault_jwt_profiles() -> list[tuple[str, dict[str, Any]]]:
    profiles: list[tuple[str, dict[str, Any]]] = []
    if not VAULT_JWT_PROFILE_DIR.is_dir():
        return profiles
    for path in sorted(VAULT_JWT_PROFILE_DIR.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            profiles.append((path.stem, data))
    return profiles


def warn_on_vault_jwt_conflict(args: argparse.Namespace) -> None:
    """Warn when a bare 'vault enable' would undo what 'vault jwt apply' wrote."""
    for name, data in vault_jwt_profiles():
        auth_path = str(data.get("auth_path", ""))
        if auth_path and auth_path != args.jwt_auth_backend_path:
            log_warn(f"vault-jwt profile {name} uses auth path {auth_path}, but this writes {args.jwt_auth_backend_path}")
            log_warn(f"Nomad would stop finding the configured JWT mount; run {NOMAD_MANAGER_CMD} vault jwt apply --profile {name} to keep both sides in sync")
    detected_ca = vault_ca_cert_file(args.address)
    if detected_ca and not args.ca_file and not args.ca_path:
        log_warn(f"Vault CA detected but not written: {detected_ca}")
        log_warn(f"Pass --ca-file {detected_ca} when Vault uses TLS, otherwise Nomad will fail to verify it")


def cmd_vault_enable(args: argparse.Namespace) -> int:
    warn_on_vault_jwt_conflict(args)
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
    if getattr(args, "workload_identity", True):
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
            ]
        )
    lines.append("}")
    commit_managed_file(CONSUL_CONFIG, managed_config("\n".join(lines)))
    return 0


def consul_install_metadata() -> dict[str, Any]:
    try:
        data = json.loads(CONSUL_INSTALL_METADATA_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def local_consul_address(metadata: dict[str, Any]) -> str:
    port = metadata.get("http_port", 8500)
    return f"127.0.0.1:{port}"


def write_consul_token(token: str, *, restart: bool) -> None:
    require_config_environment()
    if not token:
        raise CLIError("Consul token is empty")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(CONSUL_TOKEN_ENV_FILE.parent)])
    install_text(CONSUL_TOKEN_ENV_FILE, f"CONSUL_HTTP_TOKEN={token}\n", mode="0600", owner="root", group="root")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(CONSUL_TOKEN_DROPIN_DIR)])
    install_text(
        CONSUL_TOKEN_DROPIN,
        f"{MANAGED_MARKER}\n[Service]\nEnvironmentFile={CONSUL_TOKEN_ENV_FILE}\n",
        mode="0644",
    )
    run_root(["systemctl", "daemon-reload"])
    log_success(f"Consul token stored: {CONSUL_TOKEN_ENV_FILE}")
    if restart:
        restart_nomad_service()


def read_token_argument(args: argparse.Namespace) -> str:
    token = getattr(args, "token", "") or ""
    if token:
        return token
    token_file = getattr(args, "token_file", "") or ""
    if not token_file:
        raise CLIError("Pass --token or --token-file")
    path = Path(token_file)
    if not path.is_file():
        raise CLIError(f"Consul token file not found: {path}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise CLIError(f"Consul token file is empty: {path}")
    return value.splitlines()[0].strip()


def cmd_consul_token_set(args: argparse.Namespace) -> int:
    write_consul_token(read_token_argument(args), restart=True)
    return 0


def cmd_consul_token_unset(_: argparse.Namespace) -> int:
    require_config_environment()
    removed = False
    for path in (CONSUL_TOKEN_DROPIN, CONSUL_TOKEN_ENV_FILE):
        if path.exists():
            safe_remove_path(path)
            removed = True
    if not removed:
        log_success("No managed Consul token to remove")
        return 0
    run_root(["systemctl", "daemon-reload"])
    restart_nomad_service()
    log_success("Consul token removed")
    return 0


def cmd_consul_setup_local(args: argparse.Namespace) -> int:
    metadata = consul_install_metadata()
    if not metadata:
        raise CLIError(
            f"Local Consul install metadata not found: {CONSUL_INSTALL_METADATA_FILE}. "
            "Install Consul with consul-manager first, or use 'consul enable --address ...' for a remote Consul"
        )
    address = args.address or local_consul_address(metadata)
    acl_on = bool(metadata.get("acl_enabled", True))
    log_info(f"Local Consul detected: {address} (acl_enabled={str(acl_on).lower()})")
    if acl_on:
        token_file = Path(args.token_file) if args.token_file else CONSUL_NOMAD_AGENT_TOKEN_FILE
        if not token_file.is_file():
            raise CLIError(
                f"Nomad agent token not found: {token_file}. Run 'consul-manager nomad-jwt apply' first"
            )
        write_consul_token(read_token_argument(argparse.Namespace(token="", token_file=str(token_file))), restart=False)
    else:
        log_warn("Consul ACL is disabled; skipping token and workload identity setup")
    return cmd_consul_enable(
        argparse.Namespace(
            address=address,
            grpc_address="",
            ca_file="",
            cert_file="",
            key_file="",
            ssl=False,
            verify=True,
            aud="consul.io",
            ttl="1h",
            workload_identity=acl_on,
        )
    )


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
        log_success(f"Driver already denied: {driver}")
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


def resolve_host_volume_path(name: str, value: str | None) -> Path:
    raw_path = (value or name).strip()
    if not raw_path:
        raw_path = name
    path = Path(raw_path)
    if path.is_absolute():
        return path
    base = HOST_VOLUME_DIR.resolve(strict=False)
    target = (base / path).resolve(strict=False)
    if target != base and base not in target.parents:
        raise CLIError(f"Host volume path escapes base directory {HOST_VOLUME_DIR}: {raw_path}")
    return target


def host_volume_job_hcl_example(name: str, read_only: bool) -> str:
    mode = hcl_bool(read_only)
    destination = f"/opt/{name}"
    return f"""    group "app" {{
      volume "{name}" {{
        type      = "host"
        source    = "{name}"
        read_only = {mode}
      }}

      task "web" {{
        volume_mount {{
          volume      = "{name}"
          destination = "{destination}"
          read_only   = {mode}
        }}
      }}
    }}"""


def host_volume_next_steps(name: str, read_only: bool) -> str:
    access = "ro" if read_only else "rw"
    return (
        "Next:\n"
        "  Reference this host volume in a Nomad job:\n\n"
        f"{host_volume_job_hcl_example(name, read_only)}\n\n"
        "  Or scaffold a job with:\n"
        f"    {shell_command(['nomad-job', 'scaffold', 'docker', '--job', 'web', '--image', 'nginx:1.27', '--host-volume', f'{name}:/opt/{name}:{access}', '--out', 'jobs/web.nomad.hcl'])}"
    )


def cmd_host_volume_add(args: argparse.Namespace) -> int:
    validate_name(args.name, "host volume name")
    path = resolve_host_volume_path(args.name, args.path)
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
    print(host_volume_next_steps(args.name, args.read_only), file=sys.stderr)
    return 0


def read_host_volume_path(name: str) -> Path | None:
    config = host_volume_config_path(name)
    if not is_managed_file(config):
        return None
    try:
        content = config.read_text(encoding="utf-8")
    except OSError:
        return None
    match = re.search(r'^\s*path\s*=\s*"([^"]*)"', content, re.MULTILINE)
    if not match or not match.group(1).strip():
        return None
    return Path(match.group(1))


def ensure_purgeable_host_volume_path(path: Path) -> None:
    resolved = path.resolve(strict=False)
    protected = [Path("/"), NOMAD_ROOT_DIR, HOST_VOLUME_DIR, CONFIG_DIR, DATA_DIR, BIN_DIR, TOOL_DIR, TOOL_STATE_DIR]
    for item in protected:
        target = item.resolve(strict=False)
        if resolved == target or resolved in target.parents:
            raise CLIError(f"Refuse to purge host volume path: {resolved}")


def confirm_host_volume_purge(path: Path, assume_yes: bool) -> None:
    if assume_yes:
        return
    try:
        answer = input(f"Delete host volume data directory {path}? Type yes to continue: ")
    except EOFError as exc:
        raise CLIError("Host volume purge requires confirmation. Re-run with --yes for non-interactive use") from exc
    if answer != "yes":
        raise CLIError("Host volume purge cancelled")


def cmd_host_volume_remove(args: argparse.Namespace) -> int:
    validate_name(args.name, "host volume name")
    path = read_host_volume_path(args.name)
    assumed = path is None
    if path is None:
        path = resolve_host_volume_path(args.name, None)
    if args.purge and path.exists():
        ensure_purgeable_host_volume_path(path)
        if assumed:
            log_warn(f"Host volume path is missing from the config, assuming the default path: {path}")
        confirm_host_volume_purge(path, args.yes)
    remove_managed_file(host_volume_config_path(args.name))
    if not path.exists():
        if args.purge:
            log_success(f"Host volume data already absent: {path}")
        return 0
    if args.purge:
        log_info(f"Removing host volume data: {path}")
        safe_remove_path(path)
        log_success(f"Host volume data removed: {path}")
        return 0
    if assumed:
        log_warn(f"Host volume data may still exist at the default path: {path}")
    else:
        log_warn(f"Host volume data preserved: {path}")
    log_warn(f"Remove it with: {shell_command([NOMAD_MANAGER_CMD, 'host-volume', 'remove', args.name, '--purge'])}")
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


def normalize_cni_version(version: str) -> str:
    value = version.strip()
    if re.match(r"^[0-9]+[.][0-9]+[.][0-9]+$", value):
        value = f"v{value}"
    if not re.match(r"^v[0-9]+[.][0-9]+[.][0-9]+$", value):
        raise CLIError(f"Invalid CNI plugin version: {version}")
    return value


def detect_cni_arch() -> str:
    arch = detect_arch()
    if arch in {"amd64", "arm64"}:
        return arch
    if arch == "386":
        return "386"
    raise CLIError(f"Unsupported CNI architecture: {arch}")


def cni_archive_name(version: str, arch: str) -> str:
    return f"cni-plugins-linux-{arch}-{version}.tgz"


def verify_cni_checksum(archive_file: Path, checksum_file: Path) -> None:
    expected = checksum_file.read_text(encoding="utf-8").split()[0]
    actual = sha256_file(archive_file)
    if expected != actual:
        raise CLIError(f"Checksum mismatch for {archive_file.name}")
    log_success(f"Checksum verified: {archive_file.name}")


def safe_extract_cni_archive(archive_file: Path, output_dir: Path) -> None:
    output_base = output_dir.resolve()
    with tarfile.open(archive_file, "r:gz") as archive:
        for member in archive.getmembers():
            target = (output_base / member.name).resolve()
            if target != output_base and output_base not in target.parents:
                raise CLIError(f"Refuse to extract unsafe CNI archive member: {member.name}")
            if member.issym() or member.islnk():
                raise CLIError(f"Refuse to extract linked CNI archive member: {member.name}")
        archive.extractall(output_base)


def download_cni_plugins(version: str, tmpdir: Path) -> Path:
    arch = detect_cni_arch()
    archive_name = cni_archive_name(version, arch)
    base_url = f"https://github.com/containernetworking/plugins/releases/download/{version}"
    archive_file = tmpdir / archive_name
    checksum_file = tmpdir / f"{archive_name}.sha256"

    log_info(f"Downloading CNI plugins {version} for linux_{arch}")
    download_file(f"{base_url}/{archive_name}", archive_file, timeout=300)
    download_file(f"{base_url}/{archive_name}.sha256", checksum_file, timeout=300)
    verify_cni_checksum(archive_file, checksum_file)

    extract_dir = tmpdir / "cni-extract"
    extract_dir.mkdir(parents=True, exist_ok=True)
    safe_extract_cni_archive(archive_file, extract_dir)
    return extract_dir


def install_cni_plugins(version: str) -> None:
    tmpdir = create_install_tmpdir("nomad-cni")
    try:
        extract_dir = download_cni_plugins(version, tmpdir)
        run_root(["install", "-d", "-m", "0755", str(CNI_BIN_DIR)])
        installed = 0
        for path in sorted(extract_dir.iterdir()):
            if not path.is_file():
                continue
            run_root(["install", "-m", "0755", str(path), str(CNI_BIN_DIR / path.name)])
            installed += 1
        if installed == 0:
            raise CLIError("CNI plugin archive did not contain plugin binaries")
        log_success(f"CNI plugins installed: {CNI_BIN_DIR}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def cni_client_config_content(version: str = "") -> str:
    lines = [f"# cni_plugin_version = {version}"] if version else []
    lines.extend(
        [
            "client {",
            f"  cni_path       = {hcl_string(CNI_BIN_DIR)}",
            f"  cni_config_dir = {hcl_string(CNI_CONFIG_DIR)}",
            "}",
        ]
    )
    return managed_config("\n".join(lines))


def cni_sysctl_content() -> str:
    return "\n".join(
        [
            MANAGED_MARKER,
            "net.bridge.bridge-nf-call-arptables = 1",
            "net.bridge.bridge-nf-call-ip6tables = 1",
            "net.bridge.bridge-nf-call-iptables = 1",
            "",
        ]
    )


def cni_modules_content() -> str:
    return "\n".join(
        [
            MANAGED_MARKER,
            "bridge",
            "br_netfilter",
            "",
        ]
    )


def apply_cni_sysctl() -> None:
    require_command("modprobe")
    require_command("sysctl")
    ensure_managed_or_absent(CNI_MODULES_CONFIG)
    ensure_managed_or_absent(CNI_SYSCTL_CONFIG)
    run_root(["modprobe", "bridge"])
    run_root(["modprobe", "br_netfilter"])
    run_root(["install", "-d", "-m", "0755", str(CNI_MODULES_CONFIG.parent)])
    install_text(CNI_MODULES_CONFIG, cni_modules_content(), mode="0644")
    run_root(["install", "-d", "-m", "0755", str(CNI_SYSCTL_CONFIG.parent)])
    install_text(CNI_SYSCTL_CONFIG, cni_sysctl_content(), mode="0644")
    result = run_root(["sysctl", "--system"], check=False, capture=True)
    if result.returncode != 0:
        log_warn("sysctl --system failed, falling back to sysctl -p for CNI bridge settings")
        run_root(["sysctl", "-p", str(CNI_SYSCTL_CONFIG)])


def installed_cni_version() -> str:
    match = re.search(r"(?m)^#\s*cni_plugin_version\s*=\s*(\S+)", read_config_text(CNI_CLIENT_CONFIG))
    return match.group(1) if match else ""


def write_cni_client_config(version: str = "", *, restart: bool) -> None:
    if restart:
        commit_managed_file(CNI_CLIENT_CONFIG, cni_client_config_content(version))
        return
    ensure_managed_or_absent(CNI_CLIENT_CONFIG)
    install_text(CNI_CLIENT_CONFIG, cni_client_config_content(version), mode="0644")


def enable_cni(version: str, *, restart: bool) -> None:
    require_config_environment()
    version = normalize_cni_version(version)
    install_cni_plugins(version)
    run_root(["install", "-d", "-m", "0755", str(CNI_CONFIG_DIR)])
    apply_cni_sysctl()
    write_cni_client_config(version, restart=restart)
    if not restart:
        validate_nomad_config()
    log_success("Nomad CNI configuration enabled")


def cmd_cni_plan(args: argparse.Namespace) -> int:
    version = normalize_cni_version(args.version)
    arch = detect_cni_arch()
    archive_name = cni_archive_name(version, arch)
    print("Nomad CNI enable plan:")
    print(f"  - Download: https://github.com/containernetworking/plugins/releases/download/{version}/{archive_name}")
    print(f"  - Verify:   {archive_name}.sha256")
    print(f"  - Install:  {CNI_BIN_DIR}")
    print(f"  - Ensure:   {CNI_CONFIG_DIR}")
    print(f"  - Write:    {CNI_MODULES_CONFIG}")
    print(f"  - Write:    {CNI_SYSCTL_CONFIG}")
    print(f"  - Write:    {CNI_CLIENT_CONFIG}")
    print("  - Load:     bridge and br_netfilter modules")
    print("  - Reload:   bridge sysctl settings")
    print("  - Restart:  nomad.service")
    return 0


def cmd_cni_enable(args: argparse.Namespace) -> int:
    enable_cni(args.version, restart=True)
    return 0


def cmd_cni_disable(args: argparse.Namespace) -> int:
    remove_managed_file(CNI_CLIENT_CONFIG)
    if CNI_SYSCTL_CONFIG.exists():
        ensure_managed_or_absent(CNI_SYSCTL_CONFIG)
        run_root(["rm", "-f", "--", str(CNI_SYSCTL_CONFIG)])
        log_success(f"Config removed: {CNI_SYSCTL_CONFIG}")
    if CNI_MODULES_CONFIG.exists():
        ensure_managed_or_absent(CNI_MODULES_CONFIG)
        run_root(["rm", "-f", "--", str(CNI_MODULES_CONFIG)])
        log_success(f"Config removed: {CNI_MODULES_CONFIG}")
    if args.remove_plugins:
        safe_remove_path(CNI_BIN_DIR)
        log_success(f"CNI plugins removed: {CNI_BIN_DIR}")
    return 0


def read_proc_sysctl(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def cmd_cni_status(_: argparse.Namespace) -> int:
    plugins = ["bridge", "loopback", "host-local", "portmap", "firewall"]
    failures = 0
    doctor_info(f"plugin version = {unset_label(installed_cni_version())}")
    for plugin in plugins:
        path = CNI_BIN_DIR / plugin
        status = "OK" if os.access(path, os.X_OK) else "FAIL"
        failures += 0 if status == "OK" else 1
        doctor_check(status, f"CNI plugin {plugin}: {path}")
    status = "OK" if CNI_CONFIG_DIR.is_dir() else "FAIL"
    failures += 0 if status == "OK" else 1
    doctor_check(status, f"CNI config dir: {CNI_CONFIG_DIR}")
    status = "OK" if CNI_CLIENT_CONFIG.is_file() else "FAIL"
    failures += 0 if status == "OK" else 1
    doctor_check(status, f"Nomad CNI client config: {CNI_CLIENT_CONFIG}")
    doctor_check("OK" if CNI_MODULES_CONFIG.is_file() else "WARN", f"CNI modules config: {CNI_MODULES_CONFIG}")
    doctor_check("OK" if CNI_SYSCTL_CONFIG.is_file() else "WARN", f"CNI bridge sysctl config: {CNI_SYSCTL_CONFIG}")
    for name in ("bridge-nf-call-arptables", "bridge-nf-call-ip6tables", "bridge-nf-call-iptables"):
        path = Path("/proc/sys/net/bridge") / name
        value = read_proc_sysctl(path)
        doctor_check("OK" if value == "1" else "WARN", f"{name}={value or 'unavailable'}")
    return 1 if failures else 0


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
    """Return the body of a `<block> {` ... `}` section from a managed config."""
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


def unset_label(value: str) -> str:
    return value if value else "<unset>"


def read_base_config_text() -> str:
    """The base config carries no managed marker; install owns it outright."""
    try:
        return NOMAD_CONFIG_FILE.read_text(encoding="utf-8")
    except OSError:
        return ""


def base_config_values() -> dict[str, str]:
    text = read_base_config_text()
    if not text:
        return {}
    server = hcl_block_body(text, "server")
    client = hcl_block_body(text, "client")
    return {
        "datacenter": hcl_text_value(text, "datacenter"),
        "data_dir": hcl_text_value(text, "data_dir"),
        "bind_addr": hcl_text_value(text, "bind_addr"),
        "log_level": hcl_text_value(text, "log_level"),
        "server": hcl_text_value(server, "enabled"),
        "bootstrap_expect": hcl_text_value(server, "bootstrap_expect"),
        "job_gc_threshold": hcl_text_value(server, "job_gc_threshold"),
        "client": hcl_text_value(client, "enabled"),
        "acl": hcl_text_value(hcl_block_body(text, "acl"), "enabled"),
    }


def doctor_base_configuration() -> int:
    values = base_config_values()
    if not values:
        doctor_check("FAIL", f"Base config not readable: {NOMAD_CONFIG_FILE}")
        return 1
    failures = 0
    doctor_info(f"datacenter       = {unset_label(values['datacenter'])}")
    doctor_info(f"bind_addr        = {unset_label(values['bind_addr'])}")
    doctor_info(f"data_dir         = {unset_label(values['data_dir'])}")
    doctor_info(f"roles            = server {values['server'] or 'false'}, client {values['client'] or 'false'}")
    doctor_info(f"job_gc_threshold = {unset_label(values['job_gc_threshold'])}"
                + ("  (Nomad default 4h)" if not values["job_gc_threshold"] else ""))
    doctor_info(f"acl              = {values['acl'] or 'false'}")
    acl_off = values["acl"] != "true"
    # Nomad serves the HTTP API on bind_addr, unlike Consul where it is client_addr
    if values["bind_addr"] not in LOCAL_ADDRESSES and acl_off:
        doctor_check("FAIL", f"HTTP API binds {values['bind_addr']} with ACL disabled")
        doctor_check("INFO", "Anyone who can reach the port can submit and stop jobs")
        failures += 1
    if values["server"] == "true" and values["bootstrap_expect"] not in {"1", ""}:
        doctor_check("WARN", f"bootstrap_expect is {values['bootstrap_expect']}; this tool manages single-node installs")
    return failures


def docker_config_values() -> dict[str, str]:
    config = hcl_block_body(read_config_text(DOCKER_CONFIG), "config")
    if not config:
        return {}
    gc = hcl_block_body(config, "gc")
    return {
        "allow_privileged": hcl_text_value(config, "allow_privileged"),
        "volumes": hcl_text_value(hcl_block_body(config, "volumes"), "enabled"),
        "image_gc": hcl_text_value(gc, "image"),
        "image_delay": hcl_text_value(gc, "image_delay"),
        "auth_config": hcl_text_value(hcl_block_body(config, "auth"), "config"),
    }


def tls_config_values() -> dict[str, str]:
    text = read_config_text(TLS_CONFIG)
    if not text:
        return {}
    return {key: hcl_text_value(text, key) for key in
            ("http", "rpc", "ca_file", "cert_file", "key_file", "verify_server_hostname", "verify_https_client")}


def ui_config_values() -> dict[str, str]:
    text = read_config_text(UI_CONFIG)
    if not text:
        return {}
    body = hcl_block_body(text, "ui")
    return {
        "enabled": hcl_text_value(body, "enabled"),
        "show_cli_hints": hcl_text_value(body, "show_cli_hints"),
        "consul_url": hcl_text_value(hcl_block_body(body, "consul"), "ui_url"),
        "vault_url": hcl_text_value(hcl_block_body(body, "vault"), "ui_url"),
        "label": hcl_text_value(hcl_block_body(body, "label"), "text"),
    }


def telemetry_config_values() -> dict[str, str]:
    text = read_config_text(TELEMETRY_CONFIG)
    if not text:
        return {}
    return {key: hcl_text_value(text, key) for key in
            ("collection_interval", "disable_hostname", "prometheus_metrics",
             "publish_allocation_metrics", "publish_node_metrics")}


def vault_config_values() -> dict[str, str]:
    text = read_config_text(VAULT_CONFIG)
    if not text:
        return {}
    identity = hcl_block_body(text, "default_identity")
    return {
        "address": hcl_text_value(text, "address"),
        "namespace": hcl_text_value(text, "namespace"),
        "jwt_auth_backend_path": hcl_text_value(text, "jwt_auth_backend_path"),
        "ca_file": hcl_text_value(text, "ca_file"),
        "cert_file": hcl_text_value(text, "cert_file"),
        "aud": hcl_text_value(identity, "aud"),
        "ttl": hcl_text_value(identity, "ttl"),
        "env": hcl_text_value(identity, "env"),
        "file": hcl_text_value(identity, "file"),
    }


def consul_config_values() -> dict[str, str]:
    text = read_config_text(CONSUL_CONFIG)
    if not text:
        return {}
    service = hcl_block_body(text, "service_identity")
    return {
        "address": hcl_text_value(text, "address"),
        "ssl": hcl_text_value(text, "ssl"),
        "verify_ssl": hcl_text_value(text, "verify_ssl"),
        "grpc_address": hcl_text_value(text, "grpc_address"),
        "ca_file": hcl_text_value(text, "ca_file"),
        "workload_identity": "true" if service else "false",
        "aud": hcl_text_value(service, "aud"),
        "ttl": hcl_text_value(service, "ttl"),
    }


def list_host_volumes() -> list[tuple[str, Path | None, str]]:
    """Return (name, path, read_only) for every managed host volume config."""
    volumes: list[tuple[str, Path | None, str]] = []
    if not CONFIG_DIR.is_dir():
        return volumes
    for config in sorted(CONFIG_DIR.glob("70-host-volume-*.hcl")):
        name = config.name[len("70-host-volume-"):-len(".hcl")]
        volumes.append((name, read_host_volume_path(name), hcl_text_value(read_config_text(config), "read_only")))
    return volumes




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


def vault_client_env_file_value(name: str) -> str:
    if not VAULT_CLIENT_ENV_FILE.is_file():
        return ""
    try:
        lines = VAULT_CLIENT_ENV_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, raw_value = stripped.split("=", 1)
        if key.strip() == name:
            return raw_value.strip().strip("'\"")
    return ""


def normalized_vault_addr(address: str) -> str:
    return with_default_scheme(address, "http").rstrip("/")


def vault_ca_cert_file(address: str = "") -> str:
    value = os.environ.get("VAULT_CACERT", "")
    if value:
        return value
    client_addr = vault_client_env_file_value("VAULT_ADDR")
    if address and client_addr and normalized_vault_addr(address) != normalized_vault_addr(client_addr):
        return ""
    return vault_client_env_file_value("VAULT_CACERT")


def detected_vault_addr() -> str:
    return os.environ.get("VAULT_ADDR", "") or vault_client_env_file_value("VAULT_ADDR") or DEFAULT_VAULT_ADDR


def shell_export_line(name: str, value: str) -> str:
    return f"export {name}={shlex.quote(value)}"


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
    values = vault_config_values()
    if values:
        doctor_info(f"address   = {unset_label(values['address'])}")
        doctor_info(f"auth path = {unset_label(values['jwt_auth_backend_path'])}")
        doctor_info(f"namespace = {unset_label(values['namespace'])}")
        doctor_info(f"ca_file   = {unset_label(values['ca_file'])}")
        doctor_info(f"identity  = aud {unset_label(values['aud'])}, ttl {unset_label(values['ttl'])}, "
                    f"env {values['env'] or 'false'}, file {values['file'] or 'false'}")
    if doctor_config_file(VAULT_CONFIG, "Vault") == 1:
        failures += 1
    for key in ("ca_file", "cert_file"):
        value = values.get(key, "")
        if value and not Path(value).is_file():
            doctor_check("FAIL", f"Vault {key} missing: {value}")
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
        code = http_status(health_url, cafile=vault_ca_cert_file(base))
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
            cacert = vault_ca_cert_file(base)
            if cacert:
                env.setdefault("VAULT_CACERT", cacert)
            if namespace:
                env["VAULT_NAMESPACE"] = namespace
            if run(["vault", "status"], check=False, env=env, capture=True).returncode == 0:
                doctor_check("OK", "vault status succeeded")
            else:
                doctor_check("WARN", "vault status failed; check token, TLS and namespace")
    return failures


def cmd_consul_doctor(args: argparse.Namespace) -> int:
    failures = 0
    values = consul_config_values()
    if values:
        doctor_info(f"address      = {unset_label(values['address'])}")
        doctor_info(f"ssl          = {values['ssl'] or 'false'} (verify {values['verify_ssl'] or 'false'})")
        doctor_info(f"grpc_address = {unset_label(values['grpc_address'])}")
        doctor_info(f"workload id  = {values['workload_identity']}"
                    + (f" (aud {values['aud']}, ttl {values['ttl']})" if values["workload_identity"] == "true" else ""))
    if doctor_config_file(CONSUL_CONFIG, "Consul") == 1:
        failures += 1
    metadata = consul_install_metadata()
    address = args.address or hcl_file_string_value(CONSUL_CONFIG, "address")
    if not address and metadata:
        address = local_consul_address(metadata)
    ssl_value = args.ssl
    if ssl_value is None:
        ssl_value = parse_bool(hcl_file_bool_value(CONSUL_CONFIG, "ssl") or "false")
    failures += doctor_nomad_config()
    if metadata:
        doctor_check("OK", f"Local consul-manager install detected: {CONSUL_INSTALL_METADATA_FILE}")
        acl_on = bool(metadata.get("acl_enabled", True))
        doctor_check("OK", f"Local Consul ACL enabled: {str(acl_on).lower()}")
    else:
        acl_on = None
        doctor_check("WARN", "No local consul-manager install detected; assuming a remote Consul")
    workload_identity = CONSUL_CONFIG.is_file() and "service_identity" in CONSUL_CONFIG.read_text(encoding="utf-8")
    if acl_on is not None and workload_identity != acl_on:
        doctor_check(
            "FAIL",
            f"Nomad workload identity is {'on' if workload_identity else 'off'} but Consul ACL is "
            f"{'on' if acl_on else 'off'}; run {NOMAD_MANAGER_CMD} consul setup-local",
        )
        failures += 1
    if acl_on:
        if CONSUL_TOKEN_ENV_FILE.is_file() and CONSUL_TOKEN_DROPIN.is_file():
            doctor_check("OK", f"Nomad agent Consul token configured: {CONSUL_TOKEN_ENV_FILE}")
        else:
            doctor_check("FAIL", f"Consul ACL is on but no agent token is configured; run {NOMAD_MANAGER_CMD} consul token set")
            failures += 1
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
    values = docker_config_values()
    if values:
        doctor_info(f"allow_privileged = {values['allow_privileged']}")
        doctor_info(f"volumes.enabled  = {values['volumes']}")
        doctor_info(f"gc.image         = {values['image_gc']} (delay {unset_label(values['image_delay'])})")
        doctor_info(f"auth.config      = {unset_label(values['auth_config'])}")
    if doctor_config_file(DOCKER_CONFIG, "Docker") == 1:
        failures += 1
    if values.get("auth_config"):
        auth_path = Path(values["auth_config"])
        if auth_path.is_file():
            doctor_check("OK", f"Docker auth config exists: {auth_path}")
        else:
            doctor_check("FAIL", f"Docker auth config missing: {auth_path}")
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


def read_nomad_token() -> str:
    token = os.environ.get("NOMAD_TOKEN", "")
    if token:
        return token
    try:
        content = target_token_file().read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"(?m)^\s*export\s+NOMAD_TOKEN=(\S+)\s*$", content)
    return match.group(1) if match else ""


def nomad_cli(command: list[str], *, token: str = "") -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["NOMAD_ADDR"] = NOMAD_ADDR
    env["no_proxy"] = LOCAL_NO_PROXY
    env["NO_PROXY"] = LOCAL_NO_PROXY
    if token:
        env["NOMAD_TOKEN"] = token
    return run([str(BIN_PATH), *command], env=env, capture=True, check=False)


def doctor_node_runtime() -> int:
    """Version, ACL bootstrap state and whether this client can actually take work."""
    failures = 0
    recorded = read_installed_nomad_version()
    doctor_info(f"recorded version = {recorded}")
    doctor_info(f"tool revision    = {read_installed_tool_revision()}")
    actual = installed_binary_version()
    if actual:
        doctor_info(f"binary version   = {actual}")
        if recorded not in {"unknown", actual}:
            doctor_check("WARN", f"Binary version {actual} differs from recorded {recorded}; "
                                 f"run {NOMAD_MANAGER_CMD} upgrade to install a known release")
    token_file = target_token_file()
    token = read_nomad_token()
    if token_file.is_file():
        doctor_check("OK", f"ACL token file present: {token_file}")
    elif token:
        doctor_check("OK", "ACL token taken from NOMAD_TOKEN")
    else:
        doctor_check("WARN", f"No ACL token found; expected {token_file} or NOMAD_TOKEN")
    if not BIN_PATH.is_file():
        return failures
    if token:
        if nomad_cli(["acl", "token", "self"], token=token).returncode == 0:
            doctor_check("OK", "ACL token is accepted by Nomad")
        else:
            doctor_check("FAIL", "ACL token is rejected by Nomad; re-bootstrap or update the token file")
            failures += 1
    result = nomad_cli(["node", "status", "-self", "-json"], token=token)
    if result.returncode != 0:
        doctor_check("WARN", "Cannot read node status; the client may not be enabled on this agent")
        return failures
    try:
        node = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        doctor_check("WARN", "Node status returned unparsable JSON")
        return failures
    status = str(node.get("Status", "unknown"))
    eligibility = str(node.get("SchedulingEligibility", "unknown"))
    draining = bool(node.get("Drain", False))
    doctor_check("OK" if status == "ready" else "FAIL", f"Node status: {status}")
    if status != "ready":
        failures += 1
    doctor_check("OK" if eligibility == "eligible" else "FAIL", f"Scheduling eligibility: {eligibility}")
    if eligibility != "eligible":
        failures += 1
    if draining:
        doctor_check("FAIL", "Node is draining; no new allocations will be placed")
        failures += 1
    return failures


def doctor_managed_toggle(path: Path, label: str, values: dict[str, str], keys: list[str]) -> int:
    """Report a managed config that has no external dependency to verify."""
    if not path.exists():
        doctor_info(f"{label}: not configured")
        return 0
    if not is_managed_file(path):
        doctor_check("FAIL", f"{label} config exists but is not managed: {path}")
        return 1
    doctor_info(f"{label}: " + ", ".join(f"{key} {unset_label(values.get(key, ''))}" for key in keys))
    return 0


def doctor_node_configuration() -> int:
    failures = 0
    failures += doctor_managed_toggle(UI_CONFIG, "UI", ui_config_values(),
                                      ["enabled", "consul_url", "vault_url", "label"])
    failures += doctor_managed_toggle(TELEMETRY_CONFIG, "Telemetry", telemetry_config_values(),
                                      ["prometheus_metrics", "collection_interval"])
    tls_values = tls_config_values()
    failures += doctor_managed_toggle(TLS_CONFIG, "TLS", tls_values, ["http", "rpc", "verify_server_hostname"])
    for key in ("ca_file", "cert_file", "key_file"):
        value = tls_values.get(key, "")
        if not value:
            continue
        if Path(value).is_file():
            doctor_check("OK", f"TLS {key} exists: {value}")
        else:
            doctor_check("FAIL", f"TLS {key} missing: {value}; nomad.service will not start")
            failures += 1
    if RAW_EXEC_CONFIG.exists():
        if is_managed_file(RAW_EXEC_CONFIG):
            doctor_check("WARN", "raw_exec is enabled; tasks run on the host with no isolation")
        else:
            doctor_check("FAIL", f"raw_exec config exists but is not managed: {RAW_EXEC_CONFIG}")
            failures += 1
    else:
        doctor_info("raw_exec: not configured")
    denied = read_driver_denylist()
    doctor_info(f"Denied drivers: {', '.join(denied) if denied else '<none>'}")
    pairs = read_meta_pairs()
    doctor_info(f"Client meta: {', '.join(f'{k}={v}' for k, v in sorted(pairs.items())) if pairs else '<none>'}")
    return failures


def doctor_host_volumes() -> int:
    volumes = list_host_volumes()
    if not volumes:
        doctor_info("No managed host volumes")
        return 0
    failures = 0
    for name, path, read_only in volumes:
        mode = "read-only" if read_only == "true" else "read-write"
        if path is None:
            doctor_check("FAIL", f"{name}: config is unreadable or unmanaged: {host_volume_config_path(name)}")
            failures += 1
            continue
        doctor_info(f"{name} -> {path} ({mode})")
        if not path.exists():
            doctor_check("FAIL", f"{name}: host path does not exist: {path}")
            failures += 1
        elif not path.is_dir():
            doctor_check("FAIL", f"{name}: host path is not a directory: {path}")
            failures += 1
        elif not os.access(path, os.R_OK | os.X_OK):
            doctor_check("FAIL", f"{name}: host path is not readable: {path}")
            failures += 1
        else:
            doctor_check("OK", f"{name}: host path is usable")
    return failures


def cmd_doctor(args: argparse.Namespace) -> int:
    failures = 0
    doctor_check("OK" if sys.platform.startswith("linux") else "FAIL", f"platform: {sys.platform}")
    if not sys.platform.startswith("linux"):
        failures += 1
    if command_exists("systemctl"):
        doctor_check("OK", f"systemctl found: {shutil.which('systemctl')}")
        if run(["systemctl", "is-active", "--quiet", "nomad"], check=False).returncode == 0:
            doctor_check("OK", "nomad.service is active")
        else:
            doctor_check("FAIL", "nomad.service is not active")
            failures += 1
    else:
        doctor_check("FAIL", "systemctl not found")
        failures += 1
    if BIN_PATH.is_file():
        doctor_check("OK", f"Nomad binary found: {BIN_PATH}")
    else:
        doctor_check("FAIL", f"Nomad binary missing: {BIN_PATH}")
        failures += 1
    if BIN_ENTRY.exists() or BIN_ENTRY.is_symlink():
        doctor_check("OK", f"Nomad entry exists: {BIN_ENTRY}")
    else:
        doctor_check("WARN", f"Nomad entry missing: {BIN_ENTRY}")
    if SYSTEMD_SERVICE.is_file():
        doctor_check("OK", f"systemd service file found: {SYSTEMD_SERVICE}")
    else:
        doctor_check("FAIL", f"systemd service file missing: {SYSTEMD_SERVICE}")
        failures += 1
    failures += doctor_nomad_config()
    code = http_status(f"{NOMAD_ADDR}/v1/status/leader")
    if code == 200:
        doctor_check("OK", f"Nomad HTTP API reachable: {NOMAD_ADDR}")
    else:
        doctor_check("FAIL", f"Nomad HTTP API not reachable: {NOMAD_ADDR} ({code})")
        failures += 1
    print("\nNode runtime:")
    failures += doctor_node_runtime()
    print("\nBase configuration:")
    failures += doctor_base_configuration()
    print("\nNode configuration:")
    failures += doctor_node_configuration()
    print("\nHost volumes:")
    failures += doctor_host_volumes()
    if args.integrations or DOCKER_CONFIG.is_file():
        print("\nDocker checks:")
        failures += cmd_docker_doctor(argparse.Namespace())
    if args.integrations or CNI_CLIENT_CONFIG.is_file():
        print("\nCNI checks:")
        failures += cmd_cni_status(argparse.Namespace())
    if args.integrations or VAULT_CONFIG.is_file():
        print("\nVault checks:")
        failures += cmd_vault_doctor(argparse.Namespace(address=None, namespace=None))
    if args.integrations or CONSUL_CONFIG.is_file():
        print("\nConsul checks:")
        failures += cmd_consul_doctor(argparse.Namespace(address=None, ssl=None))
    if failures == 0:
        print("\nAll checks passed.")
    return 0 if failures == 0 else 1


def status_line(key: str, value: str) -> None:
    print(f"  {key:<22} {value}")


def cmd_status(_: argparse.Namespace) -> int:
    """Show what is configured. doctor answers whether it is healthy."""
    print("Install:")
    status_line("recorded version", read_installed_nomad_version())
    if BIN_PATH.is_file():
        status_line("binary version", installed_binary_version() or "unknown")
    status_line("binary", str(BIN_PATH) if BIN_PATH.is_file() else "<not installed>")
    linked = linked_binary_path(BIN_PATH)
    if linked:
        status_line("binary release", str(linked))
    kept = [path.name for path in kept_binary_versions(BINARY_VERSION_DIR, "nomad")]
    if kept:
        status_line("kept releases", ", ".join(kept))
    status_line("config dir", str(CONFIG_DIR))
    status_line("data dir", str(DATA_DIR))
    status_line("tool dir", str(TOOL_DIR) if TOOL_DIR.is_dir() else "<not installed>")
    status_line("tool revision", read_installed_tool_revision())
    if command_exists("systemctl"):
        active = run(["systemctl", "is-active", "nomad"], check=False, capture=True)
        status_line("service", (active.stdout or "").strip() or "unknown")
    status_line("api", f"{NOMAD_ADDR} ({http_status(f'{NOMAD_ADDR}/v1/status/leader')})")
    status_line("acl token file", str(target_token_file()) if target_token_file().is_file() else "<absent>")

    print("\nBase configuration:")
    base = base_config_values()
    if not base:
        print(f"  <not readable: {NOMAD_CONFIG_FILE}>")
    else:
        status_line("datacenter", unset_label(base["datacenter"]))
        status_line("bind_addr", unset_label(base["bind_addr"]))
        status_line("roles", f"server {base['server'] or 'false'}, client {base['client'] or 'false'}")
        status_line("job_gc_threshold", unset_label(base["job_gc_threshold"]))
        status_line("acl", base["acl"] or "false")

    print("\nManaged configuration:")
    docker = docker_config_values()
    status_line("docker", f"allow_privileged {docker['allow_privileged']}, volumes {docker['volumes']}, "
                          f"image gc {docker['image_gc']} (delay {unset_label(docker['image_delay'])}), "
                          f"auth {unset_label(docker['auth_config'])}" if docker else "<not configured>")
    cni_version = installed_cni_version()
    status_line("cni", f"plugins {unset_label(cni_version)} in {CNI_BIN_DIR}" if CNI_CLIENT_CONFIG.is_file() else "<not configured>")
    status_line("raw_exec", "enabled" if RAW_EXEC_CONFIG.is_file() else "<not configured>")
    denied = read_driver_denylist()
    status_line("denied drivers", ", ".join(denied) if denied else "<none>")
    vault = vault_config_values()
    status_line("vault", f"{unset_label(vault['address'])}, auth path {unset_label(vault['jwt_auth_backend_path'])}, "
                         f"aud {unset_label(vault['aud'])}, ttl {unset_label(vault['ttl'])}" if vault else "<not configured>")
    consul = consul_config_values()
    status_line("consul", f"{unset_label(consul['address'])}, ssl {consul['ssl'] or 'false'}, "
                          f"workload identity {consul['workload_identity']}" if consul else "<not configured>")
    ui = ui_config_values()
    status_line("ui", f"enabled {ui['enabled']}, label {unset_label(ui['label'])}" if ui else "<not configured>")
    tls = tls_config_values()
    status_line("tls", f"http {tls['http']}, rpc {tls['rpc']}, ca {unset_label(tls['ca_file'])}" if tls else "<not configured>")
    telemetry = telemetry_config_values()
    status_line("telemetry", f"prometheus {telemetry['prometheus_metrics']}, "
                             f"interval {telemetry['collection_interval']}" if telemetry else "<not configured>")

    print("\nHost volumes:")
    volumes = list_host_volumes()
    if not volumes:
        print("  <none>")
    for name, path, read_only in volumes:
        mode = "read-only" if read_only == "true" else "read-write"
        state = "missing" if path is None or not path.is_dir() else "ok"
        status_line(name, f"{path or '<unreadable>'} ({mode}, {state})")

    print("\nClient meta:")
    pairs = read_meta_pairs()
    if not pairs:
        print("  <none>")
    for key in sorted(pairs):
        status_line(key, pairs[key])
    print(f"\nRun '{NOMAD_MANAGER_CMD} doctor' to check whether any of this is broken.")
    return 0


PROFILE_DEFAULTS: dict[str, Any] = {
    "auth_path": "jwt-nomad",
    "role": "nomad-workloads",
    "policy": "nomad-workloads",
    "aud": "vault.io",
    "ttl": "1h",
    "secret_paths": ["kv/data/*"],
    "policy_file": "",
    "vault_namespace": "",
}


def arrow_glyphs() -> tuple[str, str]:
    """Box-drawing when the terminal can render it, plain ASCII otherwise."""
    return ("\u2502", "\u25bc") if terminal_supports_checkmark() else ("|", "v")


def jwt_wiring_diagram(data: dict[str, Any], links: dict[str, list[tuple[str, str]]] | None = None) -> str:
    """Show how the flags chain together, using this profile's real values.

    links maps a stage key to extra (status, message) lines, so doctor can mark
    which link in the chain is broken.
    """
    pipe, down = arrow_glyphs()
    secret_paths = ", ".join(data["secret_paths"])
    stages = [
        (
            "nomad",
            "Nomad signs a JWT for each task",
            [("audience", data["aud"], "--aud"),
             ("published", data["nomad_jwks_url"], "--nomad-addr")],
        ),
        (
            "auth",
            f"Vault auth mount   auth/{data['auth_path']}",
            [("validates", "the JWT against that JWKS URL", "--auth-path")],
        ),
        (
            "role",
            f"Vault role         {data['role']}",
            [("issues", f"tokens with TTL {data['ttl']}", "--ttl")],
        ),
        (
            "policy",
            f"Vault policy       {data['policy']}",
            [("grants", f"read on {secret_paths}", "--secret-path")],
        ),
    ]
    lines: list[str] = []
    for index, (key, title, rows) in enumerate(stages):
        lines.append(f"  {title}")
        for label, value, flag in rows:
            lines.append(f"      {label:<10} {value:<42} {flag}")
        for status, message in (links or {}).get(key, []):
            lines.append(f"{status:<5} {message}")
        if index < len(stages) - 1:
            lines.append(f"                            {pipe}")
            lines.append(f"                            {down}")
    return "\n".join(lines)


def profile_header(data: dict[str, Any]) -> str:
    lines = [f"Profile:  {data['profile']}  ->  {profile_path(data['profile'])}"]
    extras = []
    if data.get("vault_namespace"):
        extras.append(f"namespace {data['vault_namespace']}")
    if data.get("policy_file"):
        extras.append(f"policy file {data['policy_file']}")
    extras.append(f"vault {data['vault_addr']}")
    lines.append(f"          {', '.join(extras)}")
    return "\n".join(lines)


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
        "auth_path": args.auth_path or existing.get("auth_path", PROFILE_DEFAULTS["auth_path"]),
        "role": args.role or existing.get("role", PROFILE_DEFAULTS["role"]),
        "policy": args.policy or existing.get("policy", PROFILE_DEFAULTS["policy"]),
        "aud": args.aud or existing.get("aud", PROFILE_DEFAULTS["aud"]),
        "ttl": args.ttl or existing.get("ttl", PROFILE_DEFAULTS["ttl"]),
        "secret_paths": args.secret_path or existing.get("secret_paths", list(PROFILE_DEFAULTS["secret_paths"])),
        "policy_file": args.policy_file if args.policy_file is not None else existing.get("policy_file", ""),
    }
    if not data["nomad_jwks_url"] and data["nomad_addr"]:
        data["nomad_jwks_url"] = derived_jwks_url(data["nomad_addr"])
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


def shell_command(args: list[str]) -> str:
    return " ".join(shlex.quote(str(item)) for item in args)


def derived_jwks_url(nomad_addr: str) -> str:
    return f"{str(nomad_addr).rstrip('/')}/.well-known/jwks.json"


def vault_jwt_apply_command(data: dict[str, Any], *, force: bool = False) -> str:
    """The shortest command that reproduces this profile.

    Values equal to the defaults are omitted, so the printed command stays
    readable instead of restating every flag.
    """
    command = [
        NOMAD_MANAGER_CMD, "vault", "jwt", "apply",
        "--profile", data["profile"],
        "--vault-addr", data["vault_addr"],
        "--nomad-addr", data["nomad_addr"],
    ]
    for flag, key in (("--auth-path", "auth_path"), ("--role", "role"),
                      ("--policy", "policy"), ("--aud", "aud"), ("--ttl", "ttl")):
        if data[key] != PROFILE_DEFAULTS[key]:
            command.extend([flag, data[key]])
    if data.get("vault_namespace"):
        command.extend(["--vault-namespace", data["vault_namespace"]])
    if data.get("nomad_jwks_url") and data["nomad_jwks_url"] != derived_jwks_url(data["nomad_addr"]):
        command.extend(["--nomad-jwks-url", data["nomad_jwks_url"]])
    if data["secret_paths"] != PROFILE_DEFAULTS["secret_paths"]:
        for secret_path in data["secret_paths"]:
            command.extend(["--secret-path", secret_path])
    if data.get("policy_file"):
        command.extend(["--policy-file", data["policy_file"]])
    if force:
        command.append("--force")
    return shell_command(command)


def cmd_vault_jwt_plan(args: argparse.Namespace) -> int:
    data = prepare_profile(args)
    print(profile_header(data))
    print()
    print(jwt_wiring_diagram(data))
    print()
    failures = vault_jwt_preflight(data)
    print(
        "\nPlan:\n"
        f"  [1/7] Enable Vault JWT auth at auth/{data['auth_path']} if missing\n"
        f"  [2/7] Write Vault JWT config with jwks_url={data['nomad_jwks_url']}\n"
        f"  [3/7] Write Vault policy {data['policy']}\n"
        f"  [4/7] Write Vault role {data['role']}\n"
        f"  [5/7] Write Nomad vault config {VAULT_CONFIG}\n"
        "  [6/7] Validate Nomad config and restart nomad.service\n"
        f"  [7/7] Save profile {profile_path(data['profile'])}\n\n"
        f"Next:\n  {vault_jwt_apply_command(data, force=args.force)}\n\n"
        f"The profile stores all of this, so later commands only need --profile {data['profile']}:\n"
        f"  {NOMAD_MANAGER_CMD} vault jwt doctor --profile {data['profile']}"
    )
    return 0 if failures == 0 else 1


def write_profile(data: dict[str, Any]) -> None:
    run_root(["install", "-d", "-m", "0700", str(VAULT_JWT_PROFILE_DIR)])
    install_text(profile_path(data["profile"]), json.dumps(data, indent=2, sort_keys=True) + "\n", mode="0600")
    log_success(f"Vault JWT profile saved: {profile_path(data['profile'])}")


def vault_env(data: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    env["VAULT_ADDR"] = data["vault_addr"]
    cacert = vault_ca_cert_file(data["vault_addr"])
    if cacert:
        env.setdefault("VAULT_CACERT", cacert)
    if data.get("vault_namespace"):
        env["VAULT_NAMESPACE"] = data["vault_namespace"]
    return env


def vault_cmd(data: dict[str, Any], command: list[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["vault", *command], env=vault_env(data), capture=capture, check=check)


def vault_status_json_for_jwt(data: dict[str, Any]) -> dict[str, Any] | None:
    result = vault_cmd(data, ["status", "-format=json"], capture=True, check=False)
    if result.returncode not in {0, 2}:
        return None
    try:
        parsed = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def vault_auth_type(data: dict[str, Any]) -> str:
    result = vault_cmd(data, ["auth", "list", "-format=json"], capture=True, check=False)
    if result.returncode != 0:
        return ""
    parsed = json.loads(result.stdout or "{}")
    return parsed.get(f"{data['auth_path'].rstrip('/')}/", {}).get("type", "")


def vault_token_has_capability(data: dict[str, Any], path: str, required: set[str]) -> bool:
    result = vault_cmd(data, ["token", "capabilities", path], capture=True, check=False)
    if result.returncode != 0:
        return False
    capabilities = set((result.stdout or "").split())
    return "root" in capabilities or bool(capabilities.intersection(required))


def vault_jwt_preflight(data: dict[str, Any]) -> int:
    """Report every problem at once; the caller aborts if anything failed.

    Connectivity comes first because a wrong --vault-addr or --nomad-addr is the
    most common failure, and a missing vault CLI no longer hides the rest.
    """
    failures = 0
    print("Connectivity:")
    health_url = f"{str(data['vault_addr']).rstrip('/')}/v1/sys/health"
    code = http_status(health_url, cafile=vault_ca_cert_file(data["vault_addr"]))
    if code in {200, 429, 472, 473, 501, 503}:
        doctor_check("OK", f"Vault reachable: {health_url} ({code})")
    else:
        doctor_check("FAIL", f"Vault not reachable: {health_url} ({code})")
        doctor_check("INFO", f"Vault may be down, or --vault-addr may be wrong: {data['vault_addr']}")
        failures += 1
    if wait_http(data["nomad_jwks_url"], attempts=1, delay=0):
        doctor_check("OK", f"Nomad JWKS reachable: {data['nomad_jwks_url']}")
    else:
        doctor_check("FAIL", f"Nomad JWKS not reachable: {data['nomad_jwks_url']}")
        doctor_check("INFO", f"Nomad may be down, or --nomad-addr may be wrong: {data['nomad_addr']}")
        failures += 1
    if data["nomad_jwks_url"] != derived_jwks_url(data["nomad_addr"]):
        doctor_check("INFO", "This JWKS URL was probed from this host, but Vault is the one that fetches it")
        doctor_check("INFO", f"Confirm from the Vault server: curl {data['nomad_jwks_url']}")

    print("\nVault state:")
    has_cli = command_exists("vault")
    if has_cli:
        doctor_check("OK", f"vault CLI found: {shutil.which('vault')}")
    else:
        doctor_check("FAIL", "vault CLI not found; Vault state and permission checks are skipped")
        failures += 1

    status = vault_status_json_for_jwt(data) if has_cli else None
    if status is None:
        doctor_check("FAIL", "vault status failed; check Vault address, TLS and namespace")
        failures += 1
    else:
        if status.get("initialized") is True:
            doctor_check("OK", "Vault is initialized")
        else:
            doctor_check("FAIL", "Vault is not initialized")
            failures += 1
        if status.get("sealed") is True:
            doctor_check("FAIL", "Vault is sealed; run vault-manager unseal --keys-file /opt/vault/init/vault-init.json")
            failures += 1
        elif status.get("sealed") is False:
            doctor_check("OK", "Vault is unsealed")
        else:
            doctor_check("FAIL", "Vault seal status is unknown")
            failures += 1

    print("\nVault permissions:")
    auth_type = ""
    reachable = has_cli and status is not None and status.get("sealed") is False
    if not has_cli:
        doctor_check("WARN", "Skipped: install the vault CLI to check auth path and token permissions")
    elif not reachable:
        doctor_check("WARN", "Skipped: Vault must be reachable and unsealed before permissions can be checked")
    if reachable:
        auth_list = vault_cmd(data, ["auth", "list", "-format=json"], capture=True, check=False)
        if auth_list.returncode != 0:
            doctor_check("FAIL", "Vault token cannot list auth methods; check VAULT_TOKEN permissions")
            failures += 1
        else:
            try:
                auth_data = json.loads(auth_list.stdout or "{}")
            except json.JSONDecodeError:
                auth_data = {}
            auth_type = auth_data.get(f"{data['auth_path'].rstrip('/')}/", {}).get("type", "")
            if not auth_type:
                doctor_check("OK", f"Vault auth path auth/{data['auth_path']} is available")
            elif auth_type == "jwt":
                doctor_check("OK", f"Vault auth path auth/{data['auth_path']} already uses jwt")
            else:
                doctor_check("FAIL", f"Vault auth path auth/{data['auth_path']} already exists with type {auth_type}")
                failures += 1

        token_result = vault_cmd(data, ["token", "lookup", "-format=json"], capture=True, check=False)
        if token_result.returncode == 0:
            doctor_check("OK", "Vault token lookup succeeded")
            capability_checks = [
                (f"sys/auth/{data['auth_path']}", {"create", "update", "sudo"}, "enable Vault auth method"),
                (f"auth/{data['auth_path']}/config", {"create", "update", "sudo"}, "write Vault JWT auth config"),
                (f"sys/policies/acl/{data['policy']}", {"create", "update", "sudo"}, "write Vault policy"),
                (f"auth/{data['auth_path']}/role/{data['role']}", {"create", "update", "sudo"}, "write Vault JWT role"),
            ]
            for path, required, label in capability_checks:
                if vault_token_has_capability(data, path, required):
                    doctor_check("OK", f"Vault token can {label}: {path}")
                else:
                    doctor_check("FAIL", f"Vault token cannot {label}: {path}")
                    failures += 1
        else:
            doctor_check("FAIL", "Vault token lookup failed; set VAULT_TOKEN or use a token with management permissions")
            failures += 1

    print("\nSecret paths:")
    if reachable:
        failures += doctor_secret_mounts(data)
    else:
        doctor_check("WARN", "Skipped: Vault must be reachable and unsealed to list secrets engines")

    print("\nLocal inputs:")
    policy_file = data.get("policy_file")
    if policy_file and not Path(policy_file).is_file():
        doctor_check("FAIL", f"Policy file not found: {policy_file}")
        failures += 1
    elif policy_file:
        doctor_check("OK", f"Policy file readable: {policy_file}")
    else:
        doctor_check("OK", "Vault policy will be generated")

    return failures


def vault_path_matches(pattern: str, path: str) -> bool:
    """Match a path against a Vault policy path.

    Vault's globbing is not fnmatch: `*` is a wildcard only as the final
    character, and `+` matches exactly one path segment. A `*` anywhere else is
    a literal character.
    """
    prefix = pattern.endswith("*")
    core = pattern[:-1] if prefix else pattern
    segments = ["[^/]+" if segment == "+" else re.escape(segment) for segment in core.split("/")]
    return bool(re.fullmatch("/".join(segments) + (".*" if prefix else ""), path))


def secret_path_mount(secret_path: str) -> str:
    """The mount a policy path lives under, i.e. its first segment."""
    return secret_path.split("/", 1)[0]


def vault_secret_mounts(data: dict[str, Any]) -> dict[str, Any]:
    result = vault_cmd(data, ["secrets", "list", "-format=json"], capture=True, check=False)
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def doctor_secret_mounts(data: dict[str, Any]) -> int:
    """Vault accepts a policy for a mount that does not exist.

    Writing the policy succeeds, doctor sees every object in place, and the job
    only fails when a template tries to read the secret. Check the mounts here
    instead.
    """
    failures = 0
    if data.get("policy_file"):
        doctor_check("INFO", "Using a policy file; its paths are not checked against Vault mounts")
        return failures
    mounts = vault_secret_mounts(data)
    if not mounts:
        doctor_check("WARN", "Cannot list Vault secrets engines; skipping secret path checks")
        return failures
    for secret_path in data["secret_paths"]:
        mount = secret_path_mount(secret_path)
        entry = mounts.get(f"{mount}/")
        if not isinstance(entry, dict):
            doctor_check("FAIL", f"No secrets engine mounted at {mount}/ for {secret_path}")
            doctor_check("INFO", f"Enable it with: vault secrets enable -path={mount} kv-v2")
            failures += 1
            continue
        engine = str(entry.get("type", ""))
        version = str((entry.get("options") or {}).get("version", ""))
        if engine == "kv" and version == "2":
            if "/data/" in secret_path:
                doctor_check("OK", f"{secret_path} matches the kv-v2 mount at {mount}/")
            else:
                doctor_check("FAIL", f"{mount}/ is kv-v2, so the path needs a /data/ segment: {secret_path}")
                doctor_check("INFO", f"For secret {mount}/app/config the policy path is {mount}/data/app/config")
                failures += 1
        elif engine == "kv":
            if "/data/" in secret_path:
                doctor_check("FAIL", f"{mount}/ is kv v1, which has no /data/ segment: {secret_path}")
                failures += 1
            else:
                doctor_check("OK", f"{secret_path} matches the kv v1 mount at {mount}/")
        else:
            doctor_check("INFO", f"{mount}/ is a {engine} engine; path structure is not checked")
    return failures


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
    failures = vault_jwt_preflight(data)
    if failures:
        sys.stdout.flush()
        raise CLIError("Vault JWT preflight failed; no changes were applied")
    auth_type = vault_auth_type(data)
    if not auth_type:
        log_info(f"Enabling Vault JWT auth: {data['auth_path']}")
        vault_cmd(data, ["auth", "enable", f"-path={data['auth_path']}", "jwt"])
    elif auth_type != "jwt":
        raise CLIError(f"Vault auth path {data['auth_path']} already exists with type {auth_type}")
    else:
        log_success(f"Vault JWT auth already enabled: {data['auth_path']}")
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
    cmd_vault_enable(
        argparse.Namespace(
            address=data["vault_addr"],
            namespace=data.get("vault_namespace", ""),
            jwt_auth_backend_path=data["auth_path"],
            aud=data["aud"],
            ttl=data["ttl"],
            env=False,
            file=True,
            ca_file=vault_ca_cert_file(data["vault_addr"]),
            ca_path="",
            cert_file="",
            key_file="",
        )
    )
    write_profile(data)
    print()
    print(jwt_wiring_diagram(data))
    print(f"\nSaved to {profile_path(data['profile'])}. "
          f"Later commands only need --profile {data['profile']}:")
    print(f"  {NOMAD_MANAGER_CMD} vault jwt doctor --profile {data['profile']}")
    print(f"  {NOMAD_MANAGER_CMD} vault jwt job-example --profile {data['profile']} --job web --secret kv/data/app/config")
    return 0


def vault_read_json(data: dict[str, Any], path: str) -> dict[str, Any]:
    result = vault_cmd(data, ["read", "-format=json", path], capture=True, check=False)
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return {}
    body = payload.get("data") if isinstance(payload, dict) else None
    return body if isinstance(body, dict) else {}


def vault_jwt_status_impl(profile: str) -> int:
    """Walk the chain and report where it is broken, not just what is missing.

    Each stage is checked for existence and for agreement with the neighbour it
    points at, which is how a stale jwks_url or audience is caught.
    """
    data = load_profile(profile)
    failures = 0
    links: dict[str, list[tuple[str, str]]] = {"nomad": [], "auth": [], "role": [], "policy": []}

    def note(stage: str, status: str, message: str) -> None:
        nonlocal failures
        links[stage].append((status, message))
        if status == "FAIL":
            failures += 1

    if wait_http(data["nomad_jwks_url"], attempts=1, delay=0):
        note("nomad", "OK", "JWKS endpoint reachable")
    else:
        note("nomad", "FAIL", f"JWKS endpoint not reachable: {data['nomad_jwks_url']}")

    if VAULT_CONFIG.is_file():
        nomad_config = VAULT_CONFIG.read_text(encoding="utf-8")
        configured_path = hcl_file_string_value(VAULT_CONFIG, "jwt_auth_backend_path")
        if configured_path == data["auth_path"]:
            note("auth", "OK", f"Nomad config points at auth/{configured_path}")
        else:
            note("auth", "FAIL",
                 f"Nomad config uses auth path {configured_path or '<unset>'}, profile says {data['auth_path']}")
        if data["aud"] in nomad_config:
            note("nomad", "OK", f"Nomad config signs for audience {data['aud']}")
        else:
            note("nomad", "FAIL", f"Nomad config does not list audience {data['aud']}")
    else:
        note("auth", "FAIL", f"Nomad vault config missing: {VAULT_CONFIG}")

    if not command_exists("vault"):
        note("auth", "FAIL", "vault CLI not found; the Vault side cannot be checked")
        print(profile_header(data))
        print()
        print(jwt_wiring_diagram(data, links))
        return failures

    if vault_auth_type(data) == "jwt":
        note("auth", "OK", f"Vault mount auth/{data['auth_path']} exists, type jwt")
        auth_config = vault_read_json(data, f"auth/{data['auth_path']}/config")
        vault_jwks = str(auth_config.get("jwks_url", ""))
        if not auth_config:
            note("auth", "FAIL", "Vault JWT auth config is unreadable")
        elif vault_jwks == data["nomad_jwks_url"]:
            note("auth", "OK", "Vault validates against the same JWKS URL")
        else:
            note("auth", "FAIL",
                 f"Vault validates against {vault_jwks or '<unset>'}, which is not the URL above")
    else:
        note("auth", "FAIL", f"Vault mount auth/{data['auth_path']} missing or not jwt")

    role = vault_read_json(data, f"auth/{data['auth_path']}/role/{data['role']}")
    if role:
        note("role", "OK", f"Vault role {data['role']} exists")
        bound = [str(item) for item in role.get("bound_audiences") or []]
        expected = parse_csv(data["aud"])
        if set(expected) <= set(bound):
            note("role", "OK", f"Role accepts audience {', '.join(expected)}")
        else:
            note("role", "FAIL",
                 f"Role accepts {', '.join(bound) or '<none>'}, but Nomad signs {', '.join(expected)}")
        policies = [str(item) for item in role.get("token_policies") or []]
        if data["policy"] in policies:
            note("role", "OK", f"Role grants policy {data['policy']}")
        else:
            note("role", "FAIL",
                 f"Role grants {', '.join(policies) or '<none>'}, not {data['policy']}")
    else:
        note("role", "FAIL", f"Vault role {data['role']} missing")

    if vault_cmd(data, ["policy", "read", data["policy"]], check=False, capture=True).returncode == 0:
        note("policy", "OK", f"Vault policy {data['policy']} exists")
    else:
        note("policy", "FAIL", f"Vault policy {data['policy']} missing")
    if not data.get("policy_file"):
        mounts = vault_secret_mounts(data)
        for secret_path in data["secret_paths"]:
            mount = secret_path_mount(secret_path)
            if isinstance(mounts.get(f"{mount}/"), dict):
                note("policy", "OK", f"Secrets engine mounted at {mount}/")
            elif mounts:
                note("policy", "FAIL",
                     f"No secrets engine at {mount}/; enable it with "
                     f"vault secrets enable -path={mount} kv-v2")

    print(profile_header(data))
    print()
    print(jwt_wiring_diagram(data, links))
    return failures


def cmd_vault_jwt_doctor(args: argparse.Namespace) -> int:
    failures = vault_jwt_status_impl(args.profile)
    if failures == 0:
        print("\nAll checks passed.")
        return 0
    print(f"\nFix:\n  {NOMAD_MANAGER_CMD} vault jwt apply --profile {args.profile}")
    return 1


def require_secret_is_granted(data: dict[str, Any], secret: str) -> None:
    """The generated job would deploy fine and fail at render time otherwise.

    The policy grants specific paths; a template reading anything else gets a
    403 from Vault, several steps after the mistake was made.
    """
    if data.get("policy_file"):
        log_warn(f"Profile {data['profile']} uses a policy file; {secret} is not checked against it")
        return
    if any(vault_path_matches(pattern, secret) for pattern in data["secret_paths"]):
        return
    granted = ", ".join(data["secret_paths"])
    raise CLIError(
        f"Secret {secret} is not granted by profile {data['profile']}.\n"
        f"  The policy grants: {granted}\n"
        f"  Either read a granted path, or widen the policy:\n"
        f"    {NOMAD_MANAGER_CMD} vault jwt apply --profile {data['profile']} --secret-path {shlex.quote(secret)}"
    )


def cmd_vault_jwt_job_example(args: argparse.Namespace) -> int:
    data = load_profile(args.profile)
    validate_name(args.job, "job name")
    require_secret_is_granted(data, args.secret)
    content = f"""# Generated by nomad-manager vault jwt job-example
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
{{{{ with index .Data.data "value" }}}}SECRET_VALUE={{{{ . }}}}{{{{ end }}}}
{{{{ with index .Data.data "username" }}}}APP_USERNAME={{{{ . }}}}{{{{ end }}}}
{{{{ with index .Data.data "password" }}}}APP_PASSWORD={{{{ . }}}}{{{{ end }}}}
{{{{ with index .Data.data "api_key" }}}}APP_API_KEY={{{{ . }}}}{{{{ end }}}}
{{{{ end }}}}
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
        log_success(f"Job example written: {args.out}")
    return 0


def exported_job_filename(job_id: str) -> str:
    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", job_id).strip("._")
    if not safe_name:
        safe_name = "job"
    if safe_name != job_id:
        digest = hashlib.sha256(job_id.encode("utf-8")).hexdigest()[:8]
        safe_name = f"{safe_name}-{digest}"
    return f"{safe_name}.nomad.hcl"


def job_id_from_status_item(item: object) -> str:
    if isinstance(item, str):
        return item
    if not isinstance(item, dict):
        return ""
    for key in ("ID", "JobID", "Name"):
        value = item.get(key)
        if value:
            return str(value)
    for key in ("Summary", "LatestDeployment"):
        value = item.get(key)
        if isinstance(value, dict) and value.get("JobID"):
            return str(value["JobID"])
    for key in ("Allocations", "Evaluations"):
        value = item.get(key)
        if isinstance(value, list):
            for child in value:
                if isinstance(child, dict) and child.get("JobID"):
                    return str(child["JobID"])
    return ""


def extract_job_status_items(payload: object) -> list[object]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("Jobs", "jobs", "Items", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
    return []


def parse_nomad_job_status_text(output: str) -> list[str]:
    job_ids: list[str] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line == "ID" or line.startswith(("==>", "ID ", "ID\t", "No ")):
            continue
        parts = line.split()
        if parts:
            job_ids.append(parts[0])
    return sorted(set(job_ids))


def nomad_job_status_text_has_no_jobs(output: str) -> bool:
    return any(
        line.strip().lower().startswith("no ") and "job" in line.lower()
        for line in output.splitlines()
    )


def list_nomad_job_ids() -> list[str]:
    require_command("nomad")
    text_result = run(["nomad", "job", "status"], capture=True, check=False)
    if text_result.returncode != 0:
        message = (text_result.stderr or text_result.stdout or "nomad job status failed").strip()
        raise CLIError(message)
    job_ids = parse_nomad_job_status_text(text_result.stdout)
    if job_ids:
        return job_ids
    if nomad_job_status_text_has_no_jobs(text_result.stdout):
        return []
    json_result = run(["nomad", "job", "status", "-json"], capture=True, check=False)
    if json_result.returncode == 0:
        try:
            payload = json.loads(json_result.stdout or "[]")
        except json.JSONDecodeError:
            payload = []
        items = extract_job_status_items(payload)
        job_ids = sorted({job_id for item in items if (job_id := job_id_from_status_item(item))})
        if job_ids:
            return job_ids
        if items:
            raise CLIError("Nomad job status JSON did not contain recognizable job IDs")
    message = (json_result.stderr or "Nomad job status output did not contain recognizable job IDs").strip()
    raise CLIError(message)


def export_nomad_job(job_id: str, output_dir: Path, *, force: bool) -> Path:
    require_command("nomad")
    result = run(["nomad", "job", "inspect", "-hcl", job_id], capture=True)
    content = result.stdout if result.stdout.endswith("\n") else result.stdout + "\n"
    output_path = output_dir / exported_job_filename(job_id)
    atomic_write_text(output_path, content, force=force)
    return output_path


def cmd_export(args: argparse.Namespace) -> int:
    jobs = list(args.jobs)
    if not jobs:
        jobs = list_nomad_job_ids()
    if not jobs:
        log_warn("No Nomad jobs found")
        return 0
    output_dir = Path(args.out_dir)
    for job_id in jobs:
        output_path = export_nomad_job(job_id, output_dir, force=args.force)
        log_success(f"Exported Nomad job {job_id}: {output_path}")
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
        (HOST_VOLUME_DIR, "0755", "root", "root"),
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


GO_DURATION_PATTERN = re.compile(r"^[0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h)([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))*$")


def validate_go_duration(value: str, label: str) -> str:
    if not GO_DURATION_PATTERN.match(value):
        raise CLIError(f"Invalid {label}: {value}. Use a Go duration such as 4h, 30m or 87600h")
    return value


def write_nomad_config(job_gc_threshold: str = DEFAULT_JOB_GC_THRESHOLD) -> None:
    validate_go_duration(job_gc_threshold, "job GC threshold")
    content = f"""datacenter = "dc1"
data_dir   = "{NOMAD_AGENT_DATA_DIR}"
bind_addr  = "0.0.0.0"
log_level  = "INFO"

server {{
  enabled          = true
  bootstrap_expect = 1
  job_gc_threshold = "{job_gc_threshold}"
}}

client {{
  enabled = true
  servers = ["127.0.0.1:4647"]
}}

acl {{
  enabled = true
}}
"""
    log_info(f"Installing Nomad config: {NOMAD_CONFIG_FILE}")
    install_text(NOMAD_CONFIG_FILE, content, mode="0644")
    run_root(["chown", f"{NOMAD_USER}:{NOMAD_GROUP}", str(NOMAD_CONFIG_FILE)])


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


def stage_binary(tmpdir: Path, version: str) -> Path:
    """Put one release in place under its version and check it runs.

    The release is checked here, before anything points at it, so a bad archive
    fails while the running binary is still the one in use.
    """
    target = versioned_binary_path(BINARY_VERSION_DIR, "nomad", version)
    log_info(f"Installing binary: {target}")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BINARY_VERSION_DIR)])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(tmpdir / "extract" / "nomad"), str(target)])
    reported = parse_binary_version(run([str(target), "version"], capture=True, check=False).stdout or "")
    if reported != version:
        raise CLIError(f"Installed binary reports version {reported or 'unknown'}, expected {version}")
    return target


def install_binary(tmpdir: Path, version: str) -> None:
    target = stage_binary(tmpdir, version)
    atomic_symlink(target, BIN_PATH)
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_ENTRY.parent)])
    run_root(["ln", "-sfn", str(BIN_PATH), str(BIN_ENTRY)])
    log_success(f"Nomad binary entry installed: {BIN_ENTRY}")
    run([str(BIN_PATH), "version"])


def write_tool_manifest() -> None:
    lines: list[str] = []
    for name in ("nomad-manager", "nomad-job"):
        path = TOOL_DIR / name
        if path.is_file():
            lines.append(f"{sha256_file(path)}  {name}")
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


def write_install_metadata(version: str, revision: str = "unknown", dirty: bool = False) -> None:
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
        "host_volume_dir": str(HOST_VOLUME_DIR),
        "service": str(SYSTEMD_SERVICE),
        "nomad_version": version,
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
            "Managed by nomad-manager",
            f"Install metadata: {INSTALL_METADATA_FILE}",
            f"Tool dir: {TOOL_DIR}",
            f"Config dir: {CONFIG_DIR}",
            f"Host volume dir: {HOST_VOLUME_DIR}",
            f"Audit log: {AUDIT_LOG_FILE}",
            "",
        ]
    )
    install_text(DATA_POINTER_FILE, content, mode="0644")


def install_tool_snapshot(version: str, script_dir: Path) -> None:
    revision, dirty = source_tool_revision(script_dir)
    log_info(f"Installing Nomad init tools snapshot: {TOOL_DIR} (source revision {revision}{'-dirty' if dirty else ''})")
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_DIR)])
    for old_name in ("manager.sh", "job"):
        safe_remove_path(TOOL_DIR / old_name)
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(script_dir / "nomad-manager"), str(TOOL_DIR / "nomad-manager")])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(script_dir / "nomad-job"), str(TOOL_DIR / "nomad-job")])
    safe_remove_path(TOOL_DIR / "nomad_tools")
    run_root(["cp", "-R", str(script_dir / "nomad_tools"), str(TOOL_DIR / "nomad_tools")])
    run_root(["chown", "-R", "root:root", str(TOOL_DIR / "nomad_tools")])
    install_text(TOOL_VERSION_FILE, f"tool=nomad-manager\nnomad_version={version}\ntool_revision={revision}\n"
        f"tool_revision_dirty={str(dirty).lower()}\n"
        f"installed_at={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\nsource_dir={script_dir}\n", mode="0644")
    write_tool_manifest()
    write_install_metadata(version, revision, dirty)
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
    log_success(f"Nomad manager entry installed: {TOOL_ENTRY}")
    log_success(f"Nomad job entry installed: {JOB_ENTRY}")


def read_install_metadata() -> dict[str, Any]:
    try:
        data = json.loads(INSTALL_METADATA_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_installed_nomad_version() -> str:
    version = read_install_metadata().get("nomad_version")
    if isinstance(version, str) and version.strip():
        return version.strip()
    try:
        for line in TOOL_VERSION_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key == "nomad_version" and value.strip():
                return value.strip()
    except OSError:
        pass
    return "unknown"


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
    missing = [
        str(script_dir / name)
        for name in ("nomad-manager", "nomad-job")
        if not (script_dir / name).is_file()
    ]
    if not (script_dir / "nomad_tools").is_dir():
        missing.append(str(script_dir / "nomad_tools"))
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
    version = normalize_version(args.nomad_version) if args.nomad_version else read_installed_nomad_version()
    if version == "unknown":
        log_warn("Installed Nomad version metadata not found; recording unknown")
    log_info(f"Updating Nomad init tool files from: {script_dir}")
    install_tool_snapshot(version, script_dir)
    log_success("Nomad init tools updated")
    return 0


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
    log_success(f"ACL token saved to {token_file}")


def remove_acl_token_file() -> None:
    token_file = target_token_file()
    if not token_file.is_file():
        return
    with token_file.open("r", encoding="utf-8") as handle:
        first = handle.readline().rstrip("\n")
    if first != "# Generated by nomad-manager":
        log_warn(f"Skip removing ACL token file without generated marker: {token_file}")
        return
    token_file.unlink()
    log_success(f"Removed ACL token file: {token_file}")


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
        install_binary(tmpdir, version)
        ensure_nomad_user()
        install_directories()
        write_systemd_service()
        write_nomad_config(args.job_gc_threshold)
        write_default_managed_configs()
        script_dir = current_script_dir(__file__).parent
        if running_from_installed_copy(script_dir):
            log_warn(f"Running the copy installed at {TOOL_DIR}; the tool files will not change")
            log_warn("Run install from a source checkout to update nomad-manager and nomad-job as well")
        install_tool_snapshot(version, script_dir)
        log_info("Enabling Nomad service")
        run_root(["systemctl", "daemon-reload"])
        run_root(["systemctl", "enable", "nomad"])
        run_root(["systemctl", "restart", "nomad"])
        if not wait_for_nomad_api():
            raise CLIError("Timed out waiting for Nomad HTTP API")
        bootstrap_acl(not args.no_acl_bootstrap)
        if args.enable_cni:
            enable_cni(args.cni_version, restart=True)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    log_success("Nomad installation completed")
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
    key = "nomad_version="
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
    metadata["nomad_version"] = version
    metadata["previous_nomad_version"] = previous
    metadata["upgraded_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    run_root(["install", "-d", "-m", "0750", "-o", "root", "-g", "root", str(TOOL_STATE_DIR)])
    install_text(INSTALL_METADATA_FILE, json.dumps(metadata, indent=2, sort_keys=True) + "\n", mode="0644")
    record_tool_version_file(version)


def upgrade_plan_lines(current: str, target: str, keep: int) -> list[str]:
    lines = [
        "Nomad upgrade plan:",
        f"  Current version:  {current}",
        f"  Target version:   {target}",
        f"  Download:         https://releases.hashicorp.com/nomad/{target}/nomad_{target}_linux_{detect_arch()}.zip",
        f"  Install release:  {versioned_binary_path(BINARY_VERSION_DIR, 'nomad', target)}",
        f"  Switch symlink:   {BIN_PATH}",
        "  Restart service:  nomad.service",
        f"  Keep releases:    {keep} (older ones are removed once the new one is running)",
        "  Left untouched:   config, data directory, ACL state and the installed tool files",
        "",
        "  The HTTP API is unavailable while the agent restarts. Allocations already",
        "  running on a client stay up; a server rejoins the raft peers and an election",
        "  may follow. A restart that fails is rolled back to the current release.",
    ]
    if version_tuple(target) < version_tuple(current):
        lines.extend([
            "",
            f"  Downgrade: {current} may have written raft state that {target} cannot read,",
            "  so the older release can fail to start even though the binary is restored.",
        ])
    return lines


def warn_on_version_span(current: str, target: str) -> None:
    """Nomad supports one minor version at a time; larger jumps are the user's call."""
    cur = version_tuple(current)
    tgt = version_tuple(target)
    if tgt[0] != cur[0]:
        log_warn(f"Major version change {current} -> {target}; read the upgrade guide first")
    elif tgt[1] - cur[1] > 1:
        log_warn(f"{current} -> {target} skips {tgt[1] - cur[1] - 1} minor release(s); "
                 "Nomad expects one minor version at a time")


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
        raise CLIError(f"Nomad is not installed at {BIN_PATH}; run {NOMAD_MANAGER_CMD} install first")
    current = installed_binary_version() or read_installed_nomad_version()
    if not current or current == "unknown":
        raise CLIError(f"Cannot determine the installed Nomad version from {BIN_PATH}")
    target = resolve_upgrade_target(args.version)
    if target == current:
        log_success(f"Nomad {current} is already installed; nothing to upgrade")
        recorded = read_installed_nomad_version()
        if recorded != current:
            # doctor sends the operator here when the two disagree, so settle it instead of only reporting it
            log_info(f"Recording the installed version over {recorded}")
            record_upgrade_metadata(recorded, current)
        return 0
    if version_tuple(target) < version_tuple(current) and not args.allow_downgrade:
        raise CLIError(f"Refusing to downgrade Nomad {current} to {target}; re-run with --allow-downgrade")
    print("\n".join(upgrade_plan_lines(current, target, args.keep)))
    warn_on_version_span(current, target)
    if args.dry_run:
        return 0
    confirm_upgrade(args.yes)
    arch = detect_arch()
    previous = linked_binary_path(BIN_PATH)
    if previous is None:
        log_info(f"Moving the installed binary into {BINARY_VERSION_DIR}")
        previous = adopt_versioned_binary_layout(BIN_PATH, BINARY_VERSION_DIR, "nomad", current)
    tmpdir = create_install_tmpdir("nomad-upgrade")
    try:
        download_nomad(target, arch, tmpdir)
        staged = stage_binary(tmpdir, target)
        log_info(f"Switching {BIN_PATH} to {staged.name}")
        atomic_symlink(staged, BIN_PATH)
        try:
            log_info("Restarting Nomad on the new binary")
            restart_nomad_service()
        except (CLIError, subprocess.CalledProcessError) as exc:
            log_error(f"Nomad did not come back on {target}: {exc}")
            log_warn(f"Rolling back to {previous.name}")
            atomic_symlink(previous, BIN_PATH)
            try:
                restart_nomad_service()
            except (CLIError, subprocess.CalledProcessError) as rollback_error:
                raise CLIError(f"Upgrade to {target} failed and the rollback to {current} also failed: "
                               f"{rollback_error}") from exc
            raise CLIError(f"Upgrade to {target} failed and was rolled back to {current}") from exc
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    record_upgrade_metadata(current, target)
    for removed in prune_binary_versions(BINARY_VERSION_DIR, "nomad", keep=args.keep, current=staged):
        log_info(f"Removed old release: {removed}")
    log_success(f"Nomad upgraded: {current} -> {target}")
    print(f"\nVerify with: {NOMAD_MANAGER_CMD} doctor")
    return 0


def remove_tool_snapshot() -> None:
    log_info("Removing Nomad init tools")
    for path in uninstall_tool_paths():
        if Path(path).exists() or Path(path).is_symlink():
            safe_remove_path(path)


def purge_tool_state() -> None:
    log_warn("Purging Nomad init tool metadata and audit logs")
    safe_remove_path(TOOL_STATE_DIR)
    safe_remove_path(TOOL_LOG_DIR)


def uninstall_runtime_paths() -> list[Path]:
    return [SYSTEMD_SERVICE, BIN_ENTRY, BIN_PATH, BINARY_VERSION_DIR, CONFIG_DIR, DATA_DIR]


def uninstall_tool_paths() -> list[Path]:
    return [TOOL_ENTRY, JOB_ENTRY, LEGACY_TOOL_ENTRY, LEGACY_JOB_ENTRY, TOOL_PATH, JOB_PATH, TOOL_DIR]


def print_uninstall_plan(args: argparse.Namespace) -> None:
    print("Nomad uninstall plan:")
    print("  Stop and disable service:")
    print("    - nomad.service")
    print("  Remove runtime paths:")
    for path in uninstall_runtime_paths():
        print(f"    - {path}")
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
    log_info("Stopping Nomad service")
    run_root(["systemctl", "stop", "nomad"], check=False)
    run_root(["systemctl", "disable", "nomad"], check=False)
    log_info("Removing Nomad files")
    for path in uninstall_runtime_paths():
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
    log_success("Nomad uninstallation completed")
    return 0


def cmd_quickstart(_: argparse.Namespace) -> int:
    print(
        f"""Nomad manager quickstart, in the order the commands are meant to be used.

1. Set up the node
     {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}
     source {target_token_file()}
     {NOMAD_MANAGER_CMD} doctor

2. Enable the capabilities your jobs need
     {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes
     {NOMAD_MANAGER_CMD} cni enable
     {NOMAD_MANAGER_CMD} vault jwt apply --profile default --vault-addr ... --nomad-addr {NOMAD_ADDR}
     {NOMAD_MANAGER_CMD} consul setup-local

3. Provide the resources jobs reference
     {NOMAD_MANAGER_CMD} host-volume add data --create
     {NOMAD_MANAGER_CMD} meta set role web

4. Run a job with nomad-job
     nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl
     nomad-job validate jobs/web.nomad.hcl
     nomad-job plan jobs/web.nomad.hcl
     nomad-job apply jobs/web.nomad.hcl

5. Check everything at once
     {NOMAD_MANAGER_CMD} doctor --integrations

6. Review before removing anything
     {NOMAD_MANAGER_CMD} uninstall --dry-run

Run '{NOMAD_MANAGER_CMD} tutor <topic>' for the reasoning behind each step.
"""
    )
    return 0


def default_jwt_profile(vault_addr: str, nomad_addr: str) -> dict[str, Any]:
    """A profile made only of defaults, for rendering the diagram without one."""
    data = dict(PROFILE_DEFAULTS)
    data.update({"profile": "default", "vault_addr": vault_addr, "nomad_addr": nomad_addr,
                 "nomad_jwks_url": derived_jwks_url(nomad_addr)})
    return data


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    vault_addr = detected_vault_addr()
    vault_cacert = vault_ca_cert_file(vault_addr)
    vault_cacert_export = f"  {shell_export_line('VAULT_CACERT', vault_cacert)}\n" if vault_cacert else ""
    vault_secret_path = "kv/data/app/*"
    vault_enable_args = [NOMAD_MANAGER_CMD, "vault", "enable", "--address", vault_addr]
    if vault_cacert:
        vault_enable_args.extend(["--ca-file", vault_cacert])
    vault_enable_command = shell_command(vault_enable_args)
    vault_jwt_apply_command_line = shell_command([NOMAD_MANAGER_CMD, "vault", "jwt", "apply", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR])
    vault_jwt_plan_command_line = shell_command([NOMAD_MANAGER_CMD, "vault", "jwt", "plan", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR])
    vault_secret_plan_command = shell_command([NOMAD_MANAGER_CMD, "vault", "jwt", "plan", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR, "--secret-path", vault_secret_path])
    vault_secret_apply_command = shell_command([NOMAD_MANAGER_CMD, "vault", "jwt", "apply", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR, "--secret-path", vault_secret_path])
    token_file = target_token_file()
    topics = {
        "overview": f"""Nomad manager tutor.

Manage a single-node Nomad install, its node config and its integrations.
Every enable/disable command validates the config and restarts nomad.service,
rolling back automatically when validation fails.

Start here:
  {NOMAD_MANAGER_CMD} quickstart
  {NOMAD_MANAGER_CMD} doctor

Topics, in the same order as the commands:
  1. Set up          install
  2. Enable          docker, cni, vault, vault-jwt, consul
  3. Provide         host-volume-job
  4. Tune            ui
  5. Run jobs        workflows, web-service-job, vault-secret-job, private-image-job
  6. Remove          uninstall
  7. When it breaks  troubleshoot
""",
        "install": f"""Install a single node.

Downloads the Nomad binary, writes the managed config with ACL enabled and
starts nomad.service. It then bootstraps ACL and saves the management token to
{token_file} (mode 0600).
Source that file before running any nomad command. Add --enable-cni to set up
bridge networking in the same run.

There is no separate installer for this tool: install copies nomad-manager and
nomad-job into {TOOL_DIR}
and links them onto PATH, so run it from a source checkout the first time.

  ./tools/nomad/nomad-manager install --version {DEFAULT_NOMAD_VERSION}
  source {token_file}
  {NOMAD_MANAGER_CMD} doctor

Later, to update the tool without touching Nomad itself, again from a checkout:

  ./tools/nomad/nomad-manager tools update
""",
        "docker": f"""Change the Docker driver settings.

install already writes a working Docker config, so run this only to change it.
It rewrites {DOCKER_CONFIG}
and restarts nomad.service. --allow-privileged and --volumes widen what tasks
may do on the host, so enable them deliberately.

  {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes
  {NOMAD_MANAGER_CMD} docker doctor
""",
        "cni": f"""Set up bridge networking for jobs.

Required before any job uses network mode "bridge". enable downloads the CNI
plugins to {CNI_BIN_DIR}, applies the bridge sysctls and writes the client CNI
config. plan shows the same steps without touching the node.

  {NOMAD_MANAGER_CMD} cni plan
  {NOMAD_MANAGER_CMD} cni enable
  {NOMAD_MANAGER_CMD} cni doctor
""",
        "vault": f"""Point Nomad at a Vault whose JWT auth mount already exists.

This writes the Nomad side only. Use it when someone else manages that Vault,
when your token cannot create auth mounts, or when you need mTLS client certs
or env-exposed tokens -- options vault jwt apply does not cover.

If you manage this Vault yourself, use 'tutor vault-jwt' instead: that command
configures both sides at once, and running vault enable afterwards can undo it.

  {vault_enable_command}
  {NOMAD_MANAGER_CMD} vault doctor
""",
        "vault-jwt": f"""Configure Vault workload identity, on both sides.

apply creates the Vault JWT auth mount, policy and role, and also writes the
Nomad side of the integration ({VAULT_CONFIG}).
There is no need to run 'vault enable' afterwards.

How the flags connect, with their default values:

{jwt_wiring_diagram(default_jwt_profile(vault_addr, NOMAD_ADDR))}

Only --vault-addr and --nomad-addr have no default, so the shortest form is:

  {vault_jwt_plan_command_line}
  {vault_jwt_apply_command_line}

Everything is stored in the profile, so from then on:

  {NOMAD_MANAGER_CMD} vault jwt doctor --profile default

Requires the vault CLI, an unsealed Vault, and a VAULT_TOKEN allowed to create
auth mounts, policies and roles. plan runs the same checks without changing
anything, so start there.
""",
        "consul": f"""Point Nomad at Consul.

For a Consul installed on this host by consul-manager, use setup-local: it reads
the Consul install metadata, loads the Nomad agent token when ACL is on, and
picks the matching workload identity mode.

  {NOMAD_MANAGER_CMD} consul setup-local

For a remote Consul, write the config directly. Workload identity is on by
default and needs a JWT auth method on the Consul side; pass
--no-workload-identity when that Consul runs with ACL disabled.

  {NOMAD_MANAGER_CMD} consul enable --address consul.example.com:8500
  {NOMAD_MANAGER_CMD} consul doctor
""",
        "ui": f"""Adjust the Nomad UI.

enable writes cross-links to the Consul and Vault UIs plus an environment label,
which helps when you have several nodes open at once. disable turns the UI off;
reset removes the managed file and returns to the built-in default.

  {NOMAD_MANAGER_CMD} ui enable --consul-url http://127.0.0.1:8500 --label prod
  {NOMAD_MANAGER_CMD} ui disable
""",
        "workflows": f"""End-to-end job recipes.

Each topic walks one job from scaffold to running, using nomad-job for the
generate/validate/plan/apply cycle.

  {NOMAD_MANAGER_CMD} tutor web-service-job      An HTTP service with a health check
  {NOMAD_MANAGER_CMD} tutor vault-secret-job     A job reading a secret from Vault
  {NOMAD_MANAGER_CMD} tutor host-volume-job      A job with persistent host storage
  {NOMAD_MANAGER_CMD} tutor private-image-job    A job from a private registry
""",
        "vault-secret-job": f"""Run a job that reads a secret from Vault.

Set up the KV store and the workload identity link first, then generate a job
whose template pulls the secret at runtime. The job never holds the secret
itself; Nomad hands each allocation its own short-lived Vault token.

  {shell_export_line('VAULT_ADDR', vault_addr)}
{vault_cacert_export}  export VAULT_TOKEN=<root-token-or-admin-token>
  vault secrets enable -path=kv kv-v2
  vault kv put kv/app/config value='my-secret-value' username='app-user' password='app-password' api_key='app-api-key'
  vault kv get kv/app/config
  {vault_secret_plan_command}
  {vault_secret_apply_command}
  {NOMAD_MANAGER_CMD} vault jwt job-example --profile default --job web --secret kv/data/app/config --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl

Notes:
  vault kv put uses the KV CLI path kv/app/config.
  Nomad templates and Vault policies use the KV v2 API path kv/data/app/config.
  The apply command above is the simplified default form.
  For exact options, run plan first and use the full Next command it prints.
  If kv/ is already enabled, skip the vault secrets enable command.
  Avoid putting real secret values directly in shared shell history.
""",
        "host-volume-job": f"""Run a job with persistent host storage.

host-volume add writes a client host_volume block and restarts nomad.service.
--create makes the directory; a relative --path resolves under
{HOST_VOLUME_DIR}. The scaffold flag takes name:container-path:mode.

  {NOMAD_MANAGER_CMD} host-volume add data --create
  nomad-job scaffold docker --job web --image nginx:1.27 --host-volume data:/opt/data:rw --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl

Removing a volume keeps its data directory unless you pass --purge.
""",
        "private-image-job": f"""Run a job from a private registry.

--auth-config points the Docker driver at an existing credentials file rather
than storing credentials in the job. Create that file first with 'docker login'
as the user that runs nomad.service, then reference it here.

  {NOMAD_MANAGER_CMD} docker enable --auth-config /root/.docker/config.json
  nomad-job scaffold docker --job private-web --image registry.example.com/app:1.0 --out jobs/private-web.nomad.hcl
  nomad-job validate jobs/private-web.nomad.hcl
  nomad-job plan jobs/private-web.nomad.hcl
  nomad-job apply jobs/private-web.nomad.hcl
""",
        "web-service-job": f"""Run an HTTP service job.

scaffold generates the HCL, validate checks it parses, plan shows the scheduling
diff against what is running, and apply submits it. --port is host:container and
--check-http adds a health check on the mapped port.

  {NOMAD_MANAGER_CMD} docker enable --volumes
  nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --check-http / --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl
""",
        "uninstall": f"""Remove Nomad from this node.

--dry-run prints the removal plan and changes nothing; always run it first.
The real uninstall stops nomad.service and deletes
{CONFIG_DIR} and {DATA_DIR}, which destroys job state.
Installed tools, metadata and audit logs are kept unless you pass
--remove-tools or --purge.

  {NOMAD_MANAGER_CMD} uninstall --dry-run
  {NOMAD_MANAGER_CMD} uninstall --yes
""",
        "troubleshoot": f"""Start with the aggregate check, then narrow down.

doctor covers platform, service, binary, config and API, then runs checks for
whichever integrations are configured. --integrations forces all of them even
when their managed configs are absent, which is how you tell "not configured"
apart from "configured and broken".

  {NOMAD_MANAGER_CMD} doctor
  {NOMAD_MANAGER_CMD} doctor --integrations
  {NOMAD_MANAGER_CMD} docker doctor
  {NOMAD_MANAGER_CMD} vault doctor
  {NOMAD_MANAGER_CMD} consul doctor

Read the service log directly when a restart failed:
  journalctl -u nomad -n 100 --no-pager
""",
    }
    if topic not in topics:
        raise CLIError(f"Unknown tutor topic: {topic}. Available: {', '.join(topics)}")
    print(topics[topic])
    return 0


def add_common_vault_jwt_args(parser: argparse.ArgumentParser) -> None:
    """Group the flags by what they control, and state the defaults.

    argparse itself keeps default=None on purpose: prepare_profile uses "not
    given" to fall back to the stored profile, so a real argparse default would
    silently overwrite a customised profile on the next run.
    """
    # Every flag states its own status, because argparse brackets required and
    # optional options identically in the usage line.
    parser.add_argument("--profile", required=True, help="(required) Local profile name; stores everything below")

    connection = parser.add_argument_group(
        "connection", "Set these the first time. Later runs read them back from the profile."
    )
    connection.add_argument("--vault-addr", help="(required on first run) Vault address, for example http://127.0.0.1:8200")
    connection.add_argument("--nomad-addr", help="(required on first run) Nomad address; the JWKS URL is derived from it")
    connection.add_argument("--vault-namespace", help="(optional) Vault Enterprise namespace; none by default")

    created = parser.add_argument_group(
        "what gets created in Vault", "The defaults are fine unless they clash with something you already have."
    )
    created.add_argument("--auth-path", help=f"(default: {PROFILE_DEFAULTS['auth_path']}) JWT auth mount path")
    created.add_argument("--role", help=f"(default: {PROFILE_DEFAULTS['role']}) Vault role name")
    created.add_argument("--policy", help=f"(default: {PROFILE_DEFAULTS['policy']}) Vault policy name")

    granted = parser.add_argument_group(
        "what the workloads may do", "This is the part worth reviewing: it decides which secrets tasks can read."
    )
    granted.add_argument("--secret-path", action="append",
                         help=f"(default: {PROFILE_DEFAULTS['secret_paths'][0]}) Secret path the generated policy grants; repeatable")
    granted.add_argument("--aud", help=f"(default: {PROFILE_DEFAULTS['aud']}) Comma-separated JWT audiences; must match on both sides")
    granted.add_argument("--ttl", help=f"(default: {PROFILE_DEFAULTS['ttl']}) TTL of the tokens Vault issues")
    granted.add_argument("--policy-file", help="(optional) Use an existing policy HCL file; one is generated when omitted")

    advanced = parser.add_argument_group("advanced")
    advanced.add_argument("--nomad-jwks-url",
                          help="(optional) Override the JWKS URL; defaults to <nomad-addr>/.well-known/jwks.json")
    advanced.add_argument("--force", action="store_true", help="(optional) Replace an existing profile with different values")


COMMAND_GROUPS: list[tuple[str, str, list[tuple[str, str]]]] = [
    (
        "Set up the node",
        "",
        [
            ("install", "Install Nomad and this tool, write config, bootstrap ACL"),
            ("doctor", "Check the node and whatever integrations are configured"),
            ("status", "Show the effective configuration of this node"),
        ],
    ),
    (
        "Enable capabilities",
        "",
        [
            ("docker", "Docker driver settings"),
            ("cni", 'Bridge networking, required for network mode "bridge"'),
            ("raw-exec", "raw_exec driver, runs tasks on the host with no isolation"),
            ("driver", "Driver denylist"),
            ("vault", "Secrets: point Nomad at Vault"),
            ("consul", "Service discovery: point Nomad at Consul"),
        ],
    ),
    (
        "Provide resources to jobs",
        "",
        [
            ("host-volume", "Persistent host storage that jobs mount"),
            ("meta", "Client meta pairs that jobs constrain on"),
        ],
    ),
    (
        "Tune the node",
        "",
        [
            ("ui", "Nomad UI links, labels and on/off"),
            ("tls", "TLS for the HTTP and RPC listeners"),
            ("telemetry", "Prometheus metrics"),
        ],
    ),
    (
        "Run jobs",
        "Use nomad-job for the job lifecycle: scaffold, validate, plan, apply.",
        [
            ("export", "Export submitted jobs back to HCL"),
        ],
    ),
    (
        "Maintain and remove",
        "",
        [
            ("upgrade", "Install another Nomad release and restart the agent"),
            ("tools", "Update the installed nomad-manager and nomad-job files"),
            ("uninstall", "Remove Nomad, after showing a removal plan"),
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
        prog=NOMAD_MANAGER_CMD,
        description="Manage a single-node Nomad install, in the order you actually use it.\n"
        "\n"
        f"{command_group_help()}\n"
        "\n"
        f"Run '{NOMAD_MANAGER_CMD} <command> --help' for what a command does and when to use it,\n"
        f"or '{NOMAD_MANAGER_CMD} quickstart' for the whole path end to end.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}
  {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes
  {NOMAD_MANAGER_CMD} cni enable
  {NOMAD_MANAGER_CMD} vault jwt apply --profile default --vault-addr ... --nomad-addr ...
  {NOMAD_MANAGER_CMD} consul setup-local
  {NOMAD_MANAGER_CMD} host-volume add data --create
  {NOMAD_MANAGER_CMD} doctor --integrations
  {NOMAD_MANAGER_CMD} uninstall --dry-run
""",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    parser.set_defaults(func=lambda _: missing_subcommand(parser, NOMAD_MANAGER_CMD))

    install = sub.add_parser("install", description="Install Nomad, write managed config and start nomad.service.\n"
        "\n"
        "ACL is enabled in the generated config, and install bootstraps it and saves the\n"
        "management token to ~/nomad.acl (mode 0600). Source that file before running any\n"
        "nomad command. Pass --no-acl-bootstrap to skip the bootstrap step.\n"
        "\n"
        "install also copies this tool itself into the node: nomad-manager, nomad-job and\n"
        f"the nomad_tools package go to {TOOL_DIR},\n"
        f"linked onto PATH as {TOOL_ENTRY} and {JOB_ENTRY}.\n"
        "The node then runs its own copy, unaffected by the source tree moving or changing.\n"
        "Refresh that copy later with 'tools update'.")
    install.add_argument("version_pos", nargs="?", help="Nomad version, for example 2.0.0 or latest")
    install.add_argument("--version", dest="version_opt", help="Nomad version; overrides the positional version")
    install.add_argument("--no-acl-bootstrap", action="store_true", help="Skip automatic ACL bootstrap after install")
    install.add_argument("--enable-cni", action="store_true", help="Install and configure CNI plugins after Nomad install")
    install.add_argument("--cni-version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    install.add_argument("--job-gc-threshold", default=DEFAULT_JOB_GC_THRESHOLD,
                         help=f"How long dead jobs are kept before the server garbage-collects them "
                              f"(default: {DEFAULT_JOB_GC_THRESHOLD}; Nomad's own default is 4h)")
    install.set_defaults(func=lambda args: cmd_install(argparse.Namespace(version=args.version_opt or args.version_pos, no_acl_bootstrap=args.no_acl_bootstrap, enable_cni=args.enable_cni, cni_version=args.cni_version, job_gc_threshold=args.job_gc_threshold)))

    doctor = sub.add_parser("doctor", description="Check the managed Nomad install, service status and detected integrations.\n"
        "\n"
        "Read-only. Integration checks run for whichever managed configs exist; pass\n"
        "--integrations to run them all regardless.")
    doctor.add_argument("--integrations", action="store_true", help="Run Docker, CNI, Vault and Consul checks even if their managed configs are absent")
    doctor.set_defaults(func=cmd_doctor)

    status = sub.add_parser(
        "status",
        description="Show what is configured on this node: versions, service state, every managed\n"
        "config value, host volumes and client meta.\n"
        "\n"
        "status answers \"what is it\"; doctor answers \"is it broken\". Neither changes anything.",
    )
    status.set_defaults(func=cmd_status)

    docker = sub.add_parser("docker", description="Manage the Docker driver config. install already writes a working default, so use enable\nonly to change it; it rewrites 80-docker.hcl and restarts nomad.service.\n\nTo stop Nomad from using the Docker driver at all, deny it instead: driver deny docker.")
    docker_sub = docker.add_subparsers(dest="docker_command")
    docker.set_defaults(func=lambda _: missing_subcommand(docker, f"{NOMAD_MANAGER_CMD} docker"))
    docker_enable = docker_sub.add_parser("enable", help="Write managed Docker driver config")
    add_bool_argument(docker_enable, "--allow-privileged", default=True, help_text="Allow privileged Docker tasks", no_help="Disallow privileged Docker tasks")
    add_bool_argument(docker_enable, "--volumes", default=True, help_text="Allow Docker volume mounts", no_help="Disallow Docker volume mounts")
    add_bool_argument(docker_enable, "--image-gc", default=True, help_text="Enable Docker image garbage collection", no_help="Disable Docker image garbage collection")
    docker_enable.add_argument("--image-delay", default="100h", help="Nomad Docker image GC delay")
    docker_enable.add_argument("--auth-config", help="Docker auth config path for private registries")
    docker_enable.set_defaults(func=cmd_docker_enable)
    docker_doctor = docker_sub.add_parser("doctor", help="Check Docker integration")
    docker_doctor.set_defaults(func=cmd_docker_doctor)

    docker_disable = docker_sub.add_parser("disable", help="Remove managed Docker config")
    docker_disable.set_defaults(func=lambda _: remove_managed_file(DOCKER_CONFIG) or 0)

    cni = sub.add_parser(
        "cni",
        description="Set up the CNI plugins that Nomad needs before any job can use network mode\n"
        "\"bridge\".\n"
        "\n"
        "enable downloads the plugins to /opt/cni/bin, applies the bridge sysctls and writes\n"
        "83-cni.hcl, then restarts nomad.service. plan shows the same steps without touching\n"
        "the node.",
    )
    cni_sub = cni.add_subparsers(dest="cni_command")
    cni.set_defaults(func=lambda _: missing_subcommand(cni, f"{NOMAD_MANAGER_CMD} cni"))
    cni_plan = cni_sub.add_parser("plan", help="Preview CNI plugin installation and Nomad config changes")
    cni_plan.add_argument("--version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    cni_plan.set_defaults(func=cmd_cni_plan)
    cni_enable = cni_sub.add_parser("enable", help="Install CNI plugins and write Nomad client CNI config")
    cni_enable.add_argument("--version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    cni_enable.set_defaults(func=cmd_cni_enable)
    cni_doctor = cni_sub.add_parser("doctor", help="Check plugins and bridge sysctls")
    cni_doctor.set_defaults(func=cmd_cni_status)

    cni_disable = cni_sub.add_parser("disable", help="Remove managed Nomad CNI config")
    cni_disable.add_argument("--remove-plugins", action="store_true", help=f"Also remove {CNI_BIN_DIR}")
    cni_disable.set_defaults(func=cmd_cni_disable)

    raw_exec = sub.add_parser("raw-exec", description="Manage the raw_exec driver, which runs tasks directly on the host with no isolation.\nenable and disable rewrite 81-raw-exec.hcl and restart nomad.service.")
    raw_sub = raw_exec.add_subparsers(dest="raw_exec_command")
    raw_exec.set_defaults(func=lambda _: missing_subcommand(raw_exec, f"{NOMAD_MANAGER_CMD} raw-exec"))
    raw_enable = raw_sub.add_parser("enable", help="Enable raw_exec")
    raw_enable.set_defaults(func=cmd_raw_exec_enable)
    raw_disable = raw_sub.add_parser("disable", help="Remove managed raw_exec config")
    raw_disable.set_defaults(func=lambda _: remove_managed_file(RAW_EXEC_CONFIG) or 0)

    driver = sub.add_parser("driver", description="Manage the Nomad driver denylist in 82-driver-denylist.hcl. Both commands restart\nnomad.service.")
    driver_sub = driver.add_subparsers(dest="driver_command")
    driver.set_defaults(func=lambda _: missing_subcommand(driver, f"{NOMAD_MANAGER_CMD} driver"))
    driver_deny = driver_sub.add_parser("deny", help="Add a driver to the denylist")
    driver_deny.add_argument("driver", help="Driver name")
    driver_deny.set_defaults(func=cmd_driver_deny)
    driver_allow = driver_sub.add_parser("allow", help="Remove a driver from the denylist")
    driver_allow.add_argument("driver", help="Driver name")
    driver_allow.set_defaults(func=cmd_driver_allow)

    vault = sub.add_parser(
        "vault",
        description="Write the Nomad side of the Vault integration.\n"
        "\n"
        "Use 'vault enable' when the Vault JWT auth mount already exists: someone else manages\n"
        "that Vault, you have no token to create auth mounts, or you need mTLS client certs or\n"
        "env-exposed tokens. If you manage the Vault yourself, use 'vault jwt apply' instead --\n"
        "it configures both sides in one step.",
    )
    vault_sub = vault.add_subparsers(dest="vault_command")
    vault.set_defaults(func=lambda _: missing_subcommand(vault, f"{NOMAD_MANAGER_CMD} vault"))
    vault_jwt = vault_sub.add_parser(
        "jwt",
        help="Configure Vault and Nomad together (recommended)",
        description="Configure Vault workload identity for Nomad tasks, on both sides.\n"
        "\n"
        "Requires the vault CLI, an unsealed Vault, and a VAULT_TOKEN allowed to create auth\n"
        "mounts, policies and roles. Settings are kept in a local profile under\n"
        f"{VAULT_JWT_PROFILE_DIR}, so later commands only need --profile.\n"
        "\n"
        f"Run '{NOMAD_MANAGER_CMD} tutor vault-jwt' for how these flags connect.",
    )
    jwt_sub = vault_jwt.add_subparsers(dest="vault_jwt_command")
    vault_jwt.set_defaults(func=lambda _: missing_subcommand(vault_jwt, f"{NOMAD_MANAGER_CMD} vault jwt"))
    jwt_plan = jwt_sub.add_parser(
        "plan",
        help="Preview Vault JWT workload identity changes",
        description="Run the same preflight checks as apply and print the resulting policy, role and\n"
        "config without changing Vault or Nomad.",
    )
    add_common_vault_jwt_args(jwt_plan)
    jwt_plan.set_defaults(func=cmd_vault_jwt_plan)
    jwt_apply = jwt_sub.add_parser(
        "apply",
        help="Configure both the Vault side and the Nomad side",
        description="Create the Vault JWT auth mount, policy and role, then write the Nomad side\n"
        "(60-vault.hcl) and restart nomad.service.\n"
        "\n"
        "This includes everything 'vault enable' does, so there is no need to run that\n"
        "afterwards -- doing so can overwrite the auth path and CA written here.",
    )
    add_common_vault_jwt_args(jwt_apply)
    jwt_apply.set_defaults(func=cmd_vault_jwt_apply)
    jwt_doctor = jwt_sub.add_parser("doctor", help="Check and suggest fixes for a Vault JWT profile")
    jwt_doctor.add_argument("--profile", required=True, help="Local profile name")
    jwt_doctor.set_defaults(func=cmd_vault_jwt_doctor)
    jwt_job = jwt_sub.add_parser("job-example", help="Generate an example job using Vault JWT")
    jwt_job.add_argument("--profile", required=True, help="Local profile name")
    jwt_job.add_argument("--job", required=True, help="Example Nomad job name")
    jwt_job.add_argument("--secret", required=True,
                         help="(required) Vault secret path the job reads; must be granted by the profile policy")
    jwt_job.add_argument("--out", default="-", help="Output HCL path, or '-' for stdout")
    jwt_job.add_argument("--image", default="alpine:3.20", help="Example Docker image")
    jwt_job.add_argument("--force", action="store_true", help="Overwrite an existing output file")
    jwt_job.set_defaults(func=cmd_vault_jwt_job_example)

    vault_enable = vault_sub.add_parser(
        "enable",
        help="Write the Nomad side of the Vault config only",
        description="Write 60-vault.hcl and restart nomad.service, rolling back if validation fails.\n"
        "\n"
        "This touches Nomad only; it does not create the Vault auth mount, policy or role.\n"
        "It is the only way to set --cert-file, --key-file, --ca-path or --env, which\n"
        "'vault jwt apply' does not cover.\n"
        "\n"
        "Running this after 'vault jwt apply' can overwrite the auth path and CA that apply\n"
        "wrote; the command warns when it detects that case.",
    )
    vault_enable.add_argument("--address", required=True, help="Vault address, for example http://127.0.0.1:8200")
    vault_enable.add_argument("--ca-file", default="", help="Vault CA certificate file")
    vault_enable.add_argument("--ca-path", default="", help="Vault CA certificate directory")
    vault_enable.add_argument("--cert-file", default="", help="Vault client certificate file")
    vault_enable.add_argument("--key-file", default="", help="Vault client key file")
    vault_enable.add_argument("--namespace", default="", help="Vault Enterprise namespace")
    vault_enable.add_argument("--jwt-auth-backend-path", default="jwt-nomad", help="Vault JWT auth mount path")
    vault_enable.add_argument("--aud", default="vault.io", help="Comma-separated workload identity audiences")
    vault_enable.add_argument("--ttl", default="1h", help="Default workload identity token TTL")
    add_bool_argument(vault_enable, "--env", default=False, help_text="Expose workload identity token through environment variables", no_help="Do not expose workload identity token through environment variables")
    add_bool_argument(vault_enable, "--file", default=True, help_text="Write workload identity token to a file", no_help="Do not write workload identity token to a file")
    vault_enable.set_defaults(func=cmd_vault_enable)
    vault_doctor = vault_sub.add_parser("doctor", help="Check Vault integration")
    vault_doctor.add_argument("--address", help="Override Vault address for the check")
    vault_doctor.add_argument("--namespace", help="Override Vault namespace for the check")
    vault_doctor.set_defaults(func=cmd_vault_doctor)

    vault_disable = vault_sub.add_parser(
        "disable",
        help="Remove managed Vault config",
        description="Remove 60-vault.hcl and restart nomad.service. The Vault side is left untouched.",
    )
    vault_disable.set_defaults(func=lambda _: remove_managed_file(VAULT_CONFIG) or 0)

    consul = sub.add_parser(
        "consul",
        description="Write the Nomad side of the Consul integration.\n"
        "\n"
        "For a Consul installed on this host by consul-manager, prefer 'consul setup-local':\n"
        "it reads the Consul install metadata and picks the matching token and workload\n"
        "identity mode. Use 'consul enable' for a remote Consul.",
    )
    consul_sub = consul.add_subparsers(dest="consul_command")
    consul.set_defaults(func=lambda _: missing_subcommand(consul, f"{NOMAD_MANAGER_CMD} consul"))
    consul_setup_local = consul_sub.add_parser(
        "setup-local",
        help="Wire Nomad to a locally installed Consul",
        description="Detect a consul-manager install on this host, load the Nomad agent token when ACL\n"
        "is on, and write the Nomad Consul config.",
    )
    consul_setup_local.add_argument("--address", help="Override the detected Consul address")
    consul_setup_local.add_argument("--token-file", default="", help=f"Nomad agent token file (default: {CONSUL_NOMAD_AGENT_TOKEN_FILE})")
    consul_setup_local.set_defaults(func=cmd_consul_setup_local)
    consul_enable = consul_sub.add_parser(
        "enable",
        help="Write the Nomad side of the Consul config",
        description="Write 60-consul.hcl and restart nomad.service, rolling back if validation fails.\n"
        "\n"
        "Workload identity is on by default, which requires a JWT auth method on the Consul\n"
        "side. Pass --no-workload-identity when that Consul runs with ACL disabled.",
    )
    consul_enable.add_argument("--address", default=DEFAULT_CONSUL_ADDR, help=f"Consul HTTP address (default: {DEFAULT_CONSUL_ADDR})")
    consul_enable.add_argument("--grpc-address", default="", help="Consul gRPC address")
    consul_enable.add_argument("--ca-file", default="", help="Consul CA certificate file")
    consul_enable.add_argument("--cert-file", default="", help="Consul client certificate file")
    consul_enable.add_argument("--key-file", default="", help="Consul client key file")
    add_bool_argument(consul_enable, "--ssl", default=False, help_text="Use HTTPS for Consul", no_help="Use HTTP for Consul")
    add_bool_argument(consul_enable, "--verify", default=True, help_text="Verify Consul TLS certificates", no_help="Skip Consul TLS certificate verification")
    consul_enable.add_argument("--aud", default="consul.io", help="Comma-separated service identity audiences")
    consul_enable.add_argument("--ttl", default="1h", help="Service identity token TTL")
    add_bool_argument(
        consul_enable,
        "--workload-identity",
        default=True,
        help_text="Write service_identity and task_identity blocks; requires a Consul JWT auth method",
        no_help="Omit workload identity blocks; use this when Consul ACL is disabled",
    )
    consul_enable.set_defaults(func=cmd_consul_enable)
    consul_token = consul_sub.add_parser("token", help="Manage the Consul token used by the Nomad agent")
    consul_token_sub = consul_token.add_subparsers(dest="consul_token_command")
    consul_token.set_defaults(func=lambda _: missing_subcommand(consul_token, f"{NOMAD_MANAGER_CMD} consul token"))
    consul_token_set = consul_token_sub.add_parser(
        "set",
        help="Store the Consul token for nomad.service",
        description=f"Write the token to {CONSUL_TOKEN_ENV_FILE} (0600) and reference it from a\n"
        f"systemd drop-in at {CONSUL_TOKEN_DROPIN}.",
    )
    consul_token_set.add_argument("--token", default="", help="Consul ACL token")
    consul_token_set.add_argument("--token-file", default="", help="File holding a Consul ACL token")
    consul_token_set.set_defaults(func=cmd_consul_token_set)
    consul_token_unset = consul_token_sub.add_parser("unset", help="Remove the managed Consul token")
    consul_token_unset.set_defaults(func=cmd_consul_token_unset)
    consul_doctor = consul_sub.add_parser("doctor", help="Check Consul integration")
    consul_doctor.add_argument("--address", help="Override Consul address for the check")
    consul_doctor.add_argument("--ssl", type=bool_arg, help="Override detected Consul TLS mode with true or false")
    consul_doctor.set_defaults(func=cmd_consul_doctor)

    consul_disable = consul_sub.add_parser("disable", help="Remove managed Consul config")
    consul_disable.set_defaults(func=lambda _: remove_managed_file(CONSUL_CONFIG) or 0)

    host_volume = sub.add_parser(
        "host-volume",
        description="Manage Nomad client host volume configs.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} host-volume add data --create
  nomad-job scaffold docker --job web --image nginx:1.27 --host-volume data:/opt/data:rw --out jobs/web.nomad.hcl
  {NOMAD_MANAGER_CMD} host-volume remove data --purge
""",
    )
    hv_sub = host_volume.add_subparsers(dest="host_volume_command")
    host_volume.set_defaults(func=lambda _: missing_subcommand(host_volume, f"{NOMAD_MANAGER_CMD} host-volume"))
    hv_add = hv_sub.add_parser(
        "add",
        help="Add a managed host volume config",
        description="Add a managed Nomad client host volume config.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} host-volume add data --create
  {NOMAD_MANAGER_CMD} host-volume add logs --path /srv/logs --create --read-only

Job HCL reference:
{host_volume_job_hcl_example("data", False)}

Scaffold a job:
  nomad-job scaffold docker --job web --image nginx:1.27 --host-volume data:/opt/data:rw --out jobs/web.nomad.hcl
""",
    )
    hv_add.add_argument("name", help="Host volume name")
    hv_add.add_argument(
        "--path",
        help=f"Host path; relative paths are resolved under {HOST_VOLUME_DIR}, defaults to the volume name",
    )
    hv_add.add_argument("--read-only", action="store_true", dest="read_only", help="Mount the host volume read-only")
    hv_add.add_argument("--read-write", action="store_false", dest="read_only", help="Mount the host volume read-write")
    hv_add.set_defaults(read_only=False)
    hv_add.add_argument("--create", action="store_true", help="Create the host path if it does not exist")
    hv_add.set_defaults(func=cmd_host_volume_add)
    hv_remove = hv_sub.add_parser(
        "remove",
        help="Remove a managed host volume config",
        description="Remove a managed Nomad client host volume config.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} host-volume remove data
  {NOMAD_MANAGER_CMD} host-volume remove data --purge
  {NOMAD_MANAGER_CMD} host-volume remove data --purge --yes

The host volume data directory is preserved unless --purge is given.
""",
    )
    hv_remove.add_argument("name", help="Host volume name")
    hv_remove.add_argument("--purge", action="store_true", help="Also delete the host volume data directory")
    hv_remove.add_argument("--yes", action="store_true", help="Skip the interactive confirmation for --purge")
    hv_remove.set_defaults(func=cmd_host_volume_remove)

    meta = sub.add_parser("meta", description="Manage Nomad client meta key/value pairs in 72-client-meta.hcl, usable as job constraints.\nBoth commands restart nomad.service.")
    meta_sub = meta.add_subparsers(dest="meta_command")
    meta.set_defaults(func=lambda _: missing_subcommand(meta, f"{NOMAD_MANAGER_CMD} meta"))
    meta_set = meta_sub.add_parser("set", help="Set a client meta key")
    meta_set.add_argument("key", help="Meta key")
    meta_set.add_argument("value", help="Meta value")
    meta_set.set_defaults(func=cmd_meta_set)
    meta_unset = meta_sub.add_parser("unset", help="Remove a client meta key")
    meta_unset.add_argument("key", help="Meta key")
    meta_unset.set_defaults(func=cmd_meta_unset)

    ui = sub.add_parser("ui", description="Manage the Nomad UI. enable writes 35-ui.hcl, disable turns the UI off, reset removes the\nmanaged file and returns to the built-in default. Each one restarts nomad.service.")
    ui_sub = ui.add_subparsers(dest="ui_command")
    ui.set_defaults(func=lambda _: missing_subcommand(ui, f"{NOMAD_MANAGER_CMD} ui"))
    ui_enable = ui_sub.add_parser("enable", help="Write managed UI config")
    ui_enable.add_argument("--consul-url", help="Consul UI URL shown from the Nomad UI")
    ui_enable.add_argument("--vault-url", help="Vault UI URL shown from the Nomad UI")
    ui_enable.add_argument("--label", help="Nomad UI label text")
    ui_enable.add_argument("--label-background", help="Nomad UI label background color")
    ui_enable.add_argument("--label-color", help="Nomad UI label text color")
    add_bool_argument(ui_enable, "--show-cli-hints", default=True, help_text="Show CLI hints in the Nomad UI", no_help="Hide CLI hints in the Nomad UI")
    ui_enable.set_defaults(func=cmd_ui_enable)
    ui_disable = ui_sub.add_parser("disable", help="Disable the Nomad UI")
    ui_disable.set_defaults(func=cmd_ui_disable)
    ui_reset = ui_sub.add_parser("reset", help="Remove managed UI config")
    ui_reset.set_defaults(func=lambda _: remove_managed_file(UI_CONFIG) or 0)

    tls = sub.add_parser("tls", description="Manage the managed TLS config. enable and disable rewrite 30-tls.hcl and\n"
        "restart nomad.service.\n"
        "\n"
        "Certificates are not generated here; point the options at files that already exist.")
    tls_sub = tls.add_subparsers(dest="tls_command")
    tls.set_defaults(func=lambda _: missing_subcommand(tls, f"{NOMAD_MANAGER_CMD} tls"))
    tls_enable = tls_sub.add_parser("enable", help="Write managed TLS config")
    tls_enable.add_argument("--ca-file", required=True, help="Nomad CA certificate file")
    tls_enable.add_argument("--cert-file", required=True, help="Nomad certificate file")
    tls_enable.add_argument("--key-file", required=True, help="Nomad private key file")
    add_bool_argument(tls_enable, "--http", default=True, help_text="Enable TLS for the HTTP listener", no_help="Disable TLS for the HTTP listener")
    add_bool_argument(tls_enable, "--rpc", default=True, help_text="Enable TLS for RPC", no_help="Disable TLS for RPC")
    add_bool_argument(tls_enable, "--verify-server-hostname", default=False, help_text="Verify server hostnames", no_help="Do not verify server hostnames")
    add_bool_argument(tls_enable, "--verify-https-client", default=False, help_text="Require and verify HTTPS client certificates", no_help="Do not require HTTPS client certificates")
    tls_enable.set_defaults(func=cmd_tls_enable)
    tls_disable = tls_sub.add_parser("disable", help="Remove managed TLS config")
    tls_disable.set_defaults(func=lambda _: remove_managed_file(TLS_CONFIG) or 0)

    telemetry = sub.add_parser("telemetry", description="Manage the managed telemetry config. enable and disable rewrite\n"
        "40-telemetry.hcl and restart nomad.service.")
    telemetry_sub = telemetry.add_subparsers(dest="telemetry_command")
    telemetry.set_defaults(func=lambda _: missing_subcommand(telemetry, f"{NOMAD_MANAGER_CMD} telemetry"))
    telemetry_enable = telemetry_sub.add_parser("enable", help="Write managed telemetry config")
    add_bool_argument(telemetry_enable, "--prometheus", default=True, help_text="Enable Prometheus metrics", no_help="Disable Prometheus metrics")
    add_bool_argument(telemetry_enable, "--alloc", default=True, help_text="Publish allocation metrics", no_help="Do not publish allocation metrics")
    add_bool_argument(telemetry_enable, "--node", default=True, help_text="Publish node metrics", no_help="Do not publish node metrics")
    telemetry_enable.add_argument("--interval", default="1s", help="Telemetry collection interval")
    add_bool_argument(telemetry_enable, "--disable-hostname", default=False, help_text="Disable hostname labels in telemetry", no_help="Keep hostname labels in telemetry", no_option="--keep-hostname")
    telemetry_enable.set_defaults(func=cmd_telemetry_enable)
    telemetry_disable = telemetry_sub.add_parser("disable", help="Remove managed telemetry config")
    telemetry_disable.set_defaults(func=lambda _: remove_managed_file(TELEMETRY_CONFIG) or 0)

    export = sub.add_parser("export")
    export.add_argument("jobs", nargs="*", help="Job IDs to export; exports all jobs when omitted")
    export.add_argument("--out-dir", default="jobs/exported", help="Output directory for exported HCL files")
    export.add_argument("--force", action="store_true", help="Overwrite existing exported files")
    export.set_defaults(func=cmd_export)

    upgrade = sub.add_parser(
        "upgrade",
        help="Install another Nomad release and restart the agent",
        description="Replace the Nomad binary with another release and restart nomad.service.\n"
        "\n"
        "Only the binary changes: config, the data directory, ACL state and the installed\n"
        "tool files are left alone. The replaced release stays on disk, so an agent that\n"
        "fails to come back is switched to it again automatically.\n"
        "\n"
        "Run --dry-run first to see the plan.",
    )
    upgrade.add_argument("--version", default="latest", help="Target Nomad version, or latest (default: latest)")
    upgrade.add_argument("--keep", type=int, default=2, metavar="N",
                         help="Releases to keep on disk, including the running one (default: 2)")
    upgrade.add_argument("--allow-downgrade", action="store_true", help="Allow installing an older release than the running one")
    upgrade.add_argument("--dry-run", action="store_true", help="Print the upgrade plan without changing anything")
    upgrade.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    upgrade.set_defaults(func=cmd_upgrade)

    tools = sub.add_parser("tools")
    tools_sub = tools.add_subparsers(dest="tools_command")
    tools.set_defaults(func=lambda _: missing_subcommand(tools, f"{NOMAD_MANAGER_CMD} tools"))
    tools_update = tools_sub.add_parser(
        "update",
        help="Update nomad-manager and nomad-job files only",
        description="Refresh the tool copy that install placed on this node, without touching the Nomad\n"
        "binary, config or service state.\n"
        "\n"
        "The new files are read from the directory of the script you invoke, so run this from\n"
        f"a source checkout. Running the installed {TOOL_ENTRY} would copy\n"
        "the node's own copy onto itself and change nothing.",
    )
    tools_update.add_argument("--nomad-version",
                              help="Nomad version recorded in tool metadata; defaults to existing metadata. "
                                   "This only records a version, it does not change the binary: use upgrade for that")
    tools_update.set_defaults(func=cmd_tools_update)

    uninstall = sub.add_parser("uninstall", description="Stop Nomad and remove runtime files after showing a removal plan.\n"
        "\n"
        "Run --dry-run first: the real uninstall deletes the config and data directories,\n"
        "which destroys job state. Installed tools and audit logs are preserved unless\n"
        "--remove-tools or --purge is given.")
    uninstall.add_argument("--remove-tools", action="store_true", help="Also remove nomad-manager and nomad-job from the managed install")
    uninstall.add_argument("--purge", action="store_true", help="Remove runtime files, tools, metadata and audit logs")
    uninstall.add_argument("--dry-run", action="store_true", help="Print the uninstall plan without changing files")
    uninstall.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    uninstall.set_defaults(func=cmd_uninstall)

    quickstart = sub.add_parser("quickstart")
    quickstart.set_defaults(func=cmd_quickstart)

    tutor = sub.add_parser("tutor")
    tutor.add_argument("topic", nargs="?", help="Topic name")
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
    config = AuditConfig("nomad-manager", AUDIT_LOG_FILE, {"tool_dir": str(TOOL_DIR)})
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
