from __future__ import annotations

import argparse
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
    log_error,
    log_info,
    log_success,
    log_warn,
    missing_subcommand,
    parse_bool,
    parse_csv,
    require_command,
    require_linux,
    run,
    run_root,
    run_with_audit,
    safe_remove_path,
    sha256_file,
    terminal_status_prefix,
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
HOST_VOLUME_DIR = NOMAD_ROOT_DIR / "volumes"
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
DEFAULT_VAULT_ADDR = "http://127.0.0.1:8200"
LOCAL_NO_PROXY = "127.0.0.1,localhost,::1"
MANAGED_MARKER = "# Managed by tools/nomad/nomad-manager"
TLS_CONFIG = CONFIG_DIR / "30-tls.hcl"
UI_CONFIG = CONFIG_DIR / "35-ui.hcl"
TELEMETRY_CONFIG = CONFIG_DIR / "40-telemetry.hcl"
VAULT_CONFIG = CONFIG_DIR / "60-vault.hcl"
VAULT_CLIENT_ENV_FILE = Path("/opt/vault/etc/vault.d/client.env")
CONSUL_CONFIG = CONFIG_DIR / "60-consul.hcl"
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


def cni_client_config_content() -> str:
    body = "\n".join(
        [
            "client {",
            f"  cni_path       = {hcl_string(CNI_BIN_DIR)}",
            f"  cni_config_dir = {hcl_string(CNI_CONFIG_DIR)}",
            "}",
        ]
    )
    return managed_config(body)


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


def write_cni_client_config(*, restart: bool) -> None:
    if restart:
        commit_managed_file(CNI_CLIENT_CONFIG, cni_client_config_content())
        return
    ensure_managed_or_absent(CNI_CLIENT_CONFIG)
    install_text(CNI_CLIENT_CONFIG, cni_client_config_content(), mode="0644")


def enable_cni(version: str, *, restart: bool) -> None:
    require_config_environment()
    version = normalize_cni_version(version)
    install_cni_plugins(version)
    run_root(["install", "-d", "-m", "0755", str(CNI_CONFIG_DIR)])
    apply_cni_sysctl()
    write_cni_client_config(restart=restart)
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
    }
    label, color = labels.get(status, (status, ""))
    print(f"{color_text(f'{label:<5}', color)} {message}")


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


def shell_command(args: list[str]) -> str:
    return " ".join(shlex.quote(str(item)) for item in args)


def vault_jwt_apply_command(data: dict[str, Any], *, force: bool = False) -> str:
    command = [
        NOMAD_MANAGER_CMD,
        "vault-jwt",
        "apply",
        "--profile",
        data["profile"],
        "--vault-addr",
        data["vault_addr"],
        "--nomad-addr",
        data["nomad_addr"],
        "--auth-path",
        data["auth_path"],
        "--role",
        data["role"],
        "--policy",
        data["policy"],
        "--aud",
        data["aud"],
        "--ttl",
        data["ttl"],
    ]
    if data.get("vault_namespace"):
        command.extend(["--vault-namespace", data["vault_namespace"]])
    if data.get("nomad_jwks_url"):
        command.extend(["--nomad-jwks-url", data["nomad_jwks_url"]])
    for secret_path in data["secret_paths"]:
        command.extend(["--secret-path", secret_path])
    if data.get("policy_file"):
        command.extend(["--policy-file", data["policy_file"]])
    if force:
        command.append("--force")
    return shell_command(command)


def cmd_vault_jwt_plan(args: argparse.Namespace) -> int:
    data = prepare_profile(args)
    print(profile_summary(data))
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
        f"Next:\n  {vault_jwt_apply_command(data, force=args.force)}"
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
    failures = 0
    print("Preflight:")
    if command_exists("vault"):
        doctor_check("OK", f"vault CLI found: {shutil.which('vault')}")
    else:
        doctor_check("FAIL", "vault CLI not found")
        failures += 1
        return failures

    health_url = f"{str(data['vault_addr']).rstrip('/')}/v1/sys/health"
    code = http_status(health_url, cafile=vault_ca_cert_file(data["vault_addr"]))
    if code in {200, 429, 472, 473, 501, 503}:
        doctor_check("OK", f"Vault health endpoint reachable: {health_url} ({code})")
    else:
        doctor_check("FAIL", f"Vault health endpoint not reachable: {health_url} ({code})")
        failures += 1

    status = vault_status_json_for_jwt(data)
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

    auth_type = ""
    if status is not None and status.get("sealed") is False:
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

    if wait_http(data["nomad_jwks_url"], attempts=1, delay=0):
        doctor_check("OK", f"Nomad JWKS URL reachable: {data['nomad_jwks_url']}")
    else:
        doctor_check("FAIL", f"Nomad JWKS URL not reachable: {data['nomad_jwks_url']}")
        failures += 1

    policy_file = data.get("policy_file")
    if policy_file and not Path(policy_file).is_file():
        doctor_check("FAIL", f"Policy file not found: {policy_file}")
        failures += 1
    elif policy_file:
        doctor_check("OK", f"Policy file readable: {policy_file}")
    else:
        doctor_check("OK", "Vault policy will be generated")

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
    log_success(f"Nomad binary entry installed: {BIN_ENTRY}")
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
        "host_volume_dir": str(HOST_VOLUME_DIR),
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
            f"Host volume dir: {HOST_VOLUME_DIR}",
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
    log_success(f"Nomad manager entry installed: {TOOL_ENTRY}")
    log_success(f"Nomad job entry installed: {JOB_ENTRY}")


def read_installed_nomad_version() -> str:
    try:
        metadata = json.loads(INSTALL_METADATA_FILE.read_text(encoding="utf-8"))
        if isinstance(metadata, dict):
            version = metadata.get("nomad_version")
            if isinstance(version, str) and version.strip():
                return version.strip()
    except (OSError, json.JSONDecodeError):
        pass
    try:
        for line in TOOL_VERSION_FILE.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key == "nomad_version" and value.strip():
                return value.strip()
    except OSError:
        pass
    return "unknown"


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
    first = token_file.open("r", encoding="utf-8").readline().rstrip("\n")
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
        if args.enable_cni:
            enable_cni(args.cni_version, restart=True)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    log_success("Nomad installation completed")
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
    return [SYSTEMD_SERVICE, BIN_ENTRY, BIN_PATH, CONFIG_DIR, DATA_DIR]


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
        f"""Nomad manager quickstart:
  1. Install a single-node Nomad:
     {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}

  2. Check node health:
     {NOMAD_MANAGER_CMD} doctor

  3. Enable Docker settings when needed:
     {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes --image-gc

  4. Enable CNI bridge networking when jobs use network mode bridge:
     {NOMAD_MANAGER_CMD} cni enable

  5. Generate and apply a job:
     nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl
     nomad-job validate jobs/web.nomad.hcl
     nomad-job plan jobs/web.nomad.hcl
     nomad-job apply jobs/web.nomad.hcl

  6. Review destructive actions before removal:
     {NOMAD_MANAGER_CMD} uninstall --dry-run
"""
    )
    return 0


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
    vault_jwt_apply_command_line = shell_command([NOMAD_MANAGER_CMD, "vault-jwt", "apply", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR])
    vault_secret_plan_command = shell_command([NOMAD_MANAGER_CMD, "vault-jwt", "plan", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR, "--secret-path", vault_secret_path])
    vault_secret_apply_command = shell_command([NOMAD_MANAGER_CMD, "vault-jwt", "apply", "--profile", "default", "--vault-addr", vault_addr, "--nomad-addr", NOMAD_ADDR, "--secret-path", vault_secret_path])
    topics = {
        "overview": f"""Nomad manager tutor:
  Purpose:
    Manage single-node Nomad setup, node config and integrations.

  Common path:
    {NOMAD_MANAGER_CMD} quickstart
    {NOMAD_MANAGER_CMD} doctor

  Topics:
    install, docker, cni, vault, vault-jwt, consul, ui, workflows, vault-secret-job, host-volume-job, private-image-job, web-service-job, uninstall, troubleshoot
""",
        "install": f"Install a single node:\n  {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}",
        "docker": f"Enable Docker support:\n  {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes",
        "cni": f"Enable CNI bridge networking:\n  {NOMAD_MANAGER_CMD} cni plan\n  {NOMAD_MANAGER_CMD} cni enable\n  {NOMAD_MANAGER_CMD} cni status",
        "vault": f"Point Nomad at Vault:\n  {vault_enable_command}",
        "vault-jwt": f"Link workload identity:\n  {vault_jwt_apply_command_line}",
        "consul": f"Point Nomad at Consul:\n  {NOMAD_MANAGER_CMD} consul enable --address 127.0.0.1:8500",
        "ui": f"Enable UI settings:\n  {NOMAD_MANAGER_CMD} ui enable",
        "workflows": f"""Workflow topics:
  {NOMAD_MANAGER_CMD} tutor vault-secret-job
  {NOMAD_MANAGER_CMD} tutor host-volume-job
  {NOMAD_MANAGER_CMD} tutor private-image-job
  {NOMAD_MANAGER_CMD} tutor web-service-job
""",
        "vault-secret-job": f"""Run a Vault-backed job workflow:
  {shell_export_line('VAULT_ADDR', vault_addr)}
{vault_cacert_export}  export VAULT_TOKEN=<root-token-or-admin-token>
  vault secrets enable -path=kv kv-v2
  vault kv put kv/app/config value='my-secret-value' username='app-user' password='app-password' api_key='app-api-key'
  vault kv get kv/app/config
  {vault_secret_plan_command}
  {vault_secret_apply_command}
  {NOMAD_MANAGER_CMD} vault-jwt job-example --profile default --job web --secret kv/data/app/config --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl

Notes:
  vault kv put uses the KV CLI path kv/app/config.
  Nomad templates and Vault policies use the KV v2 API path kv/data/app/config.
  If kv/ is already enabled, skip the vault secrets enable command.
  Avoid putting real secret values directly in shared shell history.
""",
        "host-volume-job": f"""Run a job with a managed host volume:
  {NOMAD_MANAGER_CMD} host-volume add data --create
  nomad-job scaffold docker --job web --image nginx:1.27 --host-volume data:/opt/data:rw --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl
""",
        "private-image-job": f"""Run a job from a private registry:
  {NOMAD_MANAGER_CMD} docker enable --auth-config /root/.docker/config.json
  nomad-job scaffold docker --job private-web --image registry.example.com/app:1.0 --out jobs/private-web.nomad.hcl
  nomad-job validate jobs/private-web.nomad.hcl
  nomad-job plan jobs/private-web.nomad.hcl
  nomad-job apply jobs/private-web.nomad.hcl
""",
        "web-service-job": f"""Run an HTTP service job:
  {NOMAD_MANAGER_CMD} docker enable --volumes
  nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --check-http / --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl
  nomad-job apply jobs/web.nomad.hcl
""",
        "uninstall": f"Preview removal before changing the node:\n  {NOMAD_MANAGER_CMD} uninstall --dry-run\n  {NOMAD_MANAGER_CMD} uninstall --yes",
        "troubleshoot": f"Start with the aggregate check:\n  {NOMAD_MANAGER_CMD} doctor\n  {NOMAD_MANAGER_CMD} docker doctor\n  {NOMAD_MANAGER_CMD} vault doctor\n  {NOMAD_MANAGER_CMD} consul doctor",
    }
    if topic not in topics:
        raise CLIError(f"Unknown tutor topic: {topic}")
    print(topics[topic])
    return 0


def add_common_vault_jwt_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile", required=True, help="Local profile name")
    parser.add_argument("--vault-addr", help="Vault address, for example http://127.0.0.1:8200")
    parser.add_argument("--vault-namespace", help="Vault Enterprise namespace")
    parser.add_argument("--nomad-addr", help="Nomad address used to derive the JWKS URL")
    parser.add_argument("--nomad-jwks-url", help="Explicit Nomad JWKS URL")
    parser.add_argument("--auth-path", help="Vault JWT auth mount path")
    parser.add_argument("--role", help="Vault role name")
    parser.add_argument("--policy", help="Vault policy name")
    parser.add_argument("--aud", help="Comma-separated JWT audiences")
    parser.add_argument("--ttl", help="Vault token TTL")
    parser.add_argument("--secret-path", action="append", help="Vault secret path allowed by the generated policy; repeat for multiple paths")
    parser.add_argument("--policy-file", help="Use an existing Vault policy HCL file")
    parser.add_argument("--force", action="store_true", help="Replace an existing profile with different values")


def build_parser() -> argparse.ArgumentParser:
    parser = CLIArgumentParser(
        prog=NOMAD_MANAGER_CMD,
        description="Install and manage a single-node Nomad setup.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} quickstart
  {NOMAD_MANAGER_CMD} install --version {DEFAULT_NOMAD_VERSION}
  {NOMAD_MANAGER_CMD} tools update
  {NOMAD_MANAGER_CMD} doctor
  {NOMAD_MANAGER_CMD} docker enable --allow-privileged --volumes
  {NOMAD_MANAGER_CMD} uninstall --dry-run
""",
    )
    sub = parser.add_subparsers(dest="command")
    parser.set_defaults(func=lambda _: missing_subcommand(parser, NOMAD_MANAGER_CMD))

    install = sub.add_parser("install", help="Install Nomad", description="Install Nomad, write managed config and start nomad.service.")
    install.add_argument("version_pos", nargs="?", help="Nomad version, for example 2.0.0 or latest")
    install.add_argument("--version", dest="version_opt", help="Nomad version; overrides the positional version")
    install.add_argument("--no-acl-bootstrap", action="store_true", help="Skip automatic ACL bootstrap after install")
    install.add_argument("--enable-cni", action="store_true", help="Install and configure CNI plugins after Nomad install")
    install.add_argument("--cni-version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    install.set_defaults(func=lambda args: cmd_install(argparse.Namespace(version=args.version_opt or args.version_pos, no_acl_bootstrap=args.no_acl_bootstrap, enable_cni=args.enable_cni, cni_version=args.cni_version)))

    uninstall = sub.add_parser("uninstall", help="Uninstall Nomad", description="Stop Nomad and remove runtime files after showing a removal plan.")
    uninstall.add_argument("--remove-tools", action="store_true", help="Also remove nomad-manager and nomad-job from the managed install")
    uninstall.add_argument("--purge", action="store_true", help="Remove runtime files, tools, metadata and audit logs")
    uninstall.add_argument("--dry-run", action="store_true", help="Print the uninstall plan without changing files")
    uninstall.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    uninstall.set_defaults(func=cmd_uninstall)

    doctor = sub.add_parser("doctor", help="Run node and integration checks", description="Check the managed Nomad install, service status and detected integrations.")
    doctor.add_argument("--integrations", action="store_true", help="Run Docker, CNI, Vault and Consul checks even if their managed configs are absent")
    doctor.set_defaults(func=cmd_doctor)

    quickstart = sub.add_parser("quickstart", help="Show a copyable setup workflow")
    quickstart.set_defaults(func=cmd_quickstart)

    tools = sub.add_parser("tools", help="Manage installed tool files")
    tools_sub = tools.add_subparsers(dest="tools_command")
    tools.set_defaults(func=lambda _: missing_subcommand(tools, f"{NOMAD_MANAGER_CMD} tools"))
    tools_update = tools_sub.add_parser(
        "update",
        help="Update nomad-manager and nomad-job files only",
        description="Update the installed nomad-manager, nomad-job and nomad_tools package without changing Nomad binary, config or service state.",
    )
    tools_update.add_argument("--nomad-version", help="Nomad version recorded in tool metadata; defaults to existing metadata")
    tools_update.set_defaults(func=cmd_tools_update)

    vault = sub.add_parser("vault", help="Manage Vault integration")
    vault_sub = vault.add_subparsers(dest="vault_command")
    vault.set_defaults(func=lambda _: missing_subcommand(vault, f"{NOMAD_MANAGER_CMD} vault"))
    vault_enable = vault_sub.add_parser("enable", help="Write Nomad Vault integration config")
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
    vault_disable = vault_sub.add_parser("disable", help="Remove managed Vault config")
    vault_disable.set_defaults(func=lambda _: remove_managed_file(VAULT_CONFIG) or 0)
    vault_doctor = vault_sub.add_parser("doctor", help="Check Vault integration")
    vault_doctor.add_argument("--address", help="Override Vault address for the check")
    vault_doctor.add_argument("--namespace", help="Override Vault namespace for the check")
    vault_doctor.set_defaults(func=cmd_vault_doctor)

    consul = sub.add_parser("consul", help="Manage Consul integration")
    consul_sub = consul.add_subparsers(dest="consul_command")
    consul.set_defaults(func=lambda _: missing_subcommand(consul, f"{NOMAD_MANAGER_CMD} consul"))
    consul_enable = consul_sub.add_parser("enable", help="Write Nomad Consul integration config")
    consul_enable.add_argument("--address", required=True, help="Consul HTTP address, for example 127.0.0.1:8500")
    consul_enable.add_argument("--grpc-address", default="", help="Consul gRPC address")
    consul_enable.add_argument("--ca-file", default="", help="Consul CA certificate file")
    consul_enable.add_argument("--cert-file", default="", help="Consul client certificate file")
    consul_enable.add_argument("--key-file", default="", help="Consul client key file")
    add_bool_argument(consul_enable, "--ssl", default=False, help_text="Use HTTPS for Consul", no_help="Use HTTP for Consul")
    add_bool_argument(consul_enable, "--verify", default=True, help_text="Verify Consul TLS certificates", no_help="Skip Consul TLS certificate verification")
    consul_enable.add_argument("--aud", default="consul.io", help="Comma-separated service identity audiences")
    consul_enable.add_argument("--ttl", default="1h", help="Service identity token TTL")
    consul_enable.set_defaults(func=cmd_consul_enable)
    consul_disable = consul_sub.add_parser("disable", help="Remove managed Consul config")
    consul_disable.set_defaults(func=lambda _: remove_managed_file(CONSUL_CONFIG) or 0)
    consul_doctor = consul_sub.add_parser("doctor", help="Check Consul integration")
    consul_doctor.add_argument("--address", help="Override Consul address for the check")
    consul_doctor.add_argument("--ssl", type=bool_arg, help="Override detected Consul TLS mode with true or false")
    consul_doctor.set_defaults(func=cmd_consul_doctor)

    telemetry = sub.add_parser("telemetry", help="Manage telemetry config")
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

    tls = sub.add_parser("tls", help="Manage TLS config")
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

    ui = sub.add_parser("ui", help="Manage UI config")
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

    docker = sub.add_parser("docker", help="Manage Docker driver config")
    docker_sub = docker.add_subparsers(dest="docker_command")
    docker.set_defaults(func=lambda _: missing_subcommand(docker, f"{NOMAD_MANAGER_CMD} docker"))
    docker_enable = docker_sub.add_parser("enable", help="Write managed Docker driver config")
    add_bool_argument(docker_enable, "--allow-privileged", default=True, help_text="Allow privileged Docker tasks", no_help="Disallow privileged Docker tasks")
    add_bool_argument(docker_enable, "--volumes", default=True, help_text="Allow Docker volume mounts", no_help="Disallow Docker volume mounts")
    add_bool_argument(docker_enable, "--image-gc", default=True, help_text="Enable Docker image garbage collection", no_help="Disable Docker image garbage collection")
    docker_enable.add_argument("--image-delay", default="100h", help="Nomad Docker image GC delay")
    docker_enable.add_argument("--auth-config", help="Docker auth config path for private registries")
    docker_enable.set_defaults(func=cmd_docker_enable)
    docker_disable = docker_sub.add_parser("disable", help="Remove managed Docker config")
    docker_disable.set_defaults(func=lambda _: remove_managed_file(DOCKER_CONFIG) or 0)
    docker_disable_driver = docker_sub.add_parser("disable-driver", help="Add docker to the Nomad driver denylist")
    docker_disable_driver.set_defaults(func=lambda _: cmd_driver_deny(argparse.Namespace(driver="docker")))
    docker_enable_driver = docker_sub.add_parser("enable-driver", help="Remove docker from the Nomad driver denylist")
    docker_enable_driver.set_defaults(func=lambda _: cmd_driver_allow(argparse.Namespace(driver="docker")))
    docker_doctor = docker_sub.add_parser("doctor", help="Check Docker integration")
    docker_doctor.set_defaults(func=cmd_docker_doctor)

    cni = sub.add_parser("cni", help="Manage CNI plugins for Nomad bridge networking")
    cni_sub = cni.add_subparsers(dest="cni_command")
    cni.set_defaults(func=lambda _: missing_subcommand(cni, f"{NOMAD_MANAGER_CMD} cni"))
    cni_plan = cni_sub.add_parser("plan", help="Preview CNI plugin installation and Nomad config changes")
    cni_plan.add_argument("--version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    cni_plan.set_defaults(func=cmd_cni_plan)
    cni_enable = cni_sub.add_parser("enable", help="Install CNI plugins and write Nomad client CNI config")
    cni_enable.add_argument("--version", default=DEFAULT_CNI_PLUGIN_VERSION, help=f"CNI plugins version (default: {DEFAULT_CNI_PLUGIN_VERSION})")
    cni_enable.set_defaults(func=cmd_cni_enable)
    cni_disable = cni_sub.add_parser("disable", help="Remove managed Nomad CNI config")
    cni_disable.add_argument("--remove-plugins", action="store_true", help=f"Also remove {CNI_BIN_DIR}")
    cni_disable.set_defaults(func=cmd_cni_disable)
    cni_status = cni_sub.add_parser("status", help="Check CNI plugin and bridge sysctl status")
    cni_status.set_defaults(func=cmd_cni_status)

    raw_exec = sub.add_parser("raw-exec", help="Manage raw_exec driver config")
    raw_sub = raw_exec.add_subparsers(dest="raw_exec_command")
    raw_exec.set_defaults(func=lambda _: missing_subcommand(raw_exec, f"{NOMAD_MANAGER_CMD} raw-exec"))
    raw_enable = raw_sub.add_parser("enable", help="Enable raw_exec")
    raw_enable.set_defaults(func=cmd_raw_exec_enable)
    raw_disable = raw_sub.add_parser("disable", help="Remove managed raw_exec config")
    raw_disable.set_defaults(func=lambda _: remove_managed_file(RAW_EXEC_CONFIG) or 0)

    driver = sub.add_parser("driver", help="Manage driver denylist")
    driver_sub = driver.add_subparsers(dest="driver_command")
    driver.set_defaults(func=lambda _: missing_subcommand(driver, f"{NOMAD_MANAGER_CMD} driver"))
    driver_deny = driver_sub.add_parser("deny", help="Add a driver to the denylist")
    driver_deny.add_argument("driver", help="Driver name")
    driver_deny.set_defaults(func=cmd_driver_deny)
    driver_allow = driver_sub.add_parser("allow", help="Remove a driver from the denylist")
    driver_allow.add_argument("driver", help="Driver name")
    driver_allow.set_defaults(func=cmd_driver_allow)

    host_volume = sub.add_parser(
        "host-volume",
        help="Manage host volumes",
        description="Manage Nomad client host volume configs.",
        epilog=f"""Examples:
  {NOMAD_MANAGER_CMD} host-volume add data --create
  nomad-job scaffold docker --job web --image nginx:1.27 --host-volume data:/opt/data:rw --out jobs/web.nomad.hcl
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
    hv_remove = hv_sub.add_parser("remove", help="Remove a managed host volume config")
    hv_remove.add_argument("name", help="Host volume name")
    hv_remove.set_defaults(func=lambda args: remove_managed_file(host_volume_config_path(args.name)) or 0)

    meta = sub.add_parser("meta", help="Manage client meta")
    meta_sub = meta.add_subparsers(dest="meta_command")
    meta.set_defaults(func=lambda _: missing_subcommand(meta, f"{NOMAD_MANAGER_CMD} meta"))
    meta_set = meta_sub.add_parser("set", help="Set a client meta key")
    meta_set.add_argument("key", help="Meta key")
    meta_set.add_argument("value", help="Meta value")
    meta_set.set_defaults(func=cmd_meta_set)
    meta_unset = meta_sub.add_parser("unset", help="Remove a client meta key")
    meta_unset.add_argument("key", help="Meta key")
    meta_unset.set_defaults(func=cmd_meta_unset)

    vault_jwt = sub.add_parser("vault-jwt", help="Manage Vault JWT workload identity")
    jwt_sub = vault_jwt.add_subparsers(dest="vault_jwt_command")
    vault_jwt.set_defaults(func=lambda _: missing_subcommand(vault_jwt, f"{NOMAD_MANAGER_CMD} vault-jwt"))
    jwt_plan = jwt_sub.add_parser("plan", help="Preview Vault JWT workload identity changes")
    add_common_vault_jwt_args(jwt_plan)
    jwt_plan.set_defaults(func=cmd_vault_jwt_plan)
    jwt_apply = jwt_sub.add_parser("apply", help="Apply Vault JWT workload identity changes")
    add_common_vault_jwt_args(jwt_apply)
    jwt_apply.set_defaults(func=cmd_vault_jwt_apply)
    jwt_status = jwt_sub.add_parser("status", help="Check a Vault JWT profile")
    jwt_status.add_argument("--profile", required=True, help="Local profile name")
    jwt_status.set_defaults(func=cmd_vault_jwt_status)
    jwt_doctor = jwt_sub.add_parser("doctor", help="Check and suggest fixes for a Vault JWT profile")
    jwt_doctor.add_argument("--profile", required=True, help="Local profile name")
    jwt_doctor.set_defaults(func=cmd_vault_jwt_doctor)
    jwt_job = jwt_sub.add_parser("job-example", help="Generate an example job using Vault JWT")
    jwt_job.add_argument("--profile", required=True, help="Local profile name")
    jwt_job.add_argument("--job", required=True, help="Example Nomad job name")
    jwt_job.add_argument("--secret", required=True, help="Vault secret path used by the example")
    jwt_job.add_argument("--out", default="-", help="Output HCL path, or '-' for stdout")
    jwt_job.add_argument("--image", default="alpine:3.20", help="Example Docker image")
    jwt_job.add_argument("--force", action="store_true", help="Overwrite an existing output file")
    jwt_job.set_defaults(func=cmd_vault_jwt_job_example)

    tutor = sub.add_parser("tutor", help="Show short workflow guidance")
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
