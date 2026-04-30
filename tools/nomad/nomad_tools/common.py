from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


DEFAULT_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SENSITIVE_OPTIONS = {
    "--token",
    "--token-file",
    "--key-file",
    "--keys-file",
    "--tls-key-file",
    "--auth-config",
    "--password",
    "--client-secret",
}


class CLIError(Exception):
    def __init__(self, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def ensure_default_path() -> None:
    current = os.environ.get("PATH", "")
    os.environ["PATH"] = f"{DEFAULT_PATH}:{current}" if current else DEFAULT_PATH


def log_info(message: str) -> None:
    print(f"[INFO] {message}", file=sys.stderr)


def log_warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def log_error(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)


def is_sensitive_option(arg: str) -> bool:
    return arg in SENSITIVE_OPTIONS


def redacted_args(args: Sequence[str]) -> list[str]:
    result: list[str] = []
    redact_next = False
    for arg in args:
        if redact_next:
            result.append("<redacted>")
            redact_next = False
            continue
        if any(arg.startswith(f"{option}=") for option in SENSITIVE_OPTIONS):
            result.append(f"{arg.split('=', 1)[0]}=<redacted>")
            continue
        result.append(arg)
        if is_sensitive_option(arg):
            redact_next = True
    return result


def redacted_command_line(args: Sequence[str]) -> str:
    return " ".join(redacted_args(args)) or "help"


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def require_command(command: str) -> None:
    if not command_exists(command):
        raise CLIError(f"Required command not found: {command}")


def run(
    args: Sequence[str],
    *,
    check: bool = True,
    capture: bool = False,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(args),
            check=check,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            env=env,
            input=input_text,
        )
    except FileNotFoundError as exc:
        raise CLIError(f"Required command not found: {args[0]}") from exc
    except subprocess.CalledProcessError as exc:
        if capture and exc.stderr:
            log_error(exc.stderr.rstrip())
        raise


def run_root(args: Sequence[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    if os.geteuid() == 0:
        return run(args, **kwargs)
    require_command("sudo")
    return run(["sudo", *args], **kwargs)


def require_linux() -> None:
    if platform.system() != "Linux":
        raise CLIError("This command only supports Linux")


def detect_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return "amd64"
    if machine in {"aarch64", "arm64"}:
        return "arm64"
    if machine in {"i386", "i686"}:
        return "386"
    raise CLIError(f"Unsupported architecture: {platform.machine()}")


def validate_name(value: str, label: str) -> str:
    if not re.match(r"^[A-Za-z0-9_.-]+$", value):
        raise CLIError(f"Invalid {label}: {value}")
    return value


def validate_hcl_key(value: str) -> str:
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", value):
        raise CLIError(f"Invalid HCL key: {value}")
    return value


def parse_bool(value: str | bool) -> bool:
    if isinstance(value, bool):
        return value
    if value == "true":
        return True
    if value == "false":
        return False
    raise CLIError(f"Invalid boolean value: {value}")


def hcl_bool(value: bool) -> str:
    return "true" if value else "false"


def hcl_string(value: object) -> str:
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


def parse_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def hcl_list(values: Iterable[object]) -> str:
    return "[" + ", ".join(hcl_string(value) for value in values) + "]"


def atomic_write_text(path: str | Path, content: str, *, mode: int = 0o644, force: bool = True) -> None:
    target = Path(path)
    if target.exists() and not force:
        raise CLIError(f"Output exists, use --force to overwrite: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=str(target.parent)) as handle:
        handle.write(content)
        tmp_name = handle.name
    os.chmod(tmp_name, mode)
    os.replace(tmp_name, target)


def install_text(
    path: str | Path,
    content: str,
    *,
    mode: str = "0644",
    owner: str | None = None,
    group: str | None = None,
) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(content)
        tmp_name = handle.name
    try:
        args = ["install", "-m", mode]
        if owner:
            args.extend(["-o", owner])
        if group:
            args.extend(["-g", group])
        args.extend([tmp_name, str(path)])
        run_root(args)
    finally:
        Path(tmp_name).unlink(missing_ok=True)


def safe_remove_path(path: str | Path) -> None:
    value = str(path)
    unsafe = {"", "/", "/usr", "/usr/local", "/usr/local/bin", "/etc", "/opt", "/var", "/var/lib"}
    if value in unsafe:
        raise CLIError(f"Refuse to remove unsafe path: {value}")
    if Path(value).exists() or Path(value).is_symlink():
        run_root(["rm", "-rf", "--", value])


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_url(url: str, *, timeout: int = 60, no_proxy: bool = False) -> bytes:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({})) if no_proxy else urllib.request.build_opener()
    request = urllib.request.Request(url, headers={"User-Agent": "nomad-init-tools/1"})
    with opener.open(request, timeout=timeout) as response:
        return response.read()


def download_file(url: str, output: str | Path, *, timeout: int = 300) -> None:
    data = fetch_url(url, timeout=timeout)
    Path(output).write_bytes(data)


def extract_zip(zip_file: str | Path, output_dir: str | Path) -> None:
    with zipfile.ZipFile(zip_file) as archive:
        archive.extractall(output_dir)


def with_default_scheme(address: str, scheme: str) -> str:
    if address.startswith(("http://", "https://")):
        return address
    return f"{scheme}://{address}"


def http_status(url: str, *, timeout: int = 5) -> int:
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        request = urllib.request.Request(url, headers={"User-Agent": "nomad-init-tools/1"})
        with opener.open(request, timeout=timeout) as response:
            return int(response.status)
    except urllib.error.HTTPError as exc:  # type: ignore[attr-defined]
        return int(exc.code)
    except urllib.error.URLError:
        return 0


def wait_http(url: str, *, attempts: int, delay: float) -> bool:
    for _ in range(attempts):
        try:
            fetch_url(url, timeout=5, no_proxy=True)
            return True
        except Exception:
            time.sleep(delay)
    return False


def current_script_dir(file_value: str) -> Path:
    return Path(file_value).resolve().parent


@dataclass(frozen=True)
class AuditConfig:
    tool: str
    log_file: Path
    extra: dict[str, str] | None = None


def append_audit_line(config: AuditConfig, line: str) -> None:
    log_file = config.log_file
    try:
        if os.geteuid() == 0:
            log_file.parent.mkdir(parents=True, mode=0o750, exist_ok=True)
            if not log_file.exists():
                log_file.touch(mode=0o640)
            with log_file.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
            return
        if command_exists("sudo") and subprocess.run(["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            subprocess.run(["sudo", "-n", "install", "-d", "-m", "0750", "-o", "root", "-g", "root", str(log_file.parent)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            subprocess.run(["sudo", "-n", "tee", "-a", str(log_file)], input=line + "\n", text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        return


def audit_record(config: AuditConfig, result: str, exit_code: int, argv: Sequence[str], error: str | None = None) -> None:
    payload: dict[str, object] = {
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tool": config.tool,
        "result": result,
        "exit_code": exit_code,
        "user": os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown",
        "sudo_user": os.environ.get("SUDO_USER", ""),
        "host": platform.node() or "unknown",
        "cwd": os.getcwd(),
        "script": str(Path(sys.argv[0]).resolve()),
        "command": redacted_command_line(argv),
        "args": redacted_args(argv),
        "error": error,
    }
    if config.extra:
        payload.update(config.extra)
    append_audit_line(config, json.dumps(payload, ensure_ascii=True, separators=(",", ":")))


def is_quiet_help(argv: Sequence[str]) -> bool:
    if not argv:
        return True
    if argv[0] in {"tutor", "help", "-h", "--help"}:
        return True
    return any(arg in {"help", "-h", "--help"} for arg in argv)


def run_with_audit(config: AuditConfig, argv: Sequence[str], callback) -> int:
    quiet = is_quiet_help(argv)
    command_line = redacted_command_line(argv)
    if not quiet:
        log_info(f"Starting {config.tool} command: {command_line}")
    audit_record(config, "started", 0, argv)
    try:
        result = callback(list(argv))
        exit_code = 0 if result is None else int(result)
    except CLIError as exc:
        log_error(str(exc))
        audit_record(config, "failed", exc.exit_code, argv, str(exc))
        return exc.exit_code
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else 1
        if code == 0:
            audit_record(config, "success", 0, argv)
        else:
            audit_record(config, "failed", code, argv, str(exc.code))
        return code
    except subprocess.CalledProcessError as exc:
        code = exc.returncode or 1
        message = f"Command failed ({code}): {' '.join(map(str, exc.cmd if isinstance(exc.cmd, list) else [exc.cmd]))}"
        log_error(message)
        audit_record(config, "failed", code, argv, message)
        return code
    except KeyboardInterrupt:
        audit_record(config, "failed", 130, argv, "Interrupted")
        return 130
    except Exception as exc:
        log_error(str(exc))
        audit_record(config, "failed", 1, argv, str(exc))
        return 1
    if exit_code == 0:
        if not quiet:
            log_info(f"Completed {config.tool} command: {command_line}")
        audit_record(config, "success", 0, argv)
    else:
        audit_record(config, "failed", exit_code, argv, f"Exited with {exit_code}")
    return exit_code
