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
from dataclasses import dataclass
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
    color_text,
    command_exists,
    current_script_dir,
    detect_arch,
    download_file,
    ensure_default_path,
    extract_tar_gz,
    fetch_url,
    http_status,
    install_text,
    kept_binary_versions,
    linked_binary_path,
    log_error,
    log_info,
    log_success,
    log_warn,
    missing_subcommand,
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
    version_tuple,
    versioned_binary_path,
)


MONCTL_CMD = os.environ.get("MONCTL_CMD", "monctl")

ROOT_DIR = Path("/opt/monitoring")
BIN_DIR = ROOT_DIR / "bin"
BINARY_VERSION_DIR = BIN_DIR / "versions"
ETC_DIR = ROOT_DIR / "etc"
DATA_ROOT = ROOT_DIR / "data"
SHARE_DIR = ROOT_DIR / "share"
LOG_ROOT = ROOT_DIR / "log"

PROMETHEUS_CONFIG_DIR = ETC_DIR / "prometheus"
PROMETHEUS_CONFIG_FILE = PROMETHEUS_CONFIG_DIR / "prometheus.yml"
PROMETHEUS_TARGET_DIR = PROMETHEUS_CONFIG_DIR / "targets"
PROMETHEUS_DATA_DIR = DATA_ROOT / "prometheus"

GRAFANA_CONFIG_DIR = ETC_DIR / "grafana"
GRAFANA_CONFIG_FILE = GRAFANA_CONFIG_DIR / "grafana.ini"
GRAFANA_PROVISIONING_DIR = GRAFANA_CONFIG_DIR / "provisioning"
GRAFANA_DATASOURCE_FILE = GRAFANA_PROVISIONING_DIR / "datasources" / "prometheus.yaml"
# Grafana reads all of these at startup and logs an error for each one missing
GRAFANA_PROVISIONING_SUBDIRS = ("datasources", "dashboards", "plugins", "notifiers",
                                "alerting", "access-control")
GRAFANA_HOME_DIR = SHARE_DIR / "grafana"
GRAFANA_VERSION_DIR = GRAFANA_HOME_DIR / "versions"
GRAFANA_CURRENT_DIR = GRAFANA_HOME_DIR / "current"
GRAFANA_DATA_DIR = DATA_ROOT / "grafana"
GRAFANA_LOG_DIR = LOG_ROOT / "grafana"

TOOL_DIR = ROOT_DIR / "lib" / "monctl"
TOOL_STATE_DIR = DATA_ROOT / "monctl"
TOOL_LOG_DIR = LOG_ROOT / "monctl"
TOOL_PATH = BIN_DIR / "monctl"
TOOL_ENTRY = Path("/usr/local/bin/monctl")
TOOL_VERSION_FILE = TOOL_DIR / "VERSION"
TOOL_MANIFEST_FILE = TOOL_DIR / "MANIFEST.sha256"
INSTALL_METADATA_FILE = TOOL_STATE_DIR / "install.json"
AUDIT_LOG_FILE = TOOL_LOG_DIR / "manager.audit.log"

MANAGED_MARKER = "# Managed by tools/monitoring/monctl"
SYSTEMD_DIR = Path("/etc/systemd/system")

DEFAULT_NODE_EXPORTER_LISTEN = "0.0.0.0:9100"
DEFAULT_PROMETHEUS_LISTEN = "127.0.0.1:9090"
DEFAULT_PROMETHEUS_RETENTION = "15d"
DEFAULT_SCRAPE_INTERVAL = "15s"
DEFAULT_GRAFANA_ADDR = "0.0.0.0"
DEFAULT_GRAFANA_PORT = 3000
DEFAULT_GRAFANA_DOMAIN = "localhost"
DEFAULT_JOB = "node"
# Grafana provisions the datasource but no dashboard, so a fresh install shows an
# empty home page while the data is already there. 1860 is Node Exporter Full.
GRAFANA_DASHBOARD_ID = 1860
GRAFANA_DASHBOARD_STEPS = (
    f"Dashboards -> New -> Import, enter {GRAFANA_DASHBOARD_ID} (Node Exporter Full),",
    "Load, pick the Prometheus datasource, Import",
)


def dashboard_hint(indent: str) -> str:
    """The import steps, wrapped to the width of whatever is printing them."""
    return f"\n{indent}".join(GRAFANA_DASHBOARD_STEPS)
TARGET_REFRESH_INTERVAL = "30s"
LOCAL_ADDRESSES = {"127.0.0.1", "localhost", "::1", "[::1]"}

# Paths the shell installer under tools.old/grafana used. Nothing here is managed
# by this tool, so install refuses to run over them unless --force is given.
LEGACY_PATHS = (
    Path("/usr/local/bin/node_exporter"),
    Path("/usr/local/bin/prometheus"),
    Path("/usr/local/bin/promtool"),
    Path("/etc/prometheus"),
    Path("/var/lib/prometheus"),
)


@dataclass(frozen=True)
class Component:
    """One managed piece of the metrics stack."""

    name: str           # name on the command line
    service: str        # systemd unit name, also the release archive prefix
    user: str           # system user the unit runs as
    binaries: tuple[str, ...]  # binaries kept under BINARY_VERSION_DIR
    default_version: str       # used only when the release index cannot be reached
    repo: str           # GitHub repository the releases come from
    summary: str


NODE_EXPORTER = Component(
    name="node-exporter",
    service="node_exporter",
    user="node_exporter",
    binaries=("node_exporter",),
    default_version="1.12.1",
    repo="prometheus/node_exporter",
    summary="Host metrics exporter, one per machine you want to watch",
)
PROMETHEUS = Component(
    name="prometheus",
    service="prometheus",
    user="prometheus",
    binaries=("prometheus", "promtool"),
    default_version="3.14.0",
    repo="prometheus/prometheus",
    summary="Scrapes the exporters and stores the time series",
)
GRAFANA = Component(
    name="grafana",
    service="grafana",
    user="grafana",
    binaries=(),
    default_version="13.2.2",
    repo="grafana/grafana",
    summary="Dashboards on top of Prometheus",
)

COMPONENTS: dict[str, Component] = {
    NODE_EXPORTER.name: NODE_EXPORTER,
    PROMETHEUS.name: PROMETHEUS,
    GRAFANA.name: GRAFANA,
}
COMPONENT_NAMES = tuple(COMPONENTS)


def component_by_name(name: str) -> Component:
    try:
        return COMPONENTS[name]
    except KeyError:
        raise CLIError(f"Unknown component: {name}. Available: {', '.join(COMPONENT_NAMES)}") from None


def service_file(component: Component) -> Path:
    return SYSTEMD_DIR / f"{component.service}.service"


def binary_path(name: str) -> Path:
    return BIN_DIR / name


def normalize_version(version: str) -> str:
    value = version.strip().removeprefix("v")
    if not re.match(r"^[0-9]+[.][0-9]+[.][0-9]+$", value):
        raise CLIError(f"Invalid version: {version}")
    return value


def fetch_latest_version(component: Component) -> str:
    """The newest non-prerelease tag GitHub reports for this component."""
    body = fetch_url(f"https://api.github.com/repos/{component.repo}/releases/latest", timeout=30)
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError as exc:
        raise CLIError(f"Failed to parse the release index for {component.name}: {exc}") from exc
    tag = data.get("tag_name") if isinstance(data, dict) else ""
    if not isinstance(tag, str) or not tag:
        raise CLIError(f"Failed to resolve the latest {component.name} version")
    return normalize_version(tag)


def resolve_version(component: Component, requested: str | None) -> str:
    """Pick the version to install, falling back to the pinned default when offline."""
    if requested and requested != "latest":
        return normalize_version(requested)
    try:
        latest = fetch_latest_version(component)
        log_success(f"Resolved latest {component.name} version: {latest}")
        return latest
    except Exception:
        log_warn(f"Failed to resolve the latest {component.name} version, "
                 f"falling back to {component.default_version}")
        return component.default_version


def resolve_upgrade_target(component: Component, requested: str) -> str:
    """Resolve what to upgrade to, failing rather than guessing.

    resolve_version falls back to the pinned default when the release index is
    unreachable. That is fine for a fresh install, but here it would move a
    running node onto a version nobody asked for.
    """
    if requested and requested != "latest":
        return normalize_version(requested)
    try:
        latest = fetch_latest_version(component)
    except CLIError:
        raise
    except Exception as exc:
        raise CLIError(f"Cannot resolve the latest {component.name} version: {exc}. "
                       f"Pass --version to pick one explicitly") from exc
    log_success(f"Resolved latest {component.name} version: {latest}")
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


def require_managed_or_absent(path: Path, force: bool) -> None:
    """Never overwrite a config or unit file this tool did not write."""
    if not path.exists() or is_managed_file(path):
        return
    if force:
        log_warn(f"Overwriting a file this tool does not manage: {path}")
        return
    raise CLIError(f"Refuse to overwrite a file this tool does not manage: {path}. "
                   f"Move it aside, or re-run with --force")


def managed_text(body: str) -> str:
    return f"{MANAGED_MARKER}\n{body.rstrip()}\n"


def legacy_install_paths() -> list[Path]:
    """Leftovers from the old shell installer, which used different paths."""
    found = [path for path in LEGACY_PATHS if path.exists() or path.is_symlink()]
    for component in COMPONENTS.values():
        unit = service_file(component)
        if unit.is_file() and not is_managed_file(unit):
            found.append(unit)
    return found


def require_no_legacy_install(component: Component, force: bool) -> None:
    unit = service_file(component)
    conflicts = [path for path in legacy_install_paths()
                 if path == unit or path.name in {component.service, *component.binaries}]
    if not conflicts:
        return
    if force:
        for path in conflicts:
            log_warn(f"Unmanaged {component.name} path left in place: {path}")
        return
    listed = "\n".join(f"    - {path}" for path in conflicts)
    raise CLIError(
        f"This host already has an unmanaged {component.name} install:\n{listed}\n"
        f"  Those paths come from the old tools.old/grafana/install.sh layout and are not\n"
        f"  touched by this tool. Stop and remove them first, or re-run with --force to\n"
        f"  install alongside them (two units on the same port will fight)."
    )


def systemd_available() -> bool:
    return command_exists("systemctl")


def service_state(component: Component) -> str:
    if not systemd_available():
        return "unknown"
    result = run(["systemctl", "is-active", component.service], check=False, capture=True)
    return (result.stdout or "").strip() or "unknown"


def service_active(component: Component) -> bool:
    return service_state(component) == "active"


def dump_service_log(component: Component) -> None:
    if command_exists("journalctl"):
        run_root(["journalctl", "-u", component.service, "-n", "60", "--no-pager"], check=False)


def restart_service(component: Component) -> None:
    run_root(["systemctl", "restart", component.service])
    time.sleep(2)
    if not service_active(component):
        dump_service_log(component)
        raise CLIError(f"{component.service}.service failed to start")


def reload_service(component: Component) -> None:
    run_root(["systemctl", "reload", component.service])


def enable_service(component: Component) -> None:
    run_root(["systemctl", "daemon-reload"])
    run_root(["systemctl", "enable", component.service])
    restart_service(component)


def listen_host(listen: str) -> str:
    return listen.rsplit(":", 1)[0] if ":" in listen else listen


def listen_port(listen: str) -> str:
    return listen.rsplit(":", 1)[1] if ":" in listen else ""


def reachable_address(listen: str) -> str:
    """The address to talk to a service that may be bound to every interface."""
    host = listen_host(listen)
    if host in {"", "0.0.0.0", "::", "[::]", "*"}:
        host = "127.0.0.1"
    return f"{host}:{listen_port(listen)}" if listen_port(listen) else host


def validate_listen(value: str, label: str) -> str:
    host, _, port = value.rpartition(":")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise CLIError(f"Invalid {label} (expected HOST:PORT): {value}")
    if re.search(r"[\s'\"]", host):
        raise CLIError(f"Invalid {label}: {value}")
    return value


def validate_job(value: str) -> str:
    # the job name is also the file_sd file name, so keep it path-safe
    if not re.match(r"^[A-Za-z0-9_-]+$", value):
        raise CLIError(f"Invalid job name: {value}. Use letters, digits, '-' and '_'")
    return value


def validate_target(value: str) -> str:
    return validate_listen(value, "target address")


def validate_generated_value(value: str, label: str) -> str:
    """Reject a value that would break the unit file or the ini it is written into.

    Every flag lands on its own continuation line in ExecStart, and every ini
    value on its own line, so whitespace in one of these silently produces a file
    systemd or Grafana reads differently than it looks.
    """
    if re.search(r"\s", value):
        raise CLIError(f"Invalid {label}, whitespace is not allowed here: {value!r}")
    return value


def parse_label(value: str) -> tuple[str, str]:
    key, sep, label_value = value.partition("=")
    if not sep or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        raise CLIError(f"Invalid label (expected key=value): {value}")
    if re.search(r'["\\]', label_value):
        raise CLIError(f"Invalid label value: {value}")
    return key, label_value


def create_install_tmpdir(prefix: str) -> Path:
    parent = Path(os.environ.get("TMPDIR", "/var/tmp"))
    if not parent.is_dir() or not os.access(parent, os.W_OK):
        raise CLIError(f"Temporary directory parent is not writable: {parent}. "
                       f"Set TMPDIR to a writable directory with enough space")
    path = Path(tempfile.mkdtemp(prefix=f"{prefix}.", dir=str(parent)))
    log_info(f"Using install temporary directory: {path}")
    return path


def verify_sha256sums(archive: Path, sums_file: Path) -> None:
    """Check archive against a 'sha256sums.txt' style file listing several releases."""
    expected = ""
    for raw in sums_file.read_text(encoding="utf-8").splitlines():
        parts = raw.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == archive.name:
            expected = parts[0]
            break
    if not expected:
        raise CLIError(f"Checksum entry not found for {archive.name}")
    if expected != sha256_file(archive):
        raise CLIError(f"Checksum mismatch for {archive.name}")
    log_success(f"Checksum verified: {archive.name}")


def verify_single_sha256(archive: Path, sums_file: Path) -> None:
    """Check archive against a file that holds one bare hash, as Grafana publishes."""
    text = sums_file.read_text(encoding="utf-8").split()
    expected = text[0] if text else ""
    if not re.match(r"^[0-9a-f]{64}$", expected):
        raise CLIError(f"Unreadable checksum file for {archive.name}")
    if expected != sha256_file(archive):
        raise CLIError(f"Checksum mismatch for {archive.name}")
    log_success(f"Checksum verified: {archive.name}")


def download_prometheus_release(component: Component, version: str, arch: str, tmpdir: Path) -> Path:
    """Download and verify a prometheus.io style release, returning the extracted directory."""
    stem = f"{component.service}-{version}.linux-{arch}"
    archive = tmpdir / f"{stem}.tar.gz"
    sums = tmpdir / "sha256sums.txt"
    base_url = f"https://github.com/{component.repo}/releases/download/v{version}"
    log_info(f"Downloading {component.name} {version} for linux_{arch}")
    download_file(f"{base_url}/{archive.name}", archive, timeout=300)
    download_file(f"{base_url}/sha256sums.txt", sums, timeout=120)
    verify_sha256sums(archive, sums)
    extract_dir = tmpdir / "extract"
    extract_dir.mkdir(parents=True, exist_ok=True)
    extract_tar_gz(archive, extract_dir)
    source = extract_dir / stem
    if not source.is_dir():
        raise CLIError(f"Unexpected archive layout, {stem}/ not found in {archive.name}")
    return source


def grafana_arch(arch: str) -> str:
    if arch not in {"amd64", "arm64"}:
        raise CLIError(f"Grafana publishes no linux-{arch} tarball; install it from the "
                       f"distribution package instead")
    return arch


def download_grafana_release(version: str, arch: str, tmpdir: Path) -> Path:
    name = f"grafana-{version}.linux-{grafana_arch(arch)}.tar.gz"
    archive = tmpdir / name
    sums = tmpdir / f"{name}.sha256"
    base_url = f"https://dl.grafana.com/oss/release/{name}"
    log_info(f"Downloading Grafana {version} for linux_{arch} (around 450 MiB)")
    download_file(base_url, archive, timeout=1800)
    download_file(f"{base_url}.sha256", sums, timeout=120)
    verify_single_sha256(archive, sums)
    extract_dir = tmpdir / "extract"
    extract_dir.mkdir(parents=True, exist_ok=True)
    extract_tar_gz(archive, extract_dir)
    source = extract_dir / f"grafana-{version}"
    if not source.is_dir():
        raise CLIError(f"Unexpected archive layout, grafana-{version}/ not found in {name}")
    return source


def probe_version_output(path: Path, args: list[str]) -> str | None:
    """What a binary prints when asked for its version, or None when it cannot run.

    The Prometheus binaries print this on stdout and Grafana on stderr depending
    on the release, so both are returned. A binary that cannot be executed at all
    is a different problem from one whose output cannot be parsed, so the two are
    reported apart.
    """
    try:
        result = run([str(path), *args], capture=True, check=False)
    except OSError:
        return None
    return (result.stdout or "") + (result.stderr or "")


def parse_reported_version(text: str) -> str:
    match = re.search(r"(?i)version[\s=:]+v?([0-9]+[.][0-9]+[.][0-9]+)", text)
    return match.group(1) if match else ""


def binary_reported_version(path: Path, *, args: list[str] | None = None) -> str:
    """The version a binary prints, or "" when it cannot run or cannot be parsed."""
    text = probe_version_output(path, args or ["--version"])
    return parse_reported_version(text) if text is not None else ""


def verify_staged_version(path: Path, version: str, *, args: list[str] | None = None) -> None:
    """Check a freshly installed release before anything is pointed at it."""
    text = probe_version_output(path, args or ["--version"])
    if text is None:
        raise CLIError(f"The downloaded binary cannot be executed: {path}. "
                       f"The archive may be for another architecture, or the download is damaged")
    reported = parse_reported_version(text)
    if reported and reported != version:
        raise CLIError(f"Installed binary reports version {reported}, expected {version}: {path}")
    if not reported:
        log_warn(f"Could not read the version out of {path}; continuing on the archive name")


def stage_binaries(component: Component, source: Path, version: str) -> list[Path]:
    """Put one release in place under its version and check it runs.

    The release is checked here, before anything points at it, so a bad archive
    fails while the running binaries are still the ones in use.
    """
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BIN_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(BINARY_VERSION_DIR)])
    staged: list[Path] = []
    for name in component.binaries:
        origin = source / name
        if not origin.is_file():
            raise CLIError(f"{name} not found in the {component.name} archive")
        target = versioned_binary_path(BINARY_VERSION_DIR, name, version)
        log_info(f"Installing binary: {target}")
        run_root(["install", "-m", "0755", "-o", "root", "-g", "root", str(origin), str(target)])
        verify_staged_version(target, version)
        staged.append(target)
    return staged


def switch_binaries(component: Component, version: str) -> None:
    for name in component.binaries:
        atomic_symlink(versioned_binary_path(BINARY_VERSION_DIR, name, version), binary_path(name))


def grafana_server_command(home: Path) -> str:
    """How this Grafana release is started.

    Releases from 10 onwards ship bin/grafana with a `server` subcommand and keep
    bin/grafana-server around for a while, so the unit is written from whichever
    the extracted tree actually has.
    """
    if (home / "bin" / "grafana").is_file():
        return f"{GRAFANA_CURRENT_DIR}/bin/grafana server"
    if (home / "bin" / "grafana-server").is_file():
        return f"{GRAFANA_CURRENT_DIR}/bin/grafana-server"
    raise CLIError(f"No Grafana server binary found under {home}/bin")


def stage_grafana(source: Path, version: str) -> Path:
    """Put one Grafana release in place, through a staging directory.

    Grafana is a tree rather than a single binary, and reinstalling the running
    version would otherwise delete the files the running process still reads.
    The copy is checked under a staging name and only then renamed into place.
    """
    target = GRAFANA_VERSION_DIR / f"grafana-{version}"
    staging = GRAFANA_VERSION_DIR / f".grafana-{version}.new"
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(GRAFANA_HOME_DIR)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(GRAFANA_VERSION_DIR)])
    log_info(f"Installing Grafana release: {target}")
    safe_remove_path(staging)
    run_root(["cp", "-R", str(source), str(staging)])
    run_root(["chown", "-R", "root:root", str(staging)])
    binary = staging / "bin" / ("grafana" if (staging / "bin" / "grafana").is_file() else "grafana-server")
    verify_staged_version(binary, version, args=["--version"])
    safe_remove_path(target)
    run_root(["mv", "-Tf", str(staging), str(target)])
    return target


def kept_grafana_versions() -> list[Path]:
    if not GRAFANA_VERSION_DIR.is_dir():
        return []
    found = [path for path in GRAFANA_VERSION_DIR.iterdir()
             if path.is_dir() and not path.is_symlink() and re.match(r"^grafana-[0-9]+[.][0-9]+[.][0-9]+$", path.name)]
    return sorted(found, key=lambda path: path.stat().st_mtime, reverse=True)


def prune_grafana_versions(*, keep: int, current: Path) -> list[Path]:
    removed: list[Path] = []
    others = [path for path in kept_grafana_versions() if path != current]
    for path in others[max(keep - 1, 0):]:
        safe_remove_path(path)
        removed.append(path)
    return removed


def release_already_staged(component: Component, version: str) -> bool:
    """True when this exact release is already unpacked and runs.

    Re-running install is how a listen address, a retention or a Grafana setting
    is changed, and the Grafana tarball is around 450 MiB: downloading it again
    to rewrite one config file is a poor trade.
    """
    if component is GRAFANA:
        home = GRAFANA_VERSION_DIR / f"grafana-{version}"
        binary = home / "bin" / ("grafana" if (home / "bin" / "grafana").is_file() else "grafana-server")
        return binary.is_file() and binary_reported_version(binary) == version
    paths = [versioned_binary_path(BINARY_VERSION_DIR, name, version) for name in component.binaries]
    return all(path.is_file() for path in paths) and all(
        binary_reported_version(path) == version for path in paths)


def ensure_user(component: Component) -> None:
    if run(["id", component.user], check=False, capture=True).returncode == 0:
        return
    log_info(f"Creating system user: {component.user}")
    run_root(["useradd", "--system", "--home", str(ROOT_DIR), "--shell", "/bin/false", component.user])


def install_shared_directories() -> None:
    for path, mode in ((ROOT_DIR, "0755"), (BIN_DIR, "0755"), (ETC_DIR, "0755"),
                       (DATA_ROOT, "0755"), (SHARE_DIR, "0755"), (LOG_ROOT, "0755"),
                       (ROOT_DIR / "lib", "0755")):
        run_root(["install", "-d", "-m", mode, "-o", "root", "-g", "root", str(path)])


def node_exporter_flags(listen: str, enabled: list[str], disabled: list[str], extra: list[str]) -> list[str]:
    for name in [*enabled, *disabled]:
        if not re.match(r"^[a-z0-9_.-]+$", name):
            raise CLIError(f"Invalid collector name: {name}")
    for arg in extra:
        if not arg.startswith("--"):
            raise CLIError(f"Extra arguments must start with --: {arg}")
        validate_generated_value(arg, "extra argument")
    flags = [f"--web.listen-address={listen}"]
    flags.extend(f"--collector.{name}" for name in enabled)
    flags.extend(f"--no-collector.{name}" for name in disabled)
    flags.extend(extra)
    return flags


def exec_start_lines(command: str, flags: list[str]) -> str:
    if not flags:
        return f"ExecStart={command}"
    joined = " \\\n  ".join(flags)
    return f"ExecStart={command} \\\n  {joined}"


def render_node_exporter_unit(flags: list[str]) -> str:
    # ProtectHome is read-only rather than yes on purpose: hiding /home would make
    # node_filesystem_* stop reporting a separate /home mount.
    return managed_text(f"""[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User={NODE_EXPORTER.user}
Group={NODE_EXPORTER.user}
Type=simple
{exec_start_lines(str(binary_path('node_exporter')), flags)}
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target""")


def prometheus_flags(listen: str, retention: str, external_url: str, extra: list[str]) -> list[str]:
    for arg in extra:
        if not arg.startswith("--"):
            raise CLIError(f"Extra arguments must start with --: {arg}")
        validate_generated_value(arg, "extra argument")
    if external_url:
        validate_generated_value(external_url, "external URL")
    if not re.match(r"^[0-9]+[smhdwy]$", retention):
        raise CLIError(f"Invalid retention time (for example 15d): {retention}")
    flags = [
        f"--config.file={PROMETHEUS_CONFIG_FILE}",
        f"--storage.tsdb.path={PROMETHEUS_DATA_DIR}",
        f"--storage.tsdb.retention.time={retention}",
        f"--web.listen-address={listen}",
    ]
    if external_url:
        flags.append(f"--web.external-url={external_url}")
    flags.extend(extra)
    return flags


def render_prometheus_unit(flags: list[str]) -> str:
    return managed_text(f"""[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target
ConditionFileNotEmpty={PROMETHEUS_CONFIG_FILE}

[Service]
User={PROMETHEUS.user}
Group={PROMETHEUS.user}
Type=simple
{exec_start_lines(str(binary_path('prometheus')), flags)}
ExecReload=/bin/kill --signal HUP $MAINPID
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths={PROMETHEUS_DATA_DIR}

[Install]
WantedBy=multi-user.target""")


def render_grafana_unit(server_command: str) -> str:
    return managed_text(f"""[Unit]
Description=Grafana
Documentation=https://grafana.com/docs/grafana/latest/
Wants=network-online.target
After=network-online.target

[Service]
User={GRAFANA.user}
Group={GRAFANA.user}
Type=simple
WorkingDirectory={GRAFANA_CURRENT_DIR}
{exec_start_lines(server_command, [f'--homepath={GRAFANA_CURRENT_DIR}', f'--config={GRAFANA_CONFIG_FILE}', '--packaging=tarball'])}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths={GRAFANA_DATA_DIR} {GRAFANA_LOG_DIR}

[Install]
WantedBy=multi-user.target""")


def target_file(job: str) -> Path:
    return PROMETHEUS_TARGET_DIR / f"{validate_job(job)}.json"


def scrape_jobs() -> list[str]:
    """Job names, one per target file. Files named something else are ignored."""
    if not PROMETHEUS_TARGET_DIR.is_dir():
        return []
    return sorted(path.stem for path in PROMETHEUS_TARGET_DIR.glob("*.json")
                  if re.match(r"^[A-Za-z0-9_-]+$", path.stem))


def read_target_entries(job: str) -> list[dict[str, Any]]:
    """Targets recorded for one job.

    These files are JSON, so they cannot carry the managed marker the other files
    use. The shape is checked instead, and anything else is left alone rather
    than overwritten.
    """
    path = target_file(job)
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise CLIError(f"Cannot read the target file: {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CLIError(f"Target file is not valid JSON, refusing to rewrite it: {path}: {exc}") from exc
    if not isinstance(data, list) or not all(
        isinstance(item, dict) and isinstance(item.get("targets"), list) for item in data
    ):
        raise CLIError(f"Target file does not have the expected file_sd shape, "
                       f"refusing to rewrite it: {path}")
    return data


def write_target_entries(job: str, entries: list[dict[str, Any]]) -> None:
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(PROMETHEUS_TARGET_DIR)])
    install_text(target_file(job), json.dumps(entries, indent=2, sort_keys=True) + "\n", mode="0644")


def entry_addresses(entries: list[dict[str, Any]]) -> list[str]:
    return [address for entry in entries for address in entry.get("targets", [])]


def render_prometheus_config(listen: str, scrape_interval: str, jobs: list[str]) -> str:
    lines = [
        "# Regenerate with: " + f"{MONCTL_CMD} prometheus target add|remove",
        "# Scrape targets live in the JSON files under "
        f"{PROMETHEUS_TARGET_DIR}, which Prometheus re-reads on its own.",
        "",
        "global:",
        f"  scrape_interval:     {scrape_interval}",
        f"  evaluation_interval: {scrape_interval}",
        "",
        "scrape_configs:",
        "  - job_name: 'prometheus'",
        "    static_configs:",
        f"      - targets: ['{reachable_address(listen)}']",
    ]
    for job in jobs:
        lines.extend([
            "",
            f"  - job_name: '{job}'",
            "    file_sd_configs:",
            "      - files:",
            f"          - {target_file(job)}",
            f"        refresh_interval: {TARGET_REFRESH_INTERVAL}",
        ])
    return managed_text("\n".join(lines))


def check_prometheus_config() -> None:
    promtool = binary_path("promtool")
    if not promtool.exists():
        log_warn(f"promtool not found at {promtool}; skipping the config check")
        return
    result = run([str(promtool), "check", "config", str(PROMETHEUS_CONFIG_FILE)], check=False, capture=True)
    if result.returncode != 0:
        raise CLIError(f"promtool rejected the generated config:\n{(result.stdout or '') + (result.stderr or '')}")


def apply_prometheus_config(*, force: bool = False, reload_when_changed: bool = True) -> bool:
    """Regenerate prometheus.yml from the target files, rolling back a bad result.

    Returns True when the file changed. Adding or removing an address inside an
    existing job does not change this file at all, because file_sd is what holds
    the addresses and Prometheus re-reads those files by itself.
    """
    settings = prometheus_settings()
    require_managed_or_absent(PROMETHEUS_CONFIG_FILE, force)
    content = render_prometheus_config(settings["listen"], settings["scrape_interval"], scrape_jobs())
    previous = PROMETHEUS_CONFIG_FILE.read_text(encoding="utf-8") if PROMETHEUS_CONFIG_FILE.is_file() else ""
    if previous == content:
        return False
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(PROMETHEUS_CONFIG_DIR)])
    install_text(PROMETHEUS_CONFIG_FILE, content, mode="0644")
    try:
        check_prometheus_config()
    except CLIError:
        if previous:
            install_text(PROMETHEUS_CONFIG_FILE, previous, mode="0644")
        else:
            run_root(["rm", "-f", "--", str(PROMETHEUS_CONFIG_FILE)])
        raise
    log_success(f"Config written: {PROMETHEUS_CONFIG_FILE}")
    if reload_when_changed and previous and service_active(PROMETHEUS):
        log_info("Reloading Prometheus")
        reload_service(PROMETHEUS)
    return True


def render_grafana_config(addr: str, port: int, domain: str, root_url: str) -> str:
    body = f"""[server]
protocol  = http
http_addr = {addr}
http_port = {port}
domain    = {domain}
root_url  = {root_url}

[paths]
data         = {GRAFANA_DATA_DIR / 'data'}
logs         = {GRAFANA_LOG_DIR}
plugins      = {GRAFANA_DATA_DIR / 'plugins'}
provisioning = {GRAFANA_PROVISIONING_DIR}

[plugins]
# Grafana updates its bundled plugins on startup by rewriting them inside the
# release tree. That tree is root-owned here so a release stays exactly what was
# downloaded and a rollback is only a symlink switch, so the update fails halfway
# and leaves the plugin it was updating deregistered: with this on, the
# provisioned Prometheus datasource answers "Plugin not registered".
# Plugins now come from the release and change when the release changes.
preinstall_disabled = true

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode  = console file
level = info"""
    return managed_text(body)


def render_grafana_datasource(url: str) -> str:
    return managed_text(f"""apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: {url}
    isDefault: true
    editable: false""")


def read_install_metadata() -> dict[str, Any]:
    try:
        data = json.loads(INSTALL_METADATA_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_install_metadata_as_root() -> dict[str, Any]:
    result = run_root(["cat", str(INSTALL_METADATA_FILE)], capture=True, check=False)
    if result.returncode != 0:
        return {}
    try:
        data = json.loads(result.stdout or "")
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def component_records() -> dict[str, Any]:
    records = read_install_metadata().get("components")
    return records if isinstance(records, dict) else {}


def component_record(component: Component) -> dict[str, Any]:
    record = component_records().get(component.name)
    return record if isinstance(record, dict) else {}


def recorded_version(component: Component) -> str:
    version = component_record(component).get("version")
    return version.strip() if isinstance(version, str) and version.strip() else "unknown"


def installed_version(component: Component) -> str:
    """What this host actually runs, which upgrade trusts over the metadata."""
    if component is GRAFANA:
        current = linked_binary_path(GRAFANA_CURRENT_DIR)
        if current is not None:
            return current.name.removeprefix("grafana-")
        return ""
    entry = binary_path(component.binaries[0])
    if not entry.exists():
        return ""
    return binary_reported_version(entry)


def component_installed(component: Component) -> bool:
    if component is GRAFANA:
        return GRAFANA_CURRENT_DIR.is_symlink() or GRAFANA_CURRENT_DIR.is_dir()
    return binary_path(component.binaries[0]).exists()


def installed_components() -> list[Component]:
    return [COMPONENTS[name] for name in COMPONENT_NAMES if component_installed(COMPONENTS[name])]


def prometheus_settings() -> dict[str, Any]:
    record = component_record(PROMETHEUS)
    return {
        "listen": record.get("listen") or DEFAULT_PROMETHEUS_LISTEN,
        "retention": record.get("retention") or DEFAULT_PROMETHEUS_RETENTION,
        "scrape_interval": record.get("scrape_interval") or DEFAULT_SCRAPE_INTERVAL,
        "external_url": record.get("external_url") or "",
    }


def grafana_settings() -> dict[str, Any]:
    record = component_record(GRAFANA)
    return {
        "http_addr": record.get("http_addr") or DEFAULT_GRAFANA_ADDR,
        "http_port": int(record.get("http_port") or DEFAULT_GRAFANA_PORT),
        "domain": record.get("domain") or DEFAULT_GRAFANA_DOMAIN,
        "datasource_url": record.get("datasource_url") or "",
    }


def node_exporter_settings() -> dict[str, Any]:
    record = component_record(NODE_EXPORTER)
    return {"listen": record.get("listen") or DEFAULT_NODE_EXPORTER_LISTEN,
            "flags": record.get("flags") or []}


def source_tool_revision(script_dir: Path) -> tuple[str, bool]:
    """The git revision of the source tree the snapshot is taken from.

    Returns ("unknown", False) when git is unavailable or the source is not a
    checkout. Dirtiness is scoped to the tool directory, so unrelated edits
    elsewhere in the repository do not mark the snapshot as modified.
    """
    if not command_exists("git"):
        return "unknown", False
    revision = run(["git", "-C", str(script_dir), "rev-parse", "--short", "HEAD"], capture=True, check=False)
    if revision.returncode != 0:
        return "unknown", False
    # the pathspec is resolved relative to -C, so it must be "." and not script_dir
    status = run(["git", "-C", str(script_dir), "status", "--porcelain", "--", "."], capture=True, check=False)
    dirty = status.returncode == 0 and bool((status.stdout or "").strip())
    return (revision.stdout or "").strip() or "unknown", dirty


def read_installed_tool_revision() -> str:
    """Which source revision this host's copy was taken from.

    install.json is the record; the VERSION file is the fallback for a host whose
    metadata was removed or could not be parsed.
    """
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


def write_install_metadata(metadata: dict[str, Any]) -> None:
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_STATE_DIR)])
    install_text(INSTALL_METADATA_FILE, json.dumps(metadata, indent=2, sort_keys=True) + "\n", mode="0644")


def update_install_metadata(**changes: Any) -> dict[str, Any]:
    """Merge into install.json, keeping the records of the other components."""
    metadata = read_install_metadata() or read_install_metadata_as_root()
    metadata.setdefault("tool", "monctl")
    metadata["root_dir"] = str(ROOT_DIR)
    metadata["tool_dir"] = str(TOOL_DIR)
    metadata["manager_entry"] = str(TOOL_ENTRY)
    metadata["audit_log"] = str(AUDIT_LOG_FILE)
    components = metadata.get("components")
    metadata["components"] = components if isinstance(components, dict) else {}
    metadata.update(changes)
    write_install_metadata(metadata)
    return metadata


def record_component(component: Component, record: dict[str, Any]) -> None:
    metadata = read_install_metadata() or read_install_metadata_as_root()
    components = metadata.get("components")
    components = components if isinstance(components, dict) else {}
    existing = components.get(component.name)
    merged = dict(existing) if isinstance(existing, dict) else {}
    merged.update(record)
    merged["installed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    components[component.name] = merged
    update_install_metadata(components=components)


def forget_component(component: Component) -> None:
    metadata = read_install_metadata() or read_install_metadata_as_root()
    components = metadata.get("components")
    if not isinstance(components, dict) or component.name not in components:
        return
    components.pop(component.name, None)
    update_install_metadata(components=components)


def write_tool_manifest() -> None:
    path = TOOL_DIR / "monctl"
    lines = [f"{sha256_file(path)}  monctl"] if path.is_file() else []
    install_text(TOOL_MANIFEST_FILE, "\n".join(lines) + "\n", mode="0644")


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
    if not (script_dir / "monctl").is_file():
        missing.append(str(script_dir / "monctl"))
    if not (script_dir / "monitoring_tools").is_dir():
        missing.append(str(script_dir / "monitoring_tools"))
    if missing:
        raise CLIError(f"Tool source is incomplete: {', '.join(missing)}")


def install_tool_snapshot(script_dir: Path) -> None:
    """Copy this tool onto the node, so it can be managed without the source tree."""
    require_tool_source(script_dir)
    revision, dirty = source_tool_revision(script_dir)
    log_info(f"Installing the monctl snapshot: {TOOL_DIR} "
             f"(source revision {revision}{'-dirty' if dirty else ''})")
    install_shared_directories()
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_DIR)])
    run_root(["install", "-m", "0755", "-o", "root", "-g", "root",
              str(script_dir / "monctl"), str(TOOL_DIR / "monctl")])
    safe_remove_path(TOOL_DIR / "monitoring_tools")
    run_root(["cp", "-R", str(script_dir / "monitoring_tools"), str(TOOL_DIR / "monitoring_tools")])
    run_root(["chown", "-R", "root:root", str(TOOL_DIR / "monitoring_tools")])
    install_text(
        TOOL_VERSION_FILE,
        f"tool=monctl\ntool_revision={revision}\n"
        f"tool_revision_dirty={str(dirty).lower()}\n"
        f"installed_at={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\nsource_dir={script_dir}\n",
        mode="0644",
    )
    write_tool_manifest()
    run_root(["ln", "-sfn", str(TOOL_DIR / "monctl"), str(TOOL_PATH)])
    run_root(["install", "-d", "-m", "0755", "-o", "root", "-g", "root", str(TOOL_ENTRY.parent)])
    run_root(["ln", "-sfn", str(TOOL_PATH), str(TOOL_ENTRY)])
    update_install_metadata(tool_revision=revision, tool_revision_dirty=dirty,
                            manifest_file=str(TOOL_MANIFEST_FILE),
                            manifest_sha256=sha256_file(TOOL_MANIFEST_FILE) if TOOL_MANIFEST_FILE.is_file() else "")
    log_success(f"monctl entry installed: {TOOL_ENTRY}")


def maybe_install_tool_snapshot(install_tools: bool) -> None:
    if not install_tools:
        log_info(f"Skipping the tool snapshot; run {MONCTL_CMD} from this directory instead")
        return
    script_dir = current_script_dir(__file__).parent
    if running_from_installed_copy(script_dir):
        log_warn(f"Running the copy installed at {TOOL_DIR}; the tool files will not change")
        return
    install_tool_snapshot(script_dir)


def cmd_tools_update(_: argparse.Namespace) -> int:
    require_linux()
    require_command("install")
    script_dir = current_script_dir(__file__).parent
    if running_from_installed_copy(script_dir):
        raise CLIError(
            f"Refusing to update from the installed copy at {TOOL_DIR}: it would copy onto itself "
            f"and change nothing. Run tools update from a source checkout instead"
        )
    log_info(f"Updating the monctl files from: {script_dir}")
    install_tool_snapshot(script_dir)
    log_success("monctl updated")
    return 0


def require_install_environment() -> None:
    require_linux()
    for command in ("install", "systemctl", "useradd"):
        require_command(command)


def probe_endpoint(url: str, *, attempts: int = 15, delay: float = 1.0) -> int:
    """Poll a health endpoint after a restart, returning the last HTTP status."""
    code = 0
    for _ in range(attempts):
        code = http_status(url, timeout=3)
        if code == 200:
            return code
        time.sleep(delay)
    return code


def report_endpoint(label: str, url: str) -> None:
    code = probe_endpoint(url)
    if code == 200:
        log_success(f"{label} responds: {url}")
    else:
        log_warn(f"{label} did not respond with 200: {url} ({code or 'no answer'})")


def warn_on_public_listen(component: Component, listen: str, note: str) -> None:
    if listen_host(listen) in LOCAL_ADDRESSES:
        return
    log_warn(f"{component.name} listens on {listen}, reachable from other hosts. {note}")


def cmd_node_exporter_install(args: argparse.Namespace) -> int:
    require_install_environment()
    require_no_legacy_install(NODE_EXPORTER, args.force)
    listen = validate_listen(args.listen, "listen address")
    flags = node_exporter_flags(listen, args.enable_collector, args.disable_collector, args.extra_arg)
    unit = service_file(NODE_EXPORTER)
    require_managed_or_absent(unit, args.force)
    version = resolve_version(NODE_EXPORTER, args.version)
    install_shared_directories()
    ensure_user(NODE_EXPORTER)
    if release_already_staged(NODE_EXPORTER, version):
        log_info(f"node_exporter {version} is already unpacked; reusing it instead of downloading")
    else:
        tmpdir = create_install_tmpdir("node-exporter-install")
        try:
            source = download_prometheus_release(NODE_EXPORTER, version, detect_arch(), tmpdir)
            stage_binaries(NODE_EXPORTER, source, version)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    switch_binaries(NODE_EXPORTER, version)
    log_info(f"Installing systemd service: {unit}")
    install_text(unit, render_node_exporter_unit(flags), mode="0644")
    enable_service(NODE_EXPORTER)
    record_component(NODE_EXPORTER, {"version": version, "listen": listen, "flags": flags})
    maybe_install_tool_snapshot(args.install_tools)
    report_endpoint("node_exporter", f"http://{reachable_address(listen)}/metrics")
    warn_on_public_listen(NODE_EXPORTER, listen,
                          "It has no authentication, so restrict the port to the Prometheus host.")
    log_success(f"node_exporter {version} installed")
    print("\nNext steps:")
    print(f"  On the Prometheus host: {MONCTL_CMD} prometheus target add --address <this-host>:"
          f"{listen_port(listen)}")
    print(f"  {MONCTL_CMD} doctor")
    return 0


def reclaim_data_dir(path: Path, user: str) -> None:
    """Hand a kept data directory to the service user again.

    uninstall removes the system user but keeps the data, so the files are left
    owned by a uid nobody holds. The next install creates the user from scratch
    and there is no promise it gets the same uid back, which would leave
    Prometheus or Grafana unable to write to data that looks like it is theirs.
    Only the top directory is checked, because uninstall never chowns anything:
    if it still carries the old uid, so does everything under it.
    """
    if not path.is_dir():
        return
    try:
        target_uid = pwd.getpwnam(user).pw_uid
    except KeyError:
        return
    if path.stat().st_uid == target_uid:
        return
    log_info(f"Taking ownership of the data kept from an earlier install: {path}")
    run_root(["chown", "-R", f"{user}:{user}", str(path)])


def ensure_prometheus_directories() -> None:
    """Create the Prometheus directories. The service user must already exist."""
    install_shared_directories()
    reclaim_data_dir(PROMETHEUS_DATA_DIR, PROMETHEUS.user)
    for path, mode, owner in ((PROMETHEUS_CONFIG_DIR, "0755", "root"),
                              (PROMETHEUS_TARGET_DIR, "0755", "root"),
                              (PROMETHEUS_DATA_DIR, "0750", PROMETHEUS.user)):
        run_root(["install", "-d", "-m", mode, "-o", owner, "-g", owner, str(path)])


def add_target_entry(job: str, address: str, labels: dict[str, str]) -> bool:
    """Record one scrape target. Returns True when the file changed."""
    entries = read_target_entries(job)
    for entry in entries:
        if address in entry.get("targets", []):
            if labels and entry.get("labels", {}) != labels:
                entry["labels"] = labels
                write_target_entries(job, entries)
                log_success(f"Updated labels for {address} in job {job}")
                return True
            log_info(f"Target already present in job {job}: {address}")
            return False
    created: dict[str, Any] = {"targets": [address]}
    if labels:
        created["labels"] = labels
    entries.append(created)
    write_target_entries(job, entries)
    log_success(f"Added target to job {job}: {address}")
    return True


def cmd_prometheus_install(args: argparse.Namespace) -> int:
    require_install_environment()
    require_no_legacy_install(PROMETHEUS, args.force)
    listen = validate_listen(args.listen, "listen address")
    job = validate_job(args.job)
    flags = prometheus_flags(listen, args.retention, args.external_url, args.extra_arg)
    unit = service_file(PROMETHEUS)
    require_managed_or_absent(unit, args.force)
    require_managed_or_absent(PROMETHEUS_CONFIG_FILE, args.force)
    version = resolve_version(PROMETHEUS, args.version)
    ensure_user(PROMETHEUS)
    ensure_prometheus_directories()
    if release_already_staged(PROMETHEUS, version):
        log_info(f"Prometheus {version} is already unpacked; reusing it instead of downloading")
    else:
        tmpdir = create_install_tmpdir("prometheus-install")
        try:
            source = download_prometheus_release(PROMETHEUS, version, detect_arch(), tmpdir)
            stage_binaries(PROMETHEUS, source, version)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    switch_binaries(PROMETHEUS, version)
    record_component(PROMETHEUS, {"version": version, "listen": listen, "retention": args.retention,
                                  "scrape_interval": args.scrape_interval,
                                  "external_url": args.external_url, "flags": flags})
    if not target_file(job).is_file():
        # an empty job now means later target changes touch only the JSON file,
        # which Prometheus re-reads without a reload
        write_target_entries(job, [])
    apply_prometheus_config(force=args.force, reload_when_changed=False)
    log_info(f"Installing systemd service: {unit}")
    install_text(unit, render_prometheus_unit(flags), mode="0644")
    enable_service(PROMETHEUS)
    if args.scrape_local_node and component_installed(NODE_EXPORTER):
        local = reachable_address(node_exporter_settings()["listen"])
        log_info(f"Adding the node_exporter on this host to job {job}")
        add_target_entry(job, local, {})
    maybe_install_tool_snapshot(args.install_tools)
    report_endpoint("Prometheus", f"http://{reachable_address(listen)}/-/healthy")
    warn_on_public_listen(PROMETHEUS, listen,
                          "Prometheus has no authentication of its own; put it behind a firewall or proxy.")
    log_success(f"Prometheus {version} installed")
    print("\nNext steps:")
    print(f"  {MONCTL_CMD} prometheus target add --address <host>:9100")
    print(f"  {MONCTL_CMD} grafana install")
    print(f"  {MONCTL_CMD} doctor")
    return 0


def ensure_grafana_directories() -> None:
    """Create the Grafana directories. The service user must already exist."""
    install_shared_directories()
    for path in (GRAFANA_DATA_DIR, GRAFANA_LOG_DIR):
        reclaim_data_dir(path, GRAFANA.user)
    for path, mode, owner in ((GRAFANA_CONFIG_DIR, "0755", "root"),
                              (GRAFANA_PROVISIONING_DIR, "0755", "root"),
                              *((GRAFANA_PROVISIONING_DIR / name, "0755", "root")
                                for name in GRAFANA_PROVISIONING_SUBDIRS),
                              (GRAFANA_DATA_DIR, "0750", GRAFANA.user),
                              (GRAFANA_DATA_DIR / "data", "0750", GRAFANA.user),
                              (GRAFANA_DATA_DIR / "plugins", "0750", GRAFANA.user),
                              (GRAFANA_LOG_DIR, "0750", GRAFANA.user)):
        run_root(["install", "-d", "-m", mode, "-o", owner, "-g", owner, str(path)])


def resolve_datasource_url(requested: str, enabled: bool) -> str:
    if not enabled:
        return ""
    if requested:
        return requested
    if component_installed(PROMETHEUS):
        return f"http://{reachable_address(prometheus_settings()['listen'])}"
    return ""


def cmd_grafana_install(args: argparse.Namespace) -> int:
    require_install_environment()
    require_no_legacy_install(GRAFANA, args.force)
    if not 1 <= args.port <= 65535:
        raise CLIError(f"Invalid port: {args.port}")
    validate_generated_value(args.listen_addr, "listen address")
    validate_generated_value(args.domain, "domain")
    if args.root_url:
        validate_generated_value(args.root_url, "root URL")
    if args.prometheus_url:
        validate_generated_value(args.prometheus_url, "Prometheus URL")
    unit = service_file(GRAFANA)
    require_managed_or_absent(unit, args.force)
    require_managed_or_absent(GRAFANA_CONFIG_FILE, args.force)
    datasource_url = resolve_datasource_url(args.prometheus_url, args.datasource)
    version = resolve_version(GRAFANA, args.version)
    ensure_user(GRAFANA)
    ensure_grafana_directories()
    if release_already_staged(GRAFANA, version):
        log_info(f"Grafana {version} is already unpacked; reusing it instead of downloading 450 MiB")
        staged = GRAFANA_VERSION_DIR / f"grafana-{version}"
    else:
        tmpdir = create_install_tmpdir("grafana-install")
        try:
            staged = stage_grafana(download_grafana_release(version, detect_arch(), tmpdir), version)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    server_command = grafana_server_command(staged)
    atomic_symlink(staged, GRAFANA_CURRENT_DIR)
    root_url = args.root_url or f"http://{args.domain}:{args.port}/"
    log_info(f"Installing Grafana config: {GRAFANA_CONFIG_FILE}")
    install_text(GRAFANA_CONFIG_FILE, render_grafana_config(args.listen_addr, args.port, args.domain, root_url),
                 mode="0644")
    if datasource_url:
        require_managed_or_absent(GRAFANA_DATASOURCE_FILE, args.force)
        log_info(f"Provisioning the Prometheus datasource: {datasource_url}")
        install_text(GRAFANA_DATASOURCE_FILE, render_grafana_datasource(datasource_url), mode="0644")
    elif args.datasource:
        log_warn("No Prometheus found on this host and no --prometheus-url given; "
                 "add the datasource in the Grafana UI")
    log_info(f"Installing systemd service: {unit}")
    install_text(unit, render_grafana_unit(server_command), mode="0644")
    enable_service(GRAFANA)
    record_component(GRAFANA, {"version": version, "http_addr": args.listen_addr, "http_port": args.port,
                               "domain": args.domain, "root_url": root_url, "datasource_url": datasource_url})
    maybe_install_tool_snapshot(args.install_tools)
    listen = f"{args.listen_addr}:{args.port}"
    report_endpoint("Grafana", f"http://{reachable_address(listen)}/api/health")
    log_success(f"Grafana {version} installed")
    print("\nNext steps:")
    print(f"  Open {root_url} and sign in as admin / admin, then change that password.")
    if not datasource_url:
        print("  Add a Prometheus datasource in Connections -> Data sources.")
    print("  Import a dashboard, because Grafana ships none for these metrics and the")
    print("  home page stays empty until you do:")
    print(f"    {dashboard_hint('    ')}")
    print(f"  {MONCTL_CMD} doctor")
    return 0


def require_component_installed(component: Component) -> None:
    if not component_installed(component):
        raise CLIError(f"{component.name} is not installed on this host; "
                       f"run {MONCTL_CMD} {component.name} install first")


def prometheus_api(path: str) -> Any:
    """Query the local Prometheus API, returning None when it cannot be reached."""
    url = f"http://{reachable_address(prometheus_settings()['listen'])}{path}"
    try:
        body = fetch_url(url, timeout=5, no_proxy=True)
        return json.loads(body.decode("utf-8", errors="replace"))
    except Exception:
        return None


def active_target_health() -> dict[tuple[str, str], dict[str, str]]:
    """(job, address) -> health and last error, as Prometheus currently sees it.

    Keyed on the discovered labels rather than the final ones: `__address__` and
    `job` there are literally what the target file holds, while the final
    `instance` label is whatever relabeling made of it — and a target carrying a
    custom instance label would otherwise never match the address it was added
    with.
    """
    data = prometheus_api("/api/v1/targets?state=any")
    result: dict[tuple[str, str], dict[str, str]] = {}
    if not isinstance(data, dict):
        return result
    payload = data.get("data")
    targets = payload.get("activeTargets") if isinstance(payload, dict) else None
    if not isinstance(targets, list):
        return result
    for item in targets:
        if not isinstance(item, dict):
            continue
        labels = item.get("labels") if isinstance(item.get("labels"), dict) else {}
        discovered = item.get("discoveredLabels") if isinstance(item.get("discoveredLabels"), dict) else {}
        address = discovered.get("__address__") or labels.get("instance", "")
        job = discovered.get("job") or item.get("scrapePool") or labels.get("job", "")
        result[(str(job), str(address))] = {"health": str(item.get("health", "unknown")),
                                            "error": str(item.get("lastError", ""))}
    return result


def cmd_prometheus_target_add(args: argparse.Namespace) -> int:
    require_component_installed(PROMETHEUS)
    job = validate_job(args.job)
    address = validate_target(args.address)
    labels = dict(parse_label(item) for item in args.label)
    new_job = not target_file(job).is_file()
    changed = add_target_entry(job, address, labels)
    if new_job:
        log_info(f"Job {job} is new, so prometheus.yml has to point at its target file")
        try:
            apply_prometheus_config()
        except CLIError:
            # the file exists only because of this command and prometheus.yml was
            # never updated to reference it, so leaving it behind would show a job
            # in target list that Prometheus does not scrape
            log_warn(f"Removing the target file this command created: {target_file(job)}")
            run_root(["rm", "-f", "--", str(target_file(job))])
            raise
    elif changed:
        log_info("Prometheus re-reads the target file by itself; no restart or reload needed")
    return 0


def cmd_prometheus_target_remove(args: argparse.Namespace) -> int:
    require_component_installed(PROMETHEUS)
    address = validate_target(args.address)
    jobs = [validate_job(args.job)] if args.job else scrape_jobs()
    removed_from: list[str] = []
    for job in jobs:
        entries = read_target_entries(job)
        kept: list[dict[str, Any]] = []
        changed = False
        for entry in entries:
            original = entry.get("targets", [])
            targets = [item for item in original if item != address]
            if targets == original:
                kept.append(entry)
                continue
            changed = True
            # an entry that held only this address goes away with it; one that
            # carried several keeps the rest, along with its labels
            if targets:
                entry["targets"] = targets
                kept.append(entry)
        if changed:
            write_target_entries(job, kept)
            removed_from.append(job)
    if not removed_from:
        log_warn(f"Target not found: {address}")
        return 1
    log_success(f"Removed {address} from job(s): {', '.join(removed_from)}")
    log_info("The job itself is kept, so its target file stays in place even when empty")
    return 0


def cmd_prometheus_target_list(_: argparse.Namespace) -> int:
    jobs = scrape_jobs()
    if not jobs:
        print(f"No scrape jobs configured under {PROMETHEUS_TARGET_DIR}")
        return 0
    health = active_target_health()
    print(f"{'JOB':<16} {'ADDRESS':<28} {'HEALTH':<8} LABELS")
    for job in jobs:
        try:
            entries = read_target_entries(job)
        except CLIError as exc:
            print(f"{job:<16} {'<unreadable>':<28} {'-':<8} {exc}")
            continue
        if not entries:
            print(f"{job:<16} {'<no targets>':<28} {'-':<8}")
            continue
        for entry in entries:
            labels = entry.get("labels") or {}
            rendered = ",".join(f"{key}={value}" for key, value in sorted(labels.items())) or "-"
            for address in entry.get("targets", []):
                state = health.get((job, address), {}).get("health", "-")
                print(f"{job:<16} {address:<28} {state:<8} {rendered}")
    return 0


def cmd_prometheus_reload(_: argparse.Namespace) -> int:
    require_component_installed(PROMETHEUS)
    check_prometheus_config()
    log_success(f"Config is valid: {PROMETHEUS_CONFIG_FILE}")
    if not service_active(PROMETHEUS):
        log_warn("prometheus.service is not active; nothing to reload")
        return 0
    reload_service(PROMETHEUS)
    log_success("Prometheus reloaded")
    return 0


def upgrade_plan_lines(component: Component, current: str, target: str, keep: int) -> list[str]:
    if component is GRAFANA:
        artifact = [f"  Download:         https://dl.grafana.com/oss/release/grafana-{target}.linux-"
                    f"{grafana_arch(detect_arch())}.tar.gz",
                    f"  Install release:  {GRAFANA_VERSION_DIR / ('grafana-' + target)}",
                    f"  Switch symlink:   {GRAFANA_CURRENT_DIR}"]
        untouched = "  Left untouched:   grafana.ini, the Grafana database, dashboards and plugins"
    else:
        artifact = [f"  Download:         https://github.com/{component.repo}/releases/download/v{target}/"
                    f"{component.service}-{target}.linux-{detect_arch()}.tar.gz",
                    "  Install release:  " + ", ".join(
                        str(versioned_binary_path(BINARY_VERSION_DIR, name, target)) for name in component.binaries),
                    "  Switch symlink:   " + ", ".join(str(binary_path(name)) for name in component.binaries)]
        untouched = ("  Left untouched:   prometheus.yml, the scrape targets, the TSDB and the tool files"
                     if component is PROMETHEUS else
                     "  Left untouched:   the unit flags and the tool files")
    lines = [
        f"{component.name} upgrade plan:",
        f"  Current version:  {current}",
        f"  Target version:   {target}",
        *artifact,
        f"  Restart service:  {component.service}.service",
        f"  Keep releases:    {keep} (older ones are removed once the new one is running)",
        untouched,
        "",
        f"  {component.service}.service is restarted, so it stops answering for a moment.",
        "  A restart that fails is rolled back to the current release.",
    ]
    if version_tuple(target) < version_tuple(current):
        lines.extend([
            "",
            f"  Downgrade: {current} may have written data that {target} cannot read,",
            "  so the older release can fail to start even though the binary is restored.",
        ])
    return lines


def confirm_action(prompt: str, assume_yes: bool, cancelled: str) -> None:
    if assume_yes:
        return
    try:
        answer = input(prompt)
    except EOFError as exc:
        raise CLIError(f"{cancelled} requires confirmation. Re-run with --yes for non-interactive use") from exc
    if answer != "yes":
        raise CLIError(f"{cancelled} cancelled")


def switch_grafana_release(home: Path) -> None:
    """Point current at a release and rewrite the unit, which names the server binary."""
    atomic_symlink(home, GRAFANA_CURRENT_DIR)
    install_text(service_file(GRAFANA), render_grafana_unit(grafana_server_command(home)), mode="0644")
    run_root(["systemctl", "daemon-reload"])


def cmd_component_upgrade(component: Component, args: argparse.Namespace) -> int:
    require_linux()
    for command in ("install", "systemctl"):
        require_command(command)
    if args.keep < 1:
        raise CLIError("--keep must be at least 1")
    require_component_installed(component)
    current = installed_version(component) or recorded_version(component)
    if not current or current == "unknown":
        raise CLIError(f"Cannot determine the installed {component.name} version on this host")
    target = resolve_upgrade_target(component, args.version)
    if target == current:
        log_success(f"{component.name} {current} is already installed; nothing to upgrade")
        if recorded_version(component) != current:
            log_info(f"Recording the installed version over {recorded_version(component)}")
            record_component(component, {"version": current})
        return 0
    if version_tuple(target) < version_tuple(current) and not args.allow_downgrade:
        raise CLIError(f"Refusing to downgrade {component.name} {current} to {target}; "
                       f"re-run with --allow-downgrade")
    print("\n".join(upgrade_plan_lines(component, current, target, args.keep)))
    if args.dry_run:
        return 0
    confirm_action(f"Proceed with the {component.name} upgrade? Type yes to continue: ", args.yes, "Upgrade")
    arch = detect_arch()
    tmpdir = create_install_tmpdir(f"{component.name}-upgrade")
    try:
        if component is GRAFANA:
            previous: Path | None = linked_binary_path(GRAFANA_CURRENT_DIR)
            if previous is None:
                raise CLIError(f"{GRAFANA_CURRENT_DIR} is not a symlink, so this upgrade cannot roll back. "
                               f"Reinstall with {MONCTL_CMD} grafana install")
            staged = stage_grafana(download_grafana_release(target, arch, tmpdir), target)
            switch_grafana_release(staged)
        else:
            previous = linked_binary_path(binary_path(component.binaries[0]))
            if previous is None:
                log_info(f"Moving the installed binaries into {BINARY_VERSION_DIR}")
                for name in component.binaries:
                    adopt_versioned_binary_layout(binary_path(name), BINARY_VERSION_DIR, name, current)
            source = download_prometheus_release(component, target, arch, tmpdir)
            staged = stage_binaries(component, source, target)[0]
            log_info(f"Switching {component.name} to {target}")
            switch_binaries(component, target)
        try:
            log_info(f"Restarting {component.service}.service on the new release")
            restart_service(component)
        except (CLIError, subprocess.CalledProcessError) as exc:
            log_error(f"{component.name} did not come back on {target}: {exc}")
            log_warn(f"Rolling back to {current}")
            if component is GRAFANA:
                switch_grafana_release(GRAFANA_VERSION_DIR / f"grafana-{current}")
            else:
                switch_binaries(component, current)
            try:
                restart_service(component)
            except (CLIError, subprocess.CalledProcessError) as rollback_error:
                raise CLIError(f"Upgrade to {target} failed and the rollback to {current} also failed: "
                               f"{rollback_error}") from exc
            raise CLIError(f"Upgrade to {target} failed and was rolled back to {current}") from exc
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    record_component(component, {"version": target, "previous_version": current,
                                 "upgraded_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
    if component is GRAFANA:
        removed = prune_grafana_versions(keep=args.keep, current=staged)
    else:
        removed = [path for name in component.binaries
                   for path in prune_binary_versions(BINARY_VERSION_DIR, name, keep=args.keep,
                                                     current=versioned_binary_path(BINARY_VERSION_DIR, name, target))]
    for path in removed:
        log_info(f"Removed old release: {path}")
    log_success(f"{component.name} upgraded: {current} -> {target}")
    print(f"\nVerify with: {MONCTL_CMD} doctor --component {component.name}")
    return 0


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


def doctor_service(component: Component) -> int:
    """Unit file, unit ownership and whether the service is running."""
    failures = 0
    unit = service_file(component)
    if not unit.is_file():
        doctor_check("FAIL", f"systemd unit missing: {unit}")
        return failures + 1
    if is_managed_file(unit):
        doctor_check("OK", f"systemd unit managed: {unit}")
    else:
        doctor_check("WARN", f"systemd unit exists but was not written by this tool: {unit}")
    state = service_state(component)
    if state == "active":
        doctor_check("OK", f"{component.service}.service is active")
    else:
        doctor_check("FAIL", f"{component.service}.service is {state}")
        failures += 1
    return failures


def doctor_version(component: Component) -> None:
    recorded = recorded_version(component)
    actual = installed_version(component)
    doctor_info(f"recorded version = {recorded}")
    if actual:
        doctor_info(f"running version  = {actual}")
        if recorded not in {"unknown", actual}:
            doctor_check("WARN", f"Running version {actual} differs from the recorded {recorded}; "
                                 f"run {MONCTL_CMD} {component.name} upgrade "
                                 f"to install a known release")


def doctor_node_exporter() -> int:
    failures = 0
    entry = binary_path("node_exporter")
    if entry.exists():
        doctor_check("OK", f"Binary found: {entry}")
    else:
        doctor_check("FAIL", f"Binary missing: {entry}")
        failures += 1
    doctor_version(NODE_EXPORTER)
    failures += doctor_service(NODE_EXPORTER)
    listen = node_exporter_settings()["listen"]
    doctor_info(f"listen           = {listen}")
    url = f"http://{reachable_address(listen)}/metrics"
    code = http_status(url, timeout=3)
    if code == 200:
        doctor_check("OK", f"Metrics endpoint answers: {url}")
    else:
        doctor_check("FAIL", f"Metrics endpoint does not answer: {url} ({code or 'no answer'})")
        failures += 1
    if listen_host(listen) not in LOCAL_ADDRESSES:
        doctor_check("WARN", f"Port {listen_port(listen)} is open to other hosts and needs no credentials; "
                             f"anyone reaching it reads this host's metrics")
    return failures


def doctor_prometheus_targets() -> int:
    """Down targets are the failure everyone actually hits, so name them."""
    jobs = scrape_jobs()
    if not jobs:
        doctor_check("WARN", f"No scrape jobs configured under {PROMETHEUS_TARGET_DIR}")
        return 0
    configured: dict[str, list[str]] = {}
    failures = 0
    for job in jobs:
        try:
            configured[job] = entry_addresses(read_target_entries(job))
        except CLIError as exc:
            doctor_check("FAIL", str(exc))
            failures += 1
    total = sum(len(addresses) for addresses in configured.values())
    doctor_info(f"scrape jobs      = {', '.join(jobs)} ({total} target(s))")
    if total == 0 and not failures:
        doctor_check("WARN", f"No scrape targets configured; add one with "
                             f"{MONCTL_CMD} prometheus target add --address <host>:9100")
        return failures
    health = active_target_health()
    if not health:
        doctor_check("WARN", "Prometheus did not report its targets; skipping the per-target check")
        return failures
    for job, addresses in configured.items():
        for address in addresses:
            state = health.get((job, address))
            if state is None:
                doctor_check("WARN", f"Target not picked up yet by Prometheus: {job} {address}")
                continue
            if state["health"] == "up":
                doctor_check("OK", f"Target up: {job} {address}")
            else:
                doctor_check("FAIL", f"Target {state['health']}: {job} {address}"
                                     + (f" ({state['error']})" if state["error"] else ""))
                failures += 1
    return failures


def doctor_prometheus() -> int:
    failures = 0
    for name in PROMETHEUS.binaries:
        entry = binary_path(name)
        if entry.exists():
            doctor_check("OK", f"Binary found: {entry}")
        else:
            doctor_check("FAIL", f"Binary missing: {entry}")
            failures += 1
    doctor_version(PROMETHEUS)
    if is_managed_file(PROMETHEUS_CONFIG_FILE):
        doctor_check("OK", f"Config managed: {PROMETHEUS_CONFIG_FILE}")
    elif PROMETHEUS_CONFIG_FILE.is_file():
        doctor_check("WARN", f"Config exists but was not written by this tool: {PROMETHEUS_CONFIG_FILE}")
    else:
        doctor_check("FAIL", f"Config missing: {PROMETHEUS_CONFIG_FILE}")
        failures += 1
    if binary_path("promtool").exists():
        try:
            check_prometheus_config()
            doctor_check("OK", f"promtool accepts the config: {PROMETHEUS_CONFIG_FILE}")
        except CLIError as exc:
            doctor_check("FAIL", str(exc).splitlines()[0])
            failures += 1
    if PROMETHEUS_DATA_DIR.is_dir():
        doctor_check("OK", f"Data directory exists: {PROMETHEUS_DATA_DIR}")
    else:
        doctor_check("FAIL", f"Data directory missing: {PROMETHEUS_DATA_DIR}")
        failures += 1
    failures += doctor_service(PROMETHEUS)
    settings = prometheus_settings()
    doctor_info(f"listen           = {settings['listen']}")
    doctor_info(f"retention        = {settings['retention']}")
    url = f"http://{reachable_address(settings['listen'])}/-/healthy"
    code = http_status(url, timeout=3)
    if code == 200:
        doctor_check("OK", f"Prometheus answers: {url}")
    else:
        doctor_check("FAIL", f"Prometheus does not answer: {url} ({code or 'no answer'})")
        failures += 1
    failures += doctor_prometheus_targets()
    return failures


def doctor_grafana() -> int:
    failures = 0
    if GRAFANA_CURRENT_DIR.is_symlink():
        doctor_check("OK", f"Release linked: {GRAFANA_CURRENT_DIR} -> {os.readlink(GRAFANA_CURRENT_DIR)}")
    elif GRAFANA_CURRENT_DIR.is_dir():
        doctor_check("WARN", f"{GRAFANA_CURRENT_DIR} is a directory, not a symlink; upgrade cannot roll back")
    else:
        doctor_check("FAIL", f"Grafana release missing: {GRAFANA_CURRENT_DIR}")
        failures += 1
    doctor_version(GRAFANA)
    if is_managed_file(GRAFANA_CONFIG_FILE):
        doctor_check("OK", f"Config managed: {GRAFANA_CONFIG_FILE}")
    elif GRAFANA_CONFIG_FILE.is_file():
        doctor_check("WARN", f"Config exists but was not written by this tool: {GRAFANA_CONFIG_FILE}")
    else:
        doctor_check("FAIL", f"Config missing: {GRAFANA_CONFIG_FILE}")
        failures += 1
    failures += doctor_service(GRAFANA)
    settings = grafana_settings()
    listen = f"{settings['http_addr']}:{settings['http_port']}"
    doctor_info(f"listen           = {listen}")
    url = f"http://{reachable_address(listen)}/api/health"
    code = http_status(url, timeout=3)
    if code == 200:
        doctor_check("OK", f"Grafana answers: {url}")
    else:
        doctor_check("FAIL", f"Grafana does not answer: {url} ({code or 'no answer'})")
        failures += 1
    if GRAFANA_DATASOURCE_FILE.is_file():
        doctor_info(f"datasource       = {settings['datasource_url'] or GRAFANA_DATASOURCE_FILE}")
        if settings["datasource_url"]:
            probe = http_status(f"{settings['datasource_url'].rstrip('/')}/-/healthy", timeout=3)
            if probe == 200:
                doctor_check("OK", f"Provisioned datasource reachable: {settings['datasource_url']}")
            else:
                doctor_check("WARN", f"Provisioned datasource does not answer: "
                                     f"{settings['datasource_url']} ({probe or 'no answer'})")
    else:
        doctor_check("WARN", "No provisioned Prometheus datasource; add one in the Grafana UI")
    return failures


DOCTOR_CHECKS = {
    NODE_EXPORTER.name: doctor_node_exporter,
    PROMETHEUS.name: doctor_prometheus,
    GRAFANA.name: doctor_grafana,
}


def selected_components(name: str) -> list[Component]:
    if name in {"", "all"}:
        return [COMPONENTS[key] for key in COMPONENT_NAMES]
    return [component_by_name(name)]


def cmd_doctor(args: argparse.Namespace) -> int:
    failures = 0
    doctor_check("OK" if sys.platform.startswith("linux") else "FAIL", f"platform: {sys.platform}")
    if not sys.platform.startswith("linux"):
        failures += 1
    if systemd_available():
        doctor_check("OK", f"systemctl found: {shutil.which('systemctl')}")
    else:
        doctor_check("FAIL", "systemctl not found")
        failures += 1
    wanted = selected_components(args.component)
    present = [component for component in wanted if component_installed(component)]
    for component in wanted:
        if component in present:
            continue
        doctor_info(f"{component.name}: not installed on this host")
    if not installed_components():
        doctor_check("WARN", f"No managed component found under {ROOT_DIR}; "
                             f"run {MONCTL_CMD} quickstart to see the setup order")
    for component in present:
        print(f"\n{component.name}:")
        failures += DOCTOR_CHECKS[component.name]()
    print("\nNode runtime:")
    if TOOL_DIR.is_dir():
        doctor_check("OK", f"Tool copy present: {TOOL_DIR}")
        doctor_info(f"tool revision    = {read_installed_tool_revision()}")
    else:
        doctor_check("WARN", f"Tool copy missing: {TOOL_DIR}; this host runs {MONCTL_CMD} "
                             f"from a source checkout only")
    legacy = legacy_install_paths()
    if legacy:
        doctor_check("WARN", "Unmanaged monitoring files from an older install are still on this host:")
        for path in legacy:
            doctor_check("INFO", f"  {path}")
    if failures == 0:
        print("\nAll checks passed.")
    return 0 if failures == 0 else 1


def status_line(key: str, value: str) -> None:
    print(f"  {key:<20} {value}")


def status_component(component: Component) -> None:
    print(f"\n{component.name}:")
    if not component_installed(component):
        status_line("state", "<not installed>")
        return
    status_line("recorded version", recorded_version(component))
    status_line("running version", installed_version(component) or "unknown")
    status_line("service", service_state(component))
    status_line("unit", str(service_file(component)))
    if component is GRAFANA:
        current = linked_binary_path(GRAFANA_CURRENT_DIR)
        status_line("release", str(current) if current else str(GRAFANA_CURRENT_DIR))
        kept = [path.name for path in kept_grafana_versions()]
        if kept:
            status_line("kept releases", ", ".join(kept))
        settings = grafana_settings()
        status_line("listen", f"{settings['http_addr']}:{settings['http_port']}")
        status_line("config", str(GRAFANA_CONFIG_FILE))
        status_line("data dir", str(GRAFANA_DATA_DIR))
        status_line("datasource", settings["datasource_url"] or "<none provisioned>")
        return
    status_line("binaries", ", ".join(str(binary_path(name)) for name in component.binaries))
    kept = [path.name for name in component.binaries
            for path in kept_binary_versions(BINARY_VERSION_DIR, name)]
    if kept:
        status_line("kept releases", ", ".join(kept))
    if component is NODE_EXPORTER:
        status_line("listen", node_exporter_settings()["listen"])
        return
    settings = prometheus_settings()
    status_line("listen", settings["listen"])
    status_line("retention", settings["retention"])
    status_line("scrape interval", settings["scrape_interval"])
    status_line("config", str(PROMETHEUS_CONFIG_FILE))
    status_line("data dir", str(PROMETHEUS_DATA_DIR))
    jobs = scrape_jobs()
    try:
        total: int | str = sum(len(entry_addresses(read_target_entries(job))) for job in jobs)
    except CLIError:
        total = "unreadable"
    status_line("scrape jobs", f"{', '.join(jobs) or '<none>'} ({total} target(s))")


def cmd_status(args: argparse.Namespace) -> int:
    """Show what is configured. doctor answers whether it is healthy."""
    print("Install:")
    status_line("root dir", str(ROOT_DIR))
    status_line("tool dir", str(TOOL_DIR) if TOOL_DIR.is_dir() else "<not installed>")
    status_line("tool revision", read_installed_tool_revision())
    status_line("components", ", ".join(component.name for component in installed_components()) or "<none>")
    for component in selected_components(args.component):
        status_component(component)
    if component_installed(PROMETHEUS) and scrape_jobs():
        print("\nScrape targets:")
        cmd_prometheus_target_list(args)
    print(f"\nRun '{MONCTL_CMD} doctor' to check whether any of this is broken.")
    return 0


def component_removed_paths(component: Component, purge: bool) -> list[Path]:
    paths = [service_file(component)]
    if component is GRAFANA:
        paths.extend([GRAFANA_HOME_DIR, GRAFANA_CONFIG_DIR])
        if purge:
            paths.extend([GRAFANA_DATA_DIR, GRAFANA_LOG_DIR])
        return paths
    for name in component.binaries:
        paths.append(binary_path(name))
        paths.extend(kept_binary_versions(BINARY_VERSION_DIR, name))
    if component is PROMETHEUS:
        paths.append(PROMETHEUS_CONFIG_DIR)
        if purge:
            paths.append(PROMETHEUS_DATA_DIR)
    return paths


def component_preserved_paths(component: Component, purge: bool) -> list[tuple[Path, str]]:
    if purge:
        return []
    if component is PROMETHEUS:
        return [(PROMETHEUS_DATA_DIR, "the time series database")]
    if component is GRAFANA:
        return [(GRAFANA_DATA_DIR, "dashboards, users and plugins"), (GRAFANA_LOG_DIR, "logs")]
    return []


def removes_tool_files(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "remove_tools", False) or args.purge)


def resolve_uninstall_components(args: argparse.Namespace) -> list[Component]:
    if getattr(args, "components", ""):
        return [component_by_name(name) for name in parse_csv(args.components)]
    present = installed_components()
    if not present and not removes_tool_files(args):
        # --remove-tools still has work to do here: the components are usually
        # removed first, and the tool files are what is left behind
        raise CLIError(f"No managed component found under {ROOT_DIR}; nothing to uninstall")
    return present


def print_uninstall_plan(components: list[Component], args: argparse.Namespace) -> None:
    print("Monitoring uninstall plan:")
    print(f"  Components:  {', '.join(component.name for component in components) or '<none installed>'}")
    if components:
        print("  Stop and disable services:")
        for component in components:
            print(f"    - {component.service}.service")
        print("  Remove paths:")
        for component in components:
            for path in component_removed_paths(component, args.purge):
                suffix = "   <-- deletes stored metrics or dashboards" if args.purge and path in {
                    PROMETHEUS_DATA_DIR, GRAFANA_DATA_DIR} else ""
                print(f"    - {path}{suffix}")
    preserved = [item for component in components for item in component_preserved_paths(component, args.purge)]
    if preserved:
        print("  Preserve paths:")
        for path, note in preserved:
            print(f"    - {path}   <-- {note}; add --purge to delete it")
    if components:
        print("  Remove system users:")
        for component in components:
            print(f"    - {component.user}")
    if removes_tool_files(args):
        print("  Remove tool paths:")
        for path in (TOOL_ENTRY, TOOL_PATH, TOOL_DIR, TOOL_STATE_DIR, TOOL_LOG_DIR):
            note = "   <-- recreated afterwards, holding this command's audit record" if path == TOOL_LOG_DIR else ""
            print(f"    - {path}{note}")
    if args.purge:
        print(f"  Remove the directories under {ROOT_DIR} that end up empty")
    else:
        print("  Preserve tool paths:")
        print(f"    - {TOOL_DIR}")
        print(f"    - {TOOL_STATE_DIR}")
        print(f"    - {TOOL_LOG_DIR}")


def remove_component(component: Component, purge: bool) -> None:
    log_info(f"Stopping {component.service}.service")
    run_root(["systemctl", "stop", component.service], check=False)
    run_root(["systemctl", "disable", component.service], check=False)
    for path in component_removed_paths(component, purge):
        if path.exists() or path.is_symlink():
            safe_remove_path(path)
    run_root(["systemctl", "daemon-reload"])
    run_root(["systemctl", "reset-failed", component.service], check=False)
    if run(["id", component.user], check=False, capture=True).returncode == 0:
        log_info(f"Removing system user: {component.user}")
        run_root(["userdel", component.user], check=False)
    forget_component(component)
    log_success(f"{component.name} removed")


def prune_empty_root_directories() -> None:
    """After a purge, leave nothing behind but the audit record.

    rmdir refuses a directory that still holds anything, so a component this
    command was not asked to remove keeps its directories.
    """
    for path in (BINARY_VERSION_DIR, BIN_DIR, ETC_DIR, DATA_ROOT, SHARE_DIR, ROOT_DIR / "lib"):
        run_root(["rmdir", "--ignore-fail-on-non-empty", "--", str(path)], check=False)


def cmd_uninstall(args: argparse.Namespace) -> int:
    components = resolve_uninstall_components(args)
    print_uninstall_plan(components, args)
    if args.dry_run:
        return 0
    confirm_action("Proceed with uninstall? Type yes to continue: ", args.yes, "Uninstall")
    require_linux()
    if components:
        require_command("systemctl")
    for component in components:
        remove_component(component, args.purge)
    if removes_tool_files(args):
        log_info("Removing the monctl files")
        for path in (TOOL_ENTRY, TOOL_PATH, TOOL_DIR, TOOL_STATE_DIR, TOOL_LOG_DIR):
            if Path(path).exists() or Path(path).is_symlink():
                safe_remove_path(path)
        # every command writes an audit record when it ends, including this one,
        # so the log directory comes back holding exactly that one line
        log_warn(f"{TOOL_LOG_DIR} is recreated for this command's own audit record")
    if args.purge:
        prune_empty_root_directories()
    else:
        log_warn(f"monctl files preserved: {TOOL_DIR}. Use --remove-tools to remove them")
    log_success("Monitoring uninstallation completed")
    return 0


def cmd_quickstart(_: argparse.Namespace) -> int:
    print(
        f"""Monitoring manager quickstart, in the order the commands are meant to be used.

A normal setup is two kinds of host: every machine you want to watch runs
node_exporter, and one monitoring host runs Prometheus and Grafana.

1. On every machine you want to watch
     {MONCTL_CMD} node-exporter install
     {MONCTL_CMD} doctor --component node-exporter

   The exporter listens on {DEFAULT_NODE_EXPORTER_LISTEN} so the monitoring host can reach it.
   It has no authentication, so restrict the port to that host.

2. On the monitoring host
     {MONCTL_CMD} prometheus install
     {MONCTL_CMD} grafana install

   prometheus install picks up a node_exporter on the same host by itself, and
   grafana install provisions the local Prometheus as its default datasource.

   Grafana brings no dashboard for these metrics, so its home page stays empty
   even though the data is already being collected. Import one:
     {dashboard_hint("     ")}

3. Point Prometheus at the other machines
     {MONCTL_CMD} prometheus target add --address 10.0.0.11:9100 --label instance=web-1
     {MONCTL_CMD} prometheus target list

   Targets live in JSON files that Prometheus re-reads on its own, so adding one
   needs no restart and no reload.

4. Check everything at once
     {MONCTL_CMD} doctor
     {MONCTL_CMD} status

5. Keep it current, review before removing anything
     {MONCTL_CMD} prometheus upgrade --dry-run
     {MONCTL_CMD} uninstall --dry-run

Run '{MONCTL_CMD} tutor <topic>' for the reasoning behind each step.
"""
    )
    return 0


TUTOR_TOPICS = {
    "overview": f"""Monitoring manager tutor.

Install and manage node_exporter, Prometheus and Grafana from release tarballs,
as systemd services under {ROOT_DIR}.

Start here:
  {MONCTL_CMD} quickstart
  {MONCTL_CMD} doctor

Topics, in the same order as the commands:
  1. Set up        node-exporter, prometheus, grafana
  2. Wire up       targets
  3. Maintain      upgrade, layout, uninstall

  {MONCTL_CMD} tutor node-exporter
  {MONCTL_CMD} tutor prometheus
  {MONCTL_CMD} tutor grafana
  {MONCTL_CMD} tutor targets
  {MONCTL_CMD} tutor upgrade
  {MONCTL_CMD} tutor layout
  {MONCTL_CMD} tutor uninstall
""",
    "node-exporter": f"""node_exporter: the agent on every machine.

It reads /proc and /sys and serves the numbers at /metrics. It stores nothing
and scrapes nothing, so it is the piece you install many times.

  {MONCTL_CMD} node-exporter install --listen {DEFAULT_NODE_EXPORTER_LISTEN}

The default listen address is every interface, because a Prometheus on another
host has to reach it. There is no authentication and no TLS, so the port belongs
behind a firewall rule that only allows the monitoring host. Use --listen
127.0.0.1:9100 when Prometheus runs on the same machine.

Collectors are on and off per release default; adjust them without editing the
unit file:

  {MONCTL_CMD} node-exporter install --enable-collector systemd \\
      --disable-collector mdadm

ProtectHome in the unit is read-only rather than yes on purpose: hiding /home
would make a separate /home mount disappear from the filesystem metrics.
""",
    "prometheus": f"""Prometheus: scrapes the exporters and stores the series.

  {MONCTL_CMD} prometheus install --retention {DEFAULT_PROMETHEUS_RETENTION}

It listens on {DEFAULT_PROMETHEUS_LISTEN} by default, because the thing that
normally reads it is a Grafana on the same host. Widen it with --listen only
behind a proxy that authenticates, since Prometheus itself does not.

Retention is a flag on the service, not a config file setting, so changing it
means running install again with another --retention. Re-running install is
safe: it keeps the data directory and the scrape targets.

The config file is generated, never hand-edited:

  {PROMETHEUS_CONFIG_FILE}

It contains one job for Prometheus itself plus one file_sd job per target file.
Editing it by hand means the next target change overwrites your edit, so the
tool refuses to touch a file it did not write.
""",
    "targets": f"""Scrape targets: a file per job, JSON that Prometheus watches.

  {MONCTL_CMD} prometheus target add --address 10.0.0.11:9100
  {MONCTL_CMD} prometheus target add --address 10.0.0.12:9100 --label instance=db-1
  {MONCTL_CMD} prometheus target list
  {MONCTL_CMD} prometheus target remove --address 10.0.0.12:9100

Each job is one file under {PROMETHEUS_TARGET_DIR}, referenced from
prometheus.yml through file_sd_configs. Prometheus re-reads those files on a
timer, so adding or removing an address needs no reload and no restart, and a
typo in one file cannot stop the service from starting.

Only a brand new job rewrites prometheus.yml, and that rewrite is checked with
promtool before it is kept: a config promtool rejects is rolled back.

Removing the last address of a job keeps the job and its empty file. That is
deliberate, so the next add does not have to rewrite prometheus.yml again.
""",
    "grafana": f"""Grafana: dashboards on top of Prometheus.

  {MONCTL_CMD} grafana install --port {DEFAULT_GRAFANA_PORT}

The release tarball is around 450 MiB, so the download is the slow part.
The tree is kept whole under {GRAFANA_VERSION_DIR}, with
{GRAFANA_CURRENT_DIR} pointing at the release in use. An upgrade moves that
symlink, which is what makes the rollback possible.

When Prometheus is installed on the same host, install provisions it as the
default datasource. Point it somewhere else with --prometheus-url, or skip
provisioning entirely with --no-datasource.

Grafana starts with admin / admin and asks for a new password at the first
login. This tool never sets that password, so it never ends up in a config file
or in the audit log.

What it does not bring is a dashboard. The datasource is provisioned, the data
is being collected, and the home page is still empty until you import one:

  {dashboard_hint("  ")}

That import is done by the Grafana server, not your browser, so it needs to
reach grafana.com. On a host that cannot, fetch the JSON where you do have
access and paste it into "Import via dashboard JSON model" instead:

  curl -s https://grafana.com/api/dashboards/{GRAFANA_DASHBOARD_ID}/revisions/latest/download \\
    -o node-exporter-full.json

Provisioning a dashboard from a file is not wired up here yet, so this is a
per-host step for now.
""",
    "upgrade": f"""Upgrades: one component at a time, always with a way back.

  {MONCTL_CMD} prometheus upgrade --dry-run
  {MONCTL_CMD} prometheus upgrade --version 3.14.0

What happens: the new release is downloaded, checksummed and installed next to
the running one, the symlink is switched, and the service is restarted. If it
does not come back, the symlink is switched back and the service is restarted
on the old release, and the command fails loudly.

Old releases stay on disk (--keep, default 2) precisely so that rollback is a
symlink switch and not another download.

Nothing else is touched: configs, scrape targets, the TSDB, the Grafana
database and the installed tool files all stay as they are.
""",
    "layout": f"""Where everything lives.

  {ROOT_DIR}
    bin/                      node_exporter, prometheus, promtool symlinks
    bin/versions/             every release kept on disk
    share/grafana/current     symlink to the Grafana release in use
    etc/prometheus/           prometheus.yml and targets/
    etc/grafana/              grafana.ini and provisioning/
    data/                     TSDB, Grafana database, install metadata
    log/                      Grafana logs and this tool's audit log
    lib/monctl                the copy of this tool the node runs

Two ways to run the tool:

  In place        rsync tools/monitoring to the host and run ./monctl
  Installed       install copies it to {TOOL_DIR}
                  and links it as {TOOL_ENTRY}

install does the second by default, which is what lets a host manage itself
later without the source tree. Pass --no-install-tools to keep it in place only,
and refresh an installed copy from a checkout with 'tools update'.

The old tools.old/grafana/install.sh used /usr/local/bin and /etc/prometheus
instead. Nothing here touches those paths, and install refuses to start while
they are around unless you pass --force.
""",
    "uninstall": f"""Removing things, without losing data by accident.

  {MONCTL_CMD} uninstall --dry-run
  {MONCTL_CMD} prometheus uninstall --dry-run

Both print the plan first. Read the two lists: paths that are removed, and
paths that are preserved.

By default the data is preserved: the Prometheus TSDB and the Grafana database
survive an uninstall, so reinstalling gets the history and the dashboards back.
--purge is what deletes them, and it is the only way to delete them.

Binaries, unit files, generated configs and the system users go in both cases.
The installed tool copy and its audit log stay unless --remove-tools or --purge
is given.
""",
}


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    if topic not in TUTOR_TOPICS:
        raise CLIError(f"Unknown tutor topic: {topic}. Available: {', '.join(sorted(TUTOR_TOPICS))}")
    print(TUTOR_TOPICS[topic])
    return 0


COMMAND_GROUPS: list[tuple[str, str, list[tuple[str, str]]]] = [
    (
        "Set up a machine you want to watch",
        "",
        [
            ("node-exporter", "Host metrics exporter, one per machine"),
        ],
    ),
    (
        "Set up the monitoring host",
        "",
        [
            ("prometheus", "Scrape the exporters, store the series, manage targets"),
            ("grafana", "Dashboards on top of Prometheus"),
        ],
    ),
    (
        "Check the host",
        "",
        [
            ("doctor", "Check every installed component, including down targets"),
            ("status", "Show versions, listen addresses and scrape targets"),
        ],
    ),
    (
        "Maintain and remove",
        "",
        [
            ("tools", "Update the installed monctl files"),
            ("uninstall", "Remove components, after showing a removal plan"),
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


def with_version(args: argparse.Namespace) -> argparse.Namespace:
    args.version = args.version_opt or args.version_pos
    return args


def component_uninstall_args(args: argparse.Namespace, component: Component) -> argparse.Namespace:
    args.components = component.name
    args.remove_tools = False
    return args


def add_version_arguments(parser: argparse.ArgumentParser, component: Component) -> None:
    parser.add_argument("version_pos", nargs="?", metavar="VERSION",
                        help=f"Version to install, for example {component.default_version} or latest "
                             f"(default: latest)")
    parser.add_argument("--version", dest="version_opt", metavar="VERSION",
                        help="Version to install; overrides the positional version")


def add_install_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--force", action="store_true",
                        help="Install over unit files, configs or an older non-managed install")
    add_bool_argument(parser, "--install-tools", default=True,
                      help_text=f"Copy {MONCTL_CMD} to {TOOL_DIR} and link it onto PATH",
                      no_help="Do not copy the tool onto this host; run it from this directory instead")


def add_upgrade_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--version", default="latest", help="Target version, or latest (default: latest)")
    parser.add_argument("--keep", type=int, default=2, metavar="N",
                        help="Releases to keep on disk, including the running one (default: 2)")
    parser.add_argument("--allow-downgrade", action="store_true",
                        help="Allow installing an older release than the running one")
    parser.add_argument("--dry-run", action="store_true", help="Print the upgrade plan without changing anything")
    parser.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")


def add_component_uninstall(sub: argparse._SubParsersAction, component: Component) -> None:
    parser = sub.add_parser(
        "uninstall",
        help=f"Remove {component.name} from this host",
        description=f"Stop {component.service}.service and remove the files this tool installed for\n"
        f"{component.name}, after printing a removal plan.\n"
        "\n"
        "Stored data is preserved unless --purge is given, so a reinstall picks up where\n"
        "this left off. Run --dry-run first and read both lists in the plan.",
    )
    parser.add_argument("--purge", action="store_true",
                        help="Also delete stored data for this component")
    parser.add_argument("--dry-run", action="store_true", help="Print the removal plan without changing files")
    parser.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    parser.set_defaults(func=lambda args: cmd_uninstall(component_uninstall_args(args, component)))


def build_parser() -> argparse.ArgumentParser:
    parser = CLIArgumentParser(
        prog=MONCTL_CMD,
        description="Manage a Prometheus metrics stack, in the order you actually use it.\n"
        "\n"
        f"{command_group_help()}\n"
        "\n"
        "A normal setup spans two kinds of host: node-exporter on every machine you want\n"
        "to watch, prometheus and grafana on one monitoring host.\n"
        "\n"
        f"Run '{MONCTL_CMD} <command> --help' for what a command does and when to use it,\n"
        f"or '{MONCTL_CMD} quickstart' for the whole path end to end.",
        epilog=f"""Examples:
  {MONCTL_CMD} node-exporter install
  {MONCTL_CMD} prometheus install --retention 30d
  {MONCTL_CMD} prometheus target add --address 10.0.0.11:9100 --label instance=web-1
  {MONCTL_CMD} grafana install
  {MONCTL_CMD} doctor
  {MONCTL_CMD} uninstall --dry-run
""",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    parser.set_defaults(func=lambda _: missing_subcommand(parser, MONCTL_CMD))

    node = sub.add_parser(
        "node-exporter",
        help=NODE_EXPORTER.summary,
        description="Manage node_exporter, the agent that exposes host metrics at /metrics.\n"
        "\n"
        "Install this on every machine you want to watch. It stores nothing and scrapes\n"
        "nothing, so nothing here needs to know where Prometheus is; the monitoring host\n"
        "is told about this machine instead, with 'prometheus target add'.",
    )
    node_sub = node.add_subparsers(dest="node_command")
    node.set_defaults(func=lambda _: missing_subcommand(node, f"{MONCTL_CMD} node-exporter"))
    node_install = node_sub.add_parser(
        "install",
        help="Install node_exporter and start it",
        description=f"Install node_exporter under {ROOT_DIR} and start node_exporter.service.\n"
        "\n"
        f"The default listen address is {DEFAULT_NODE_EXPORTER_LISTEN}, because Prometheus usually runs on\n"
        "another host. The endpoint has no authentication and no TLS, so restrict the port\n"
        "to the monitoring host. Use --listen 127.0.0.1:9100 when they share a machine.\n"
        "\n"
        "Re-running install is how you change the listen address or the collectors.",
    )
    add_version_arguments(node_install, NODE_EXPORTER)
    node_install.add_argument("--listen", default=DEFAULT_NODE_EXPORTER_LISTEN,
                              help=f"HOST:PORT to listen on (default: {DEFAULT_NODE_EXPORTER_LISTEN})")
    node_install.add_argument("--enable-collector", action="append", default=[], metavar="NAME",
                              help="Enable a collector that is off by default, repeatable")
    node_install.add_argument("--disable-collector", action="append", default=[], metavar="NAME",
                              help="Disable a collector that is on by default, repeatable")
    node_install.add_argument("--extra-arg", action="append", default=[], metavar="--FLAG",
                              help="Extra node_exporter flag for the unit file, repeatable")
    add_install_arguments(node_install)
    node_install.set_defaults(func=lambda args: cmd_node_exporter_install(with_version(args)))
    node_upgrade = node_sub.add_parser(
        "upgrade",
        help="Install another node_exporter release and restart it",
        description="Replace the node_exporter binary with another release and restart the service.\n"
        "\n"
        "The unit file and its flags are left alone. The replaced release stays on disk, so\n"
        "a service that fails to come back is switched to it again automatically.",
    )
    add_upgrade_arguments(node_upgrade)
    node_upgrade.set_defaults(func=lambda args: cmd_component_upgrade(NODE_EXPORTER, args))
    add_component_uninstall(node_sub, NODE_EXPORTER)

    prom = sub.add_parser(
        "prometheus",
        help=PROMETHEUS.summary,
        description="Manage Prometheus: the binary, the generated config and the scrape targets.\n"
        "\n"
        "prometheus.yml is generated from the target files, so it is never hand-edited.\n"
        "Targets themselves live in JSON files that Prometheus re-reads on its own, which\n"
        "is why adding one needs neither a restart nor a reload.",
    )
    prom_sub = prom.add_subparsers(dest="prometheus_command")
    prom.set_defaults(func=lambda _: missing_subcommand(prom, f"{MONCTL_CMD} prometheus"))
    prom_install = prom_sub.add_parser(
        "install",
        help="Install Prometheus and start it",
        description=f"Install Prometheus under {ROOT_DIR}, write a generated config and start\n"
        "prometheus.service.\n"
        "\n"
        f"It listens on {DEFAULT_PROMETHEUS_LISTEN} by default, since the usual reader is a Grafana on\n"
        "the same host. Prometheus has no authentication of its own, so widen --listen only\n"
        "behind something that does.\n"
        "\n"
        "Retention is a service flag rather than a config setting, so changing it means\n"
        "running install again with another --retention. That is safe: the data directory\n"
        "and the scrape targets are kept.",
    )
    add_version_arguments(prom_install, PROMETHEUS)
    prom_install.add_argument("--listen", default=DEFAULT_PROMETHEUS_LISTEN,
                              help=f"HOST:PORT to listen on (default: {DEFAULT_PROMETHEUS_LISTEN})")
    prom_install.add_argument("--retention", default=DEFAULT_PROMETHEUS_RETENTION,
                              help=f"How long to keep samples, for example 30d (default: {DEFAULT_PROMETHEUS_RETENTION})")
    prom_install.add_argument("--scrape-interval", default=DEFAULT_SCRAPE_INTERVAL,
                              help=f"Global scrape interval (default: {DEFAULT_SCRAPE_INTERVAL})")
    prom_install.add_argument("--external-url", default="",
                              help="Public URL when Prometheus is served behind a reverse proxy")
    prom_install.add_argument("--job", default=DEFAULT_JOB,
                              help=f"Scrape job created for the exporters (default: {DEFAULT_JOB})")
    prom_install.add_argument("--extra-arg", action="append", default=[], metavar="--FLAG",
                              help="Extra Prometheus flag for the unit file, repeatable")
    add_bool_argument(prom_install, "--scrape-local-node", default=True,
                      help_text="Add a node_exporter installed on this host to the scrape targets",
                      no_help="Do not scrape a node_exporter installed on this host")
    add_install_arguments(prom_install)
    prom_install.set_defaults(func=lambda args: cmd_prometheus_install(with_version(args)))
    prom_upgrade = prom_sub.add_parser(
        "upgrade",
        help="Install another Prometheus release and restart it",
        description="Replace the prometheus and promtool binaries with another release and restart\n"
        "prometheus.service.\n"
        "\n"
        "Only the binaries change: the config, the scrape targets and the time series\n"
        "database are left alone. The replaced release stays on disk, so a service that\n"
        "fails to come back is switched to it again automatically.",
    )
    add_upgrade_arguments(prom_upgrade)
    prom_upgrade.set_defaults(func=lambda args: cmd_component_upgrade(PROMETHEUS, args))
    target = prom_sub.add_parser(
        "target",
        help="Add, remove and list scrape targets",
        description="Manage the scrape targets Prometheus reads through file_sd.\n"
        "\n"
        f"Each job is one JSON file under {PROMETHEUS_TARGET_DIR}.\n"
        "Prometheus watches those files, so adding or removing an address takes effect on\n"
        "its own. Only a brand new job rewrites prometheus.yml, and that rewrite is checked\n"
        "with promtool and rolled back when it is rejected.",
    )
    target_sub = target.add_subparsers(dest="target_command")
    target.set_defaults(func=lambda _: missing_subcommand(target, f"{MONCTL_CMD} prometheus target"))
    target_add = target_sub.add_parser("add", help="Add a scrape target to a job")
    target_add.add_argument("--address", required=True, metavar="HOST:PORT",
                            help="Exporter address, for example 10.0.0.11:9100")
    target_add.add_argument("--job", default=DEFAULT_JOB, help=f"Scrape job (default: {DEFAULT_JOB})")
    target_add.add_argument("--label", action="append", default=[], metavar="KEY=VALUE",
                            help="Label attached to this target, repeatable")
    target_add.set_defaults(func=cmd_prometheus_target_add)
    target_remove = target_sub.add_parser("remove", help="Remove a scrape target")
    target_remove.add_argument("--address", required=True, metavar="HOST:PORT", help="Exporter address to remove")
    target_remove.add_argument("--job", default="", help="Only remove it from this job (default: every job)")
    target_remove.set_defaults(func=cmd_prometheus_target_remove)
    target_list = target_sub.add_parser("list", help="List configured targets and their health")
    target_list.set_defaults(func=cmd_prometheus_target_list)
    prom_reload = prom_sub.add_parser(
        "reload",
        help="Check the config and reload Prometheus",
        description="Run 'promtool check config' and, when it passes, reload prometheus.service.\n"
        "\n"
        "Target changes do not need this; it is here for after an --extra-arg change or a\n"
        "manual look at the generated config.",
    )
    prom_reload.set_defaults(func=cmd_prometheus_reload)
    add_component_uninstall(prom_sub, PROMETHEUS)

    graf = sub.add_parser(
        "grafana",
        help=GRAFANA.summary,
        description="Manage Grafana from the official release tarball.\n"
        "\n"
        f"The whole tree is kept under {GRAFANA_VERSION_DIR},\n"
        "with a symlink naming the release in use, which is what makes upgrades reversible.",
    )
    graf_sub = graf.add_subparsers(dest="grafana_command")
    graf.set_defaults(func=lambda _: missing_subcommand(graf, f"{MONCTL_CMD} grafana"))
    graf_install = graf_sub.add_parser(
        "install",
        help="Install Grafana and start it",
        description=f"Install Grafana under {ROOT_DIR} and start grafana.service.\n"
        "\n"
        "When Prometheus is installed on this host it is provisioned as the default\n"
        "datasource; point somewhere else with --prometheus-url, or skip it with\n"
        "--no-datasource.\n"
        "\n"
        "The release tarball is around 450 MiB, so the download dominates the install.\n"
        "\n"
        "No dashboard is installed: the home page stays empty until you import one, which\n"
        f"install prints at the end ({GRAFANA_DASHBOARD_ID}, Node Exporter Full).\n"
        "\n"
        "Grafana starts with admin / admin and asks for a new password at first login.\n"
        "This tool never sets that password, so it never lands in a config file or a log.",
    )
    add_version_arguments(graf_install, GRAFANA)
    graf_install.add_argument("--listen-addr", default=DEFAULT_GRAFANA_ADDR,
                              help=f"Address to bind (default: {DEFAULT_GRAFANA_ADDR}, every interface)")
    graf_install.add_argument("--port", type=int, default=DEFAULT_GRAFANA_PORT,
                              help=f"HTTP port (default: {DEFAULT_GRAFANA_PORT})")
    graf_install.add_argument("--domain", default=DEFAULT_GRAFANA_DOMAIN,
                              help=f"Public host name used in links (default: {DEFAULT_GRAFANA_DOMAIN})")
    graf_install.add_argument("--root-url", default="", help="Full public URL, overriding --domain and --port")
    graf_install.add_argument("--prometheus-url", default="",
                              help="Prometheus URL to provision (default: the one installed on this host)")
    add_bool_argument(graf_install, "--datasource", default=True,
                      help_text="Provision a Prometheus datasource",
                      no_help="Do not provision any datasource")
    add_install_arguments(graf_install)
    graf_install.set_defaults(func=lambda args: cmd_grafana_install(with_version(args)))
    graf_upgrade = graf_sub.add_parser(
        "upgrade",
        help="Install another Grafana release and restart it",
        description="Install another Grafana release next to the current one, move the symlink and\n"
        "restart grafana.service.\n"
        "\n"
        "The database, dashboards, plugins and grafana.ini are left alone. The replaced\n"
        "release stays on disk, so a service that fails to come back is switched to it\n"
        "again automatically.",
    )
    add_upgrade_arguments(graf_upgrade)
    graf_upgrade.set_defaults(func=lambda args: cmd_component_upgrade(GRAFANA, args))
    add_component_uninstall(graf_sub, GRAFANA)

    doctor = sub.add_parser(
        "doctor",
        help="Check every installed component",
        description="Check the components installed on this host: binaries, unit files, generated\n"
        "configs, service state, HTTP endpoints and, for Prometheus, every scrape target.\n"
        "\n"
        "Read-only. Components that are not installed here are reported as such rather than\n"
        "as failures, so the same command is useful on an exporter-only machine.",
    )
    doctor.add_argument("--component", default="all", choices=("all", *COMPONENT_NAMES),
                        help="Only check this component (default: all)")
    doctor.set_defaults(func=cmd_doctor)

    status = sub.add_parser(
        "status",
        help="Show versions, listen addresses and scrape targets",
        description="Show what is installed and how it is configured. doctor answers whether any of\n"
        "it is broken.",
    )
    status.add_argument("--component", default="all", choices=("all", *COMPONENT_NAMES),
                        help="Only show this component (default: all)")
    status.set_defaults(func=cmd_status)

    tools = sub.add_parser("tools", help=f"Update the installed {MONCTL_CMD} files")
    tools_sub = tools.add_subparsers(dest="tools_command")
    tools.set_defaults(func=lambda _: missing_subcommand(tools, f"{MONCTL_CMD} tools"))
    tools_update = tools_sub.add_parser(
        "update",
        help=f"Update the {MONCTL_CMD} files only",
        description="Refresh the tool copy that install placed on this host, without touching any\n"
        "binary, config or service state.\n"
        "\n"
        "The new files are read from the directory of the script you invoke, so run this\n"
        f"from a source checkout. Running the installed {TOOL_ENTRY} would\n"
        "copy the host's own copy onto itself and change nothing.",
    )
    tools_update.set_defaults(func=cmd_tools_update)

    uninstall = sub.add_parser(
        "uninstall",
        help="Remove components, after showing a removal plan",
        description="Stop the services and remove the files this tool installed, after printing a\n"
        "removal plan.\n"
        "\n"
        "Without --components it removes every component installed on this host. Stored\n"
        "data is preserved unless --purge is given: the Prometheus database and the Grafana\n"
        "dashboards survive, so a reinstall picks them up again.\n"
        "\n"
        "Run --dry-run first and read both lists in the plan.",
    )
    uninstall.add_argument("--components", default="",
                           help=f"Comma separated components to remove (default: every installed one). "
                                f"Available: {', '.join(COMPONENT_NAMES)}")
    uninstall.add_argument("--purge", action="store_true",
                           help="Also delete stored metrics, dashboards, tool metadata and audit logs")
    uninstall.add_argument("--remove-tools", action="store_true",
                           help=f"Also remove the installed {MONCTL_CMD} files")
    uninstall.add_argument("--dry-run", action="store_true", help="Print the removal plan without changing files")
    uninstall.add_argument("--yes", action="store_true", help="Skip the interactive confirmation")
    uninstall.set_defaults(func=cmd_uninstall)

    quickstart = sub.add_parser("quickstart", help="A copyable end-to-end setup workflow")
    quickstart.set_defaults(func=cmd_quickstart)

    tutor = sub.add_parser("tutor", help="Per-topic guidance with explanations")
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
    config = AuditConfig("monctl", AUDIT_LOG_FILE, {"tool_dir": str(TOOL_DIR)})
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
