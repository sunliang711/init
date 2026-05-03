from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from .common import (
    AuditConfig,
    CLIArgumentParser,
    CLIError,
    atomic_write_text,
    ensure_default_path,
    hcl_bool,
    hcl_list,
    hcl_string,
    log_info,
    log_warn,
    parse_csv,
    require_command,
    run,
    run_with_audit,
    missing_subcommand,
    validate_name,
)


NOMAD_ROOT_DIR = Path("/opt/nomad")
HOST_VOLUME_DIR = NOMAD_ROOT_DIR / "volumes"
TOOL_LOG_DIR = NOMAD_ROOT_DIR / "log" / "nomad-init-tools"
AUDIT_LOG_FILE = TOOL_LOG_DIR / "job.audit.log"
MIN_PORT = 1
MAX_PORT = 65535
SUPPORTED_PORT_PROTOCOLS = {"tcp", "udp"}


def parse_positive_int_argument(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid positive integer: {value}") from exc
    if number < 1:
        raise argparse.ArgumentTypeError(f"expected a positive integer, got {value}")
    return number


def validate_positive_int(value: int, label: str) -> int:
    if value < 1:
        raise CLIError(f"Invalid {label}: {value} (expected a positive integer)")
    return value


def parse_port_number(value: object, label: str) -> int:
    try:
        number = int(str(value))
    except ValueError as exc:
        raise CLIError(f"Invalid {label}: {value} (expected an integer)") from exc
    if number < MIN_PORT or number > MAX_PORT:
        raise CLIError(f"Invalid {label}: {value} (expected {MIN_PORT}-{MAX_PORT})")
    return number


def parse_port_number_or_warn(value: object, label: str, warnings: list[str]) -> int | None:
    try:
        return parse_port_number(value, label)
    except CLIError as exc:
        warn(warnings, str(exc))
        return None


def parse_port_protocol(value: object, label: str) -> str:
    protocol = str(value).lower()
    if protocol not in SUPPORTED_PORT_PROTOCOLS:
        raise CLIError(f"Invalid {label}: {value} (expected tcp or udp)")
    return protocol


def parse_port_protocol_or_warn(value: object, label: str, warnings: list[str]) -> str | None:
    try:
        return parse_port_protocol(value, label)
    except CLIError as exc:
        warn(warnings, str(exc))
        return None


def parse_non_negative_int_or_warn(value: object, label: str, default: int, warnings: list[str]) -> int:
    try:
        number = int(str(value))
    except ValueError:
        warn(warnings, f"invalid {label} {value!r}, using {default}")
        return default
    if number < 0:
        warn(warnings, f"invalid {label} {value!r}, using {default}")
        return default
    return number


def heredoc_delimiter(data: str, base: str = "EOH") -> str:
    used = {line.strip() for line in data.splitlines()}
    if base not in used:
        return base
    for index in range(1, 100):
        candidate = f"{base}_{index}"
        if candidate not in used:
            return candidate
    raise CLIError("Template content conflicts with heredoc delimiters")


def parse_key_value(value: str, label: str) -> tuple[str, str]:
    if "=" not in value:
        raise CLIError(f"Invalid {label}, expected KEY=VALUE: {value}")
    key, val = value.split("=", 1)
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        raise CLIError(f"Invalid env key: {key}")
    return key, val


def read_env_file(path: str) -> list[tuple[str, str]]:
    env: list[tuple[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            env.append(parse_key_value(line, f"env file entry in {path}"))
    return env


def parse_port(value: str, index: int) -> dict[str, Any]:
    pieces = value.rsplit("/", 1)
    proto = parse_port_protocol(pieces[1] if len(pieces) == 2 else "tcp", "port protocol")
    fields = pieces[0].split(":")
    if len(fields) == 2:
        name, to = fields
        static = None
    elif len(fields) == 3:
        name, static, to = fields
    else:
        raise CLIError(f"Invalid port spec: {value}")
    return {
        "name": validate_name(name or f"p{index}", "port name"),
        "static": parse_port_number(static, "static port") if static else None,
        "to": parse_port_number(to, "target port"),
        "protocol": proto,
    }


def parse_mount(value: str) -> dict[str, Any]:
    fields = value.split(":")
    if not fields:
        raise CLIError(f"Invalid mount spec: {value}")
    mount_type = fields[0]
    readonly = False
    if fields[-1] in {"ro", "rw"}:
        readonly = fields[-1] == "ro"
        fields = fields[:-1]
    if mount_type in {"bind", "volume"}:
        if len(fields) != 3:
            raise CLIError(f"Invalid {mount_type} mount spec: {value}")
        return {"type": mount_type, "source": fields[1], "target": fields[2], "readonly": readonly}
    if mount_type == "tmpfs":
        if len(fields) != 2:
            raise CLIError(f"Invalid tmpfs mount spec: {value}")
        return {"type": "tmpfs", "target": fields[1], "readonly": readonly}
    raise CLIError(f"Unsupported mount type: {mount_type}")


def parse_host_volume(value: str) -> dict[str, Any]:
    fields = value.split(":")
    readonly = False
    if fields[-1] in {"ro", "rw"}:
        readonly = fields[-1] == "ro"
        fields = fields[:-1]
    if len(fields) != 2:
        raise CLIError(f"Invalid host volume spec: {value}")
    return {"name": validate_name(fields[0], "host volume name"), "destination": fields[1], "readonly": readonly}


def parse_template_file(value: str) -> dict[str, Any]:
    fields = value.split(":")
    env = False
    if fields[-1] == "env":
        env = True
        fields = fields[:-1]
    if len(fields) != 2:
        raise CLIError(f"Invalid template-file spec: {value}")
    source, destination = fields
    with open(source, "r", encoding="utf-8") as handle:
        data = handle.read()
    return {"source": source, "destination": destination, "env": env, "data": data}


def emit_task(
    lines: list[str],
    args: argparse.Namespace,
    ports: list[dict[str, Any]],
    env_items: list[tuple[str, str]],
    mounts: list[dict[str, Any]],
    host_volumes: list[dict[str, Any]],
    templates: list[dict[str, Any]],
) -> None:
    indent = "    "
    lines.append(f"{indent}task {hcl_string(args.task)} {{")
    lines.append(f'{indent}  driver = "docker"')
    lines.append("")
    lines.append(f"{indent}  config {{")
    lines.append(f"{indent}    image = {hcl_string(args.image)}")
    if args.command:
        lines.append(f"{indent}    command = {hcl_string(args.command)}")
    if args.arg:
        lines.append(f"{indent}    args = {hcl_list(args.arg)}")
    if ports:
        lines.append(f"{indent}    ports = {hcl_list([p['name'] for p in ports])}")
    for mount in mounts:
        lines.append("")
        lines.append(f"{indent}    mount {{")
        lines.append(f"{indent}      type = {hcl_string(mount['type'])}")
        if "source" in mount:
            lines.append(f"{indent}      source = {hcl_string(mount['source'])}")
        lines.append(f"{indent}      target = {hcl_string(mount['target'])}")
        lines.append(f"{indent}      readonly = {hcl_bool(mount['readonly'])}")
        lines.append(f"{indent}    }}")
    lines.append("")
    lines.append(f"{indent}    logging {{")
    lines.append(f'{indent}      type = "json-file"')
    lines.append("")
    lines.append(f"{indent}      config {{")
    lines.append(f'{indent}        max-file = "2"')
    lines.append(f'{indent}        max-size = "1m"')
    lines.append(f"{indent}      }}")
    lines.append(f"{indent}    }}")
    lines.append(f"{indent}  }}")
    if env_items:
        lines.append("")
        lines.append(f"{indent}  env {{")
        for key, val in sorted(env_items):
            lines.append(f"{indent}    {key} = {hcl_string(val)}")
        lines.append(f"{indent}  }}")
    if args.identity_aud:
        lines.append("")
        lines.append(f"{indent}  identity {{")
        lines.append(f'{indent}    name = "vault_default"')
        lines.append(f"{indent}    aud  = {hcl_list(parse_csv(args.identity_aud))}")
        lines.append(f"{indent}    file = true")
        lines.append(f"{indent}    ttl  = {hcl_string(args.identity_ttl)}")
        lines.append(f"{indent}  }}")
    if args.vault_role:
        lines.append("")
        lines.append(f"{indent}  vault {{")
        lines.append(f"{indent}    cluster = {hcl_string(args.vault_cluster)}")
        lines.append(f"{indent}    role    = {hcl_string(args.vault_role)}")
        lines.append(f"{indent}  }}")
    for template in templates:
        delimiter = heredoc_delimiter(str(template["data"]))
        lines.append("")
        lines.append(f"{indent}  template {{")
        lines.append(f"{indent}    destination = {hcl_string(template['destination'])}")
        lines.append(f"{indent}    env         = {hcl_bool(template['env'])}")
        lines.append(f"{indent}    data = <<{delimiter}")
        lines.append(str(template["data"]).rstrip("\n"))
        lines.append(delimiter)
        lines.append(f"{indent}  }}")
    for volume in host_volumes:
        lines.append("")
        lines.append(f"{indent}  volume_mount {{")
        lines.append(f"{indent}    volume      = {hcl_string(volume['name'])}")
        lines.append(f"{indent}    destination = {hcl_string(volume['destination'])}")
        lines.append(f"{indent}    read_only   = {hcl_bool(volume['readonly'])}")
        lines.append(f"{indent}  }}")
    lines.append("")
    lines.append(f"{indent}  resources {{")
    lines.append(f"{indent}    cpu    = {args.cpu}")
    lines.append(f"{indent}    memory = {args.memory}")
    lines.append(f"{indent}  }}")
    if args.emit_service and ports:
        service_port = ports[0]["name"]
        lines.append("")
        lines.append(f"{indent}  service {{")
        lines.append(f"{indent}    name = {hcl_string(args.service_name or args.job)}")
        lines.append(f"{indent}    provider = {hcl_string(args.service_provider)}")
        lines.append(f"{indent}    port = {hcl_string(service_port)}")
        if args.check_http:
            lines.append("")
            lines.append(f"{indent}    check {{")
            lines.append(f'{indent}      type     = "http"')
            lines.append(f"{indent}      path     = {hcl_string(args.check_http)}")
            lines.append(f"{indent}      interval = {hcl_string(args.check_interval)}")
            lines.append(f"{indent}      timeout  = {hcl_string(args.check_timeout)}")
            lines.append(f"{indent}    }}")
        elif args.check_tcp:
            lines.append("")
            lines.append(f"{indent}    check {{")
            lines.append(f'{indent}      type     = "tcp"')
            lines.append(f"{indent}      interval = {hcl_string(args.check_interval)}")
            lines.append(f"{indent}      timeout  = {hcl_string(args.check_timeout)}")
            lines.append(f"{indent}    }}")
        lines.append(f"{indent}  }}")
    lines.append(f"{indent}}}")


def build_scaffold_hcl(args: argparse.Namespace) -> str:
    validate_name(args.job, "job name")
    validate_name(args.group, "group name")
    validate_name(args.task, "task name")
    validate_positive_int(args.count, "group count")
    validate_positive_int(args.cpu, "CPU reservation")
    validate_positive_int(args.memory, "memory reservation")
    ports = [parse_port(value, index + 1) for index, value in enumerate(args.port or [])]
    mounts = [parse_mount(value) for value in args.mount or []]
    host_volumes = [parse_host_volume(value) for value in args.host_volume or []]
    templates = [parse_template_file(value) for value in args.template_file or []]
    env_items: list[tuple[str, str]] = []
    for path in args.env_file or []:
        env_items.extend(read_env_file(path))
    for item in args.env or []:
        env_items.append(parse_key_value(item, "env"))
    lines = [
        "# Generated by nomad-job scaffold docker",
        f"job {hcl_string(args.job)} {{",
        f"  type = {hcl_string(args.type)}",
        f"  datacenters = {hcl_list(parse_csv(args.datacenters))}",
    ]
    if args.namespace:
        lines.append(f"  namespace = {hcl_string(args.namespace)}")
    if args.region:
        lines.append(f"  region = {hcl_string(args.region)}")
    lines.extend(
        [
            "",
            "  update {",
            "    max_parallel     = 1",
            '    min_healthy_time = "10s"',
            '    healthy_deadline = "3m"',
            "    auto_revert      = true",
            "  }",
            "",
            f"  group {hcl_string(args.group)} {{",
            f"    count = {args.count}",
        ]
    )
    if ports:
        lines.append("")
        lines.append("    network {")
        for port in ports:
            lines.append(f"      port {hcl_string(port['name'])} {{")
            if port["static"] is not None:
                lines.append(f"        static = {port['static']}")
            lines.append(f"        to = {port['to']}")
            lines.append("      }")
        lines.append("    }")
    for volume in host_volumes:
        lines.append("")
        lines.append(f"    volume {hcl_string(volume['name'])} {{")
        lines.append('      type      = "host"')
        lines.append(f"      source    = {hcl_string(volume['name'])}")
        lines.append(f"      read_only = {hcl_bool(volume['readonly'])}")
        lines.append("    }")
    lines.append("")
    emit_task(lines, args, ports, env_items, mounts, host_volumes, templates)
    lines.append("  }")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def write_output(path: str, content: str, force: bool) -> None:
    if path == "-":
        print(content, end="")
        return
    atomic_write_text(path, content, force=force)


def require_scaffold_argument(value: str | None, option: str) -> str:
    if not value:
        raise CLIError(f"Missing required argument: {option} (or use --interactive)", exit_code=2)
    return value


def require_interactive_terminal() -> None:
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise CLIError("Interactive mode requires a terminal")


def read_interactive_line(prompt: str) -> str:
    print(prompt, end="", file=sys.stderr, flush=True)
    value = sys.stdin.readline()
    if value == "":
        raise CLIError("Interactive input ended")
    return value.strip()


def prompt_text(label: str, default: str | None = None, *, required: bool = False) -> str | None:
    while True:
        suffix = f" [{default}]" if default not in (None, "") else ""
        value = read_interactive_line(f"{label}{suffix}: ")
        if value:
            return value
        if default not in (None, ""):
            return default
        if not required:
            return None
        log_warn("Value is required")


def prompt_yes_no(label: str, default: bool = False) -> bool:
    suffix = " [Y/n]" if default else " [y/N]"
    while True:
        value = read_interactive_line(f"{label}{suffix}: ").lower()
        if not value:
            return default
        if value in {"y", "yes"}:
            return True
        if value in {"n", "no"}:
            return False
        log_warn("Enter yes or no")


def prompt_choice(label: str, choices: list[str], default: str) -> str:
    choice_text = "/".join(choices)
    while True:
        value = prompt_text(f"{label} ({choice_text})", default, required=True)
        assert value is not None
        value = value.lower()
        if value in choices:
            return value
        log_warn(f"Enter one of: {', '.join(choices)}")


def prompt_positive_int(label: str, default: int) -> int:
    while True:
        value = prompt_text(label, str(default), required=True)
        assert value is not None
        try:
            return parse_positive_int_argument(value)
        except argparse.ArgumentTypeError as exc:
            log_warn(str(exc))


def prompt_name(label: str, default: str | None, name_label: str, *, required: bool = False) -> str | None:
    while True:
        value = prompt_text(label, default, required=required)
        if value is None:
            return None
        try:
            return validate_name(value, name_label)
        except CLIError as exc:
            log_warn(str(exc))


def resolve_host_volume_prompt_path(value: str) -> str:
    path = Path(value)
    if path.is_absolute():
        return str(path)
    base = HOST_VOLUME_DIR.resolve(strict=False)
    target = (base / path).resolve(strict=False)
    if target != base and base not in target.parents:
        raise CLIError(f"Host volume path escapes base directory {HOST_VOLUME_DIR}: {value}")
    return str(target)


def prompt_host_volume_path(label: str, default: str) -> str:
    while True:
        value = prompt_text(label, default, required=True)
        assert value is not None
        try:
            return resolve_host_volume_prompt_path(value)
        except CLIError as exc:
            log_warn(str(exc))


def prompt_repeat(label: str, item_label: str, current: list[str] | None, validator) -> list[str] | None:
    values = list(current or [])
    if values:
        print(f"Current {label}: {len(values)} item(s)", file=sys.stderr)
    while prompt_yes_no(f"Add {label}?", False):
        while True:
            value = prompt_text(f"{item_label} (empty to skip)")
            if value is None:
                return values or None
            try:
                validator(value)
                values.append(value)
                break
            except CLIError as exc:
                log_warn(str(exc))
    return values or None


def print_current_values(label: str, values: list[str] | None) -> None:
    items = list(values or [])
    if not items:
        print(f"Current {label}: none", file=sys.stderr)
        return
    print(f"Current {label}:", file=sys.stderr)
    for index, value in enumerate(items, 1):
        print(f"  {index}. {value}", file=sys.stderr)


def prompt_repeat_review(label: str, item_label: str, current: list[str] | None, validator) -> list[str] | None:
    values = list(current or [])
    while True:
        print_current_values(label, values)
        choice = prompt_choice(f"{label} action", ["add", "clear", "back"], "back")
        if choice == "back":
            return values or None
        if choice == "clear":
            values = []
            log_info(f"Cleared {label}")
            continue
        while True:
            value = prompt_text(f"{item_label} (empty to stop adding)")
            if value is None:
                break
            try:
                validator(value)
                values.append(value)
            except CLIError as exc:
                log_warn(str(exc))


def validate_env_file_prompt(value: str) -> None:
    if not Path(value).is_file():
        raise CLIError(f"Env file not found: {value}")


def validate_template_file_prompt(value: str) -> None:
    try:
        parse_template_file(value)
    except OSError as exc:
        raise CLIError(f"Template file is not readable: {value}") from exc


def print_template_file_examples() -> None:
    print(
        """Template file format:
  source:destination[:env]

Examples:
  templates/app.env.ctmpl:secrets/app.env:env
    Source file example:
      APP_ENV=prod
      LOG_LEVEL=info
      DB_HOST={{ with secret "kv/data/app/config" }}{{ .Data.data.db_host }}{{ end }}
      DB_USER={{ with secret "kv/data/app/config" }}{{ .Data.data.db_user }}{{ end }}
      DB_PASSWORD={{ with secret "kv/data/app/config" }}{{ .Data.data.db_password }}{{ end }}

  templates/app.conf.ctmpl:local/app.conf
    Render an application config file.

  templates/nginx.conf.ctmpl:local/nginx.conf
    Render a web server or sidecar config file.

  templates/bootstrap.sh.ctmpl:local/bootstrap.sh
    Render a startup script used by the task command.
""",
        file=sys.stderr,
    )


def prompt_template_files(current: list[str] | None) -> list[str] | None:
    values = list(current or [])
    if values:
        print(f"Current template file: {len(values)} item(s)", file=sys.stderr)
    while prompt_yes_no("Add template file?", False):
        print_template_file_examples()
        while True:
            value = prompt_text("Template spec source:destination[:env] (empty to skip)")
            if value is None:
                return values or None
            try:
                validate_template_file_prompt(value)
                values.append(value)
                break
            except CLIError as exc:
                log_warn(str(exc))
    return values or None


def prompt_template_files_review(current: list[str] | None) -> list[str] | None:
    values = list(current or [])
    while True:
        print_current_values("template file", values)
        choice = prompt_choice("template file action", ["add", "clear", "back"], "back")
        if choice == "back":
            return values or None
        if choice == "clear":
            values = []
            log_info("Cleared template file")
            continue
        print_template_file_examples()
        while True:
            value = prompt_text("Template spec source:destination[:env] (empty to stop adding)")
            if value is None:
                break
            try:
                validate_template_file_prompt(value)
                values.append(value)
            except CLIError as exc:
                log_warn(str(exc))


def default_host_volume_path(name: str) -> str:
    return str(HOST_VOLUME_DIR / name)


def parse_unique_host_volumes(values: list[str] | None) -> list[dict[str, Any]]:
    volumes: list[dict[str, Any]] = []
    seen: set[str] = set()
    for value in values or []:
        volume = parse_host_volume(value)
        name = str(volume["name"])
        if name in seen:
            continue
        volumes.append(volume)
        seen.add(name)
    return volumes


def prompt_host_volume_paths(args: argparse.Namespace) -> None:
    paths = dict(getattr(args, "host_volume_paths", {}) or {})
    for volume in parse_unique_host_volumes(args.host_volume):
        name = str(volume["name"])
        paths[name] = prompt_host_volume_path(
            f'Host path for Nomad client volume "{name}" (relative to {HOST_VOLUME_DIR})',
            paths.get(name) or default_host_volume_path(name),
        )
    args.host_volume_paths = paths


def shell_command(args: list[str]) -> str:
    return " ".join(shlex.quote(item) for item in args)


def host_volume_setup_commands(args: argparse.Namespace) -> list[str]:
    paths = getattr(args, "host_volume_paths", {}) or {}
    commands: list[str] = []
    for volume in parse_unique_host_volumes(args.host_volume):
        name = str(volume["name"])
        command = [
            "nomad-manager",
            "host-volume",
            "add",
            name,
        ]
        path = str(paths.get(name) or "")
        if path and path != default_host_volume_path(name):
            command.extend(["--path", path])
        command.append("--create")
        if volume["readonly"]:
            command.append("--read-only")
        commands.append(shell_command(command))
    return commands


def log_host_volume_guidance(args: argparse.Namespace) -> None:
    volumes = parse_unique_host_volumes(args.host_volume)
    if not volumes:
        return
    names = [str(volume["name"]) for volume in volumes]
    if len(names) == 1:
        log_warn(f'Host volume "{names[0]}" must exist on Nomad clients before this job can run')
        log_info("Configure it with:")
    else:
        log_warn(f"Host volumes must exist on Nomad clients before this job can run: {', '.join(names)}")
        log_info("Configure them with:")
    for command in host_volume_setup_commands(args):
        print(f"  {command}", file=sys.stderr)


def has_docker_host_mount(args: argparse.Namespace) -> bool:
    for value in args.mount or []:
        if parse_mount(value)["type"] in {"bind", "volume"}:
            return True
    return False


def log_docker_mount_guidance() -> None:
    log_warn("Docker bind or volume mounts require Docker driver volume support on Nomad clients")
    log_info("Configure it with:")
    print("  nomad-manager docker enable --volumes", file=sys.stderr)


def log_consul_service_guidance() -> None:
    log_warn("Consul service registration requires Nomad Consul integration before service discovery works")
    log_info("Configure it with:")
    print("  nomad-manager consul enable --address 127.0.0.1:8500", file=sys.stderr)


def vault_setup_commands(args: argparse.Namespace) -> list[str]:
    role = args.vault_role or "nomad-workloads"
    aud = args.identity_aud or "vault.io"
    common_args = [
        "--profile",
        "default",
        "--vault-addr",
        "http://127.0.0.1:8200",
        "--nomad-addr",
        "http://127.0.0.1:4646",
        "--role",
        role,
        "--aud",
        aud,
    ]
    return [
        shell_command(["nomad-manager", "vault-jwt", "plan", *common_args]),
        shell_command(["nomad-manager", "vault-jwt", "apply", *common_args]),
    ]


def log_vault_guidance(args: argparse.Namespace) -> None:
    if not args.vault_role:
        return
    log_warn(f'Vault role "{args.vault_role}" must exist before this job can read Vault secrets')
    log_info("Configure workload identity with:")
    for command in vault_setup_commands(args):
        print(f"  {command}", file=sys.stderr)


def log_scaffold_guidance(args: argparse.Namespace) -> None:
    log_host_volume_guidance(args)
    if has_docker_host_mount(args):
        log_docker_mount_guidance()
    if args.emit_service and args.port and args.service_provider == "consul":
        log_consul_service_guidance()
    log_vault_guidance(args)


def log_scaffold_next_steps(args: argparse.Namespace) -> None:
    print("Next:", file=sys.stderr)
    if args.out == "-":
        print("  Save stdout to a .nomad.hcl file, then run:", file=sys.stderr)
        print("  nomad-job validate <job-file>", file=sys.stderr)
        print("  nomad-job plan <job-file>", file=sys.stderr)
        print("  nomad-job apply <job-file>", file=sys.stderr)
    else:
        print(f"  {shell_command(['nomad-job', 'validate', args.out])}", file=sys.stderr)
        print(f"  {shell_command(['nomad-job', 'plan', args.out])}", file=sys.stderr)
        print(f"  {shell_command(['nomad-job', 'apply', args.out])}", file=sys.stderr)
    print(f"  {shell_command(['nomad-job', 'status', args.job])}", file=sys.stderr)


def log_compose_guidance(content: str) -> None:
    if "\n        mount {\n" in content:
        log_docker_mount_guidance()
    if f"provider = {hcl_string('consul')}" in content:
        log_consul_service_guidance()


def scaffold_summary(args: argparse.Namespace) -> list[str]:
    lines = [
        f"  Job: {args.job}",
        f"  Image: {args.image}",
        f"  Type: {args.type}",
        f"  Datacenters: {args.datacenters}",
        f"  Group/task: {args.group}/{args.task}",
        f"  Count: {args.count}",
        f"  Resources: cpu={args.cpu} memory={args.memory}",
        f"  Ports: {', '.join(args.port or []) if args.port else 'none'}",
        f"  Service: {'yes' if args.emit_service and args.port else 'no'}",
        f"  Env entries: {len(args.env or [])}",
        f"  Env files: {', '.join(args.env_file or []) if args.env_file else 'none'}",
        f"  Mounts: {len(args.mount or [])}",
        f"  Host volumes: {len(args.host_volume or [])}",
        f"  Templates: {len(args.template_file or [])}",
        f"  Output: {args.out}",
    ]
    paths = getattr(args, "host_volume_paths", {}) or {}
    if paths:
        lines.append(f"  Host volume setup: {', '.join(f'{name}={path}' for name, path in sorted(paths.items()))}")
    return lines


def print_scaffold_summary(args: argparse.Namespace) -> None:
    print("Scaffold summary:", file=sys.stderr)
    for item in scaffold_summary(args):
        print(item, file=sys.stderr)


def edit_basic_scaffold_fields(args: argparse.Namespace) -> None:
    args.job = prompt_name("Job name", args.job, "job name", required=True)
    args.image = prompt_text("Docker image", args.image, required=True)
    args.type = prompt_choice("Job type", ["service", "batch"], args.type)
    args.datacenters = prompt_text("Datacenters", args.datacenters, required=True)
    args.namespace = prompt_text("Namespace", args.namespace)
    args.region = prompt_text("Region", args.region)
    args.group = prompt_name("Group name", args.group or args.job, "group name", required=True)
    args.task = prompt_name("Task name", args.task or args.group, "task name", required=True)
    args.count = prompt_positive_int("Group count", args.count)
    args.cpu = prompt_positive_int("CPU reservation in MHz", args.cpu)
    args.memory = prompt_positive_int("Memory reservation in MB", args.memory)


def edit_docker_command(args: argparse.Namespace) -> None:
    choice = prompt_choice("Docker command action", ["set", "clear", "back"], "back")
    if choice == "back":
        return
    if choice == "clear":
        args.command = None
        args.arg = None
        log_info("Cleared Docker command override")
        return
    args.command = prompt_text("Docker command", args.command)
    args.arg = prompt_repeat_review("Docker command argument", "Argument", args.arg, lambda _: None)


def edit_service(args: argparse.Namespace) -> None:
    choice = prompt_choice("service block action", ["set", "clear", "back"], "back")
    if choice == "back":
        return
    if choice == "clear":
        args.emit_service = False
        args.service_name = None
        args.check_http = None
        args.check_tcp = False
        log_info("Cleared service block")
        return
    args.emit_service = True
    if not args.port:
        log_warn("Service block requires at least one port; add a port mapping before generation")
    args.service_name = prompt_name("Service name", args.service_name or args.job, "service name")
    args.service_provider = prompt_choice("Service provider", ["nomad", "consul"], args.service_provider)
    if args.check_http:
        check_default = "http"
    elif args.check_tcp:
        check_default = "tcp"
    else:
        check_default = "none"
    check_type = prompt_choice("Health check", ["none", "http", "tcp"], check_default)
    args.check_http = None
    args.check_tcp = False
    if check_type == "http":
        args.check_http = prompt_text("HTTP check path", "/health", required=True)
    elif check_type == "tcp":
        args.check_tcp = True
    if check_type != "none":
        args.check_interval = prompt_text("Health check interval", args.check_interval, required=True)
        args.check_timeout = prompt_text("Health check timeout", args.check_timeout, required=True)


def edit_host_volumes(args: argparse.Namespace) -> None:
    args.host_volume = prompt_repeat_review("host volume", "Host volume spec name:destination[:ro|rw]", args.host_volume, parse_host_volume)
    if args.host_volume:
        prompt_host_volume_paths(args)
    else:
        args.host_volume_paths = {}


def edit_vault_role(args: argparse.Namespace) -> None:
    choice = prompt_choice("Vault role action", ["set", "clear", "back"], "back")
    if choice == "back":
        return
    if choice == "clear":
        args.vault_role = None
        args.vault_cluster = "default"
        log_info("Cleared Vault role")
        return
    args.vault_role = prompt_text("Vault role", args.vault_role, required=True)
    args.vault_cluster = prompt_text("Vault cluster", args.vault_cluster, required=True)


def edit_workload_identity(args: argparse.Namespace) -> None:
    choice = prompt_choice("workload identity action", ["set", "clear", "back"], "back")
    if choice == "back":
        return
    if choice == "clear":
        args.identity_aud = None
        args.identity_ttl = "1h"
        log_info("Cleared workload identity")
        return
    args.identity_aud = prompt_text("Workload identity audiences", args.identity_aud, required=True)
    args.identity_ttl = prompt_text("Workload identity token TTL", args.identity_ttl, required=True)


def review_scaffold_interactive(args: argparse.Namespace) -> None:
    while True:
        print_scaffold_summary(args)
        print(
            """Edit before generate:
  basics          job, image, type, datacenters, group, task and resources
  command         Docker command override and arguments
  ports           port mappings
  service         service block and health check
  env             environment variables
  env-files       environment files
  mounts          Docker mounts
  host-volumes    host volumes and host paths
  templates       template files
  vault           Vault role
  identity        workload identity
  output          output path
  generate        generate the job file
  cancel          cancel interactive scaffold""",
            file=sys.stderr,
        )
        choice = prompt_choice(
            "Review action",
            ["basics", "command", "ports", "service", "env", "env-files", "mounts", "host-volumes", "templates", "vault", "identity", "output", "generate", "cancel"],
            "generate",
        )
        if choice == "generate":
            return
        if choice == "cancel":
            raise CLIError("Interactive scaffold cancelled")
        if choice == "basics":
            edit_basic_scaffold_fields(args)
        elif choice == "command":
            edit_docker_command(args)
        elif choice == "ports":
            args.port = prompt_repeat_review("port mapping", "Port spec name:to[/proto] or name:static:to[/proto]", args.port, lambda value: parse_port(value, 1))
        elif choice == "service":
            edit_service(args)
        elif choice == "env":
            args.env = prompt_repeat_review("environment variable", "Environment variable KEY=VALUE", args.env, lambda value: parse_key_value(value, "env"))
        elif choice == "env-files":
            args.env_file = prompt_repeat_review("environment file", "Env file path", args.env_file, validate_env_file_prompt)
        elif choice == "mounts":
            args.mount = prompt_repeat_review("Docker mount", "Mount spec bind:source:target[:ro|rw], volume:name:target[:ro|rw], or tmpfs:target[:ro|rw]", args.mount, parse_mount)
        elif choice == "host-volumes":
            edit_host_volumes(args)
        elif choice == "templates":
            args.template_file = prompt_template_files_review(args.template_file)
        elif choice == "vault":
            edit_vault_role(args)
        elif choice == "identity":
            edit_workload_identity(args)
        elif choice == "output":
            args.out = prompt_text("Output path, or '-' for stdout", args.out, required=True)


def run_scaffold_docker_interactive(args: argparse.Namespace) -> None:
    require_interactive_terminal()
    print("Nomad Docker job interactive scaffold", file=sys.stderr)
    args.job = prompt_name("Job name", args.job, "job name", required=True)
    args.image = prompt_text("Docker image", args.image, required=True)
    args.type = prompt_choice("Job type", ["service", "batch"], args.type)
    args.datacenters = prompt_text("Datacenters", args.datacenters, required=True)
    args.namespace = prompt_text("Namespace", args.namespace)
    args.region = prompt_text("Region", args.region)
    args.group = prompt_name("Group name", args.group or args.job, "group name", required=True)
    args.task = prompt_name("Task name", args.task or args.group, "task name", required=True)
    args.count = prompt_positive_int("Group count", args.count)
    args.cpu = prompt_positive_int("CPU reservation in MHz", args.cpu)
    args.memory = prompt_positive_int("Memory reservation in MB", args.memory)

    if prompt_yes_no("Configure Docker command override?", bool(args.command or args.arg)):
        args.command = prompt_text("Docker command", args.command)
        args.arg = prompt_repeat("Docker command argument", "Argument", args.arg, lambda _: None)

    args.port = prompt_repeat("port mapping", "Port spec name:to[/proto] or name:static:to[/proto]", args.port, lambda value: parse_port(value, 1))
    args.emit_service = prompt_yes_no("Emit service block?", bool(args.emit_service))
    if args.emit_service and not args.port:
        log_warn("Service block requires at least one port; no service block will be emitted")
    if args.emit_service and args.port:
        args.service_name = prompt_name("Service name", args.service_name or args.job, "service name")
        args.service_provider = prompt_choice("Service provider", ["nomad", "consul"], args.service_provider)
        if args.check_http:
            check_default = "http"
        elif args.check_tcp:
            check_default = "tcp"
        else:
            check_default = "none"
        check_type = prompt_choice("Health check", ["none", "http", "tcp"], check_default)
        args.check_http = None
        args.check_tcp = False
        if check_type == "http":
            args.check_http = prompt_text("HTTP check path", "/health", required=True)
        elif check_type == "tcp":
            args.check_tcp = True
        if check_type != "none":
            args.check_interval = prompt_text("Health check interval", args.check_interval, required=True)
            args.check_timeout = prompt_text("Health check timeout", args.check_timeout, required=True)

    args.env = prompt_repeat("environment variable", "Environment variable KEY=VALUE", args.env, lambda value: parse_key_value(value, "env"))
    args.env_file = prompt_repeat("environment file", "Env file path", args.env_file, validate_env_file_prompt)
    args.mount = prompt_repeat("Docker mount", "Mount spec bind:source:target[:ro|rw], volume:name:target[:ro|rw], or tmpfs:target[:ro|rw]", args.mount, parse_mount)
    args.host_volume = prompt_repeat("host volume", "Host volume spec name:destination[:ro|rw]", args.host_volume, parse_host_volume)
    if args.host_volume:
        prompt_host_volume_paths(args)
    args.template_file = prompt_template_files(args.template_file)

    if prompt_yes_no("Configure Vault role?", bool(args.vault_role)):
        args.vault_role = prompt_text("Vault role", args.vault_role, required=True)
        args.vault_cluster = prompt_text("Vault cluster", args.vault_cluster, required=True)
    if prompt_yes_no("Configure workload identity?", bool(args.identity_aud)):
        args.identity_aud = prompt_text("Workload identity audiences", args.identity_aud, required=True)
        args.identity_ttl = prompt_text("Workload identity token TTL", args.identity_ttl, required=True)

    default_out = args.out or f"jobs/{args.job}.nomad.hcl"
    args.out = prompt_text("Output path, or '-' for stdout", default_out, required=True)
    review_scaffold_interactive(args)


def cmd_scaffold_docker(args: argparse.Namespace) -> int:
    if args.interactive:
        run_scaffold_docker_interactive(args)
    else:
        args.job = require_scaffold_argument(args.job, "--job")
        args.image = require_scaffold_argument(args.image, "--image")
        args.out = args.out or "-"
    args.group = args.group or args.job
    args.task = args.task or args.group
    write_output(args.out, build_scaffold_hcl(args), args.force)
    sys.stdout.flush()
    log_scaffold_guidance(args)
    if args.interactive:
        log_scaffold_next_steps(args)
    return 0


def warn(warnings: list[str], message: str) -> None:
    warnings.append(message)


def sanitize_name(value: object) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value).strip()).strip("-")
    return text or "app"


def parse_memory(value: object, default: int, warnings: list[str]) -> int:
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return max(1, int(value) // (1024 * 1024))
    text = str(value).strip().lower()
    match = re.match(r"^([0-9.]+)\s*([kmgt]?i?b?)?$", text)
    if not match:
        warn(warnings, f"unsupported memory value {value!r}, using {default} MB")
        return default
    number = float(match.group(1))
    unit = match.group(2) or "b"
    factor = {
        "b": 1 / (1024 * 1024),
        "k": 1 / 1024,
        "kb": 1 / 1024,
        "ki": 1 / 1024,
        "kib": 1 / 1024,
        "m": 1,
        "mb": 1,
        "mi": 1,
        "mib": 1,
        "g": 1024,
        "gb": 1024,
        "gi": 1024,
        "gib": 1024,
        "t": 1024 * 1024,
        "tb": 1024 * 1024,
        "ti": 1024 * 1024,
        "tib": 1024 * 1024,
    }.get(unit, 1 / (1024 * 1024))
    return max(1, int(number * factor))


def parse_cpu(value: object, default: int, warnings: list[str]) -> int:
    if value is None:
        return default
    try:
        return max(1, int(float(value) * 1000))
    except Exception:
        warn(warnings, f"unsupported cpu value {value!r}, using {default} MHz")
        return default


def load_compose(path: str, warnings: list[str]) -> dict[str, Any]:
    if path.endswith(".json"):
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    require_command("docker")
    try:
        result = run(["docker", "compose", "-f", path, "config", "--format", "json"], capture=True)
    except Exception as exc:
        raise CLIError("compose convert requires Docker Compose for YAML input") from exc
    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise CLIError("docker compose did not return valid JSON") from exc


def normalize_environment(value: object, warnings: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    if value is None:
        return env
    if isinstance(value, dict):
        for key, val in value.items():
            env[str(key)] = "" if val is None else str(val)
        return env
    if isinstance(value, list):
        for item in value:
            if "=" in str(item):
                key, val = str(item).split("=", 1)
                env[key] = val
        return env
    warn(warnings, f"unsupported environment format: {value!r}")
    return env


def read_compose_env_file(base_dir: Path, item: object, warnings: list[str]) -> dict[str, str]:
    path = Path(str(item))
    if not path.is_absolute():
        path = base_dir / path
    env: dict[str, str] = {}
    if not path.exists():
        warn(warnings, f"env_file not found: {path}")
        return env
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" in line:
                key, val = line.split("=", 1)
                env[key] = val
    return env


def env_from_service(base_dir: Path, service: dict[str, Any], warnings: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    env_file = service.get("env_file")
    if isinstance(env_file, str):
        env.update(read_compose_env_file(base_dir, env_file, warnings))
    elif isinstance(env_file, list):
        for item in env_file:
            path = item.get("path") if isinstance(item, dict) else item
            if path:
                env.update(read_compose_env_file(base_dir, path, warnings))
    env.update(normalize_environment(service.get("environment"), warnings))
    return env


def normalize_command(value: object) -> tuple[str | None, list[str]]:
    if value is None:
        return None, []
    if isinstance(value, list):
        if not value:
            return None, []
        return str(value[0]), [str(item) for item in value[1:]]
    return None, [str(value)]


def parse_port_item(item: object, index: int, warnings: list[str]) -> dict[str, Any] | None:
    if isinstance(item, dict):
        target = item.get("target")
        published = item.get("published")
        protocol = item.get("protocol", "tcp")
    else:
        text = str(item)
        protocol = "tcp"
        if "/" in text:
            text, protocol = text.rsplit("/", 1)
        pieces = text.split(":")
        if len(pieces) == 1:
            target = pieces[0]
            published = None
        elif len(pieces) == 2:
            published, target = pieces
        else:
            published, target = pieces[-2], pieces[-1]
    if target is None:
        warn(warnings, f"skip unsupported port item: {item!r}")
        return None
    protocol = parse_port_protocol_or_warn(protocol, f"port protocol in {item!r}", warnings)
    target_int = parse_port_number_or_warn(target, f"target port in {item!r}", warnings)
    if protocol is None or target_int is None:
        return None
    static_int = None
    if published not in (None, ""):
        static_int = parse_port_number_or_warn(published, f"published port in {item!r}", warnings)
        if static_int is None:
            return None
    name = "http" if target_int in (80, 8080) and index == 1 else f"p{target_int}"
    return {
        "name": sanitize_name(name),
        "to": target_int,
        "static": static_int,
        "protocol": protocol,
    }


def parse_volume_item(item: object, service_name: str, volume_root: str | None, warnings: list[str]) -> dict[str, Any] | None:
    readonly = False
    source = None
    target = None
    mount_type = "volume"
    if isinstance(item, dict):
        mount_type = str(item.get("type", "volume"))
        source = item.get("source")
        target = item.get("target")
        readonly = bool(item.get("read_only", False))
    else:
        fields = str(item).split(":")
        if len(fields) < 2:
            warn(warnings, f"skip unsupported volume item in {service_name}: {item!r}")
            return None
        source, target = fields[0], fields[1]
        if len(fields) >= 3:
            readonly = "ro" in fields[2].split(",")
        mount_type = "bind" if str(source).startswith(("/", ".")) else "volume"
    if not target:
        warn(warnings, f"skip volume without target in {service_name}: {item!r}")
        return None
    if mount_type == "bind":
        return {"type": "bind", "source": source or "", "target": target, "readonly": readonly}
    if volume_root and source:
        return {"type": "bind", "source": str(Path(volume_root) / str(source)), "target": target, "readonly": readonly}
    if source:
        return {"type": "volume", "source": source, "target": target, "readonly": readonly}
    warn(warnings, f"skip anonymous volume in {service_name}: {item!r}")
    return None


def resources_from_service(service: dict[str, Any], args: argparse.Namespace, warnings: list[str]) -> tuple[int, int]:
    deploy = service.get("deploy") or {}
    resources = deploy.get("resources") or {}
    limits = resources.get("limits") or {}
    cpus = limits.get("cpus") or service.get("cpus")
    memory = limits.get("memory") or service.get("mem_limit")
    return parse_cpu(cpus, args.cpu_default, warnings), parse_memory(memory, args.memory_default, warnings)


def emit_compose_service_group(
    lines: list[str],
    name: str,
    service: dict[str, Any],
    base_dir: Path,
    args: argparse.Namespace,
    warnings: list[str],
) -> None:
    group = sanitize_name(name)
    image = service.get("image")
    if not image:
        warn(warnings, f"service {name} has no image; build-only services are not converted")
        return
    replicas = (service.get("deploy") or {}).get("replicas")
    if replicas is None:
        replicas = 1
    replicas = parse_non_negative_int_or_warn(replicas, f"replicas for service {name}", 1, warnings)
    ports = [port for index, item in enumerate(service.get("ports") or [], 1) if (port := parse_port_item(item, index, warnings))]
    volumes = [volume for item in service.get("volumes") or [] if (volume := parse_volume_item(item, name, args.volume_root, warnings))]
    env = env_from_service(base_dir, service, warnings)
    command, command_args = normalize_command(service.get("command"))
    entrypoint = service.get("entrypoint")
    cpu, memory = resources_from_service(service, args, warnings)
    if service.get("depends_on"):
        warn(warnings, f"service {name}: depends_on is not converted; rely on service checks and application retries")
    if service.get("healthcheck"):
        warn(warnings, f"service {name}: healthcheck is not automatically converted")
    if service.get("build"):
        warn(warnings, f"service {name}: build is ignored; build and push image before running Nomad job")
    lines.append("")
    lines.append(f"  group {hcl_string(group)} {{")
    lines.append(f"    count = {int(replicas)}")
    if ports:
        lines.append("")
        lines.append("    network {")
        for port in ports:
            lines.append(f"      port {hcl_string(port['name'])} {{")
            if port["static"] is not None:
                lines.append(f"        static = {port['static']}")
            lines.append(f"        to = {port['to']}")
            lines.append("      }")
        lines.append("    }")
    lines.append("")
    lines.append(f"    task {hcl_string(group)} {{")
    lines.append('      driver = "docker"')
    lines.append("")
    lines.append("      config {")
    lines.append(f"        image = {hcl_string(image)}")
    if isinstance(entrypoint, list) and entrypoint:
        lines.append(f"        entrypoint = {hcl_list([str(item) for item in entrypoint])}")
    elif isinstance(entrypoint, str):
        lines.append(f"        entrypoint = {hcl_list([entrypoint])}")
    if command:
        lines.append(f"        command = {hcl_string(command)}")
    if command_args:
        lines.append(f"        args = {hcl_list(command_args)}")
    if ports:
        lines.append(f"        ports = {hcl_list([p['name'] for p in ports])}")
    for volume in volumes:
        lines.append("")
        lines.append("        mount {")
        lines.append(f"          type = {hcl_string(volume['type'])}")
        lines.append(f"          source = {hcl_string(volume['source'])}")
        lines.append(f"          target = {hcl_string(volume['target'])}")
        lines.append(f"          readonly = {hcl_bool(volume['readonly'])}")
        lines.append("        }")
    lines.append("      }")
    if env:
        lines.append("")
        lines.append("      env {")
        for key, value in sorted(env.items()):
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                lines.append(f"        {key} = {hcl_string(value)}")
            else:
                warn(warnings, f"service {name}: skip invalid env key {key!r}")
        lines.append("      }")
    lines.append("")
    lines.append("      resources {")
    lines.append(f"        cpu    = {cpu}")
    lines.append(f"        memory = {memory}")
    lines.append("      }")
    if ports:
        lines.append("")
        lines.append("      service {")
        lines.append(f"        name = {hcl_string(group)}")
        lines.append(f"        provider = {hcl_string(args.service_provider)}")
        lines.append(f"        port = {hcl_string(ports[0]['name'])}")
        lines.append("      }")
    lines.append("    }")
    lines.append("  }")


def build_compose_hcl(compose: dict[str, Any], path: str, args: argparse.Namespace, warnings: list[str]) -> str:
    services = compose.get("services") or {}
    if not services:
        raise CLIError("Compose file has no services")
    job_name = sanitize_name(args.job or compose.get("name") or Path(path).resolve().parent.name)
    lines = [
        "# Generated by nomad-job compose convert",
        "# Review warnings below before applying.",
        f"job {hcl_string(job_name)} {{",
        f"  type = {hcl_string(args.type)}",
        f"  datacenters = {hcl_list(parse_csv(args.datacenters))}",
    ]
    if args.namespace:
        lines.append(f"  namespace = {hcl_string(args.namespace)}")
    if args.region:
        lines.append(f"  region = {hcl_string(args.region)}")
    lines.extend(["", "  update {", "    max_parallel     = 1", '    min_healthy_time = "10s"', '    healthy_deadline = "3m"', "    auto_revert      = true", "  }"])
    base_dir = Path(path).resolve().parent
    for name, service in services.items():
        emit_compose_service_group(lines, name, service or {}, base_dir, args, warnings)
    lines.append("}")
    lines.append("")
    if warnings:
        warning_lines = ["# Warnings:"]
        warning_lines.extend(f"# - {item}" for item in warnings)
        warning_lines.append("")
        lines = warning_lines + lines
    return "\n".join(lines)


def cmd_compose_convert(args: argparse.Namespace) -> int:
    warnings: list[str] = []
    validate_positive_int(args.cpu_default, "default CPU reservation")
    validate_positive_int(args.memory_default, "default memory reservation")
    compose = load_compose(args.compose_file, warnings)
    content = build_compose_hcl(compose, args.compose_file, args, warnings)
    for item in warnings:
        log_warn(item)
    if args.strict and warnings:
        raise CLIError("Compose conversion has warnings; rerun without --strict to emit best-effort HCL")
    write_output(args.out, content, args.force)
    sys.stdout.flush()
    log_compose_guidance(content)
    return 0


def nomad_target_summary() -> str:
    address = os.environ.get("NOMAD_ADDR") or "http://127.0.0.1:4646 (default)"
    namespace = os.environ.get("NOMAD_NAMESPACE") or "default"
    region = os.environ.get("NOMAD_REGION") or "global"
    token = "set" if os.environ.get("NOMAD_TOKEN") else "not set"
    return f"address={address}, namespace={namespace}, region={region}, token={token}"


def log_nomad_target(job_file: str | None = None) -> None:
    message = f"Nomad target: {nomad_target_summary()}"
    if job_file:
        message += f", job_file={Path(job_file).resolve()}"
    log_info(message)


def validate_job_file(file_name: str) -> None:
    if not file_name:
        raise CLIError("Missing JOB_FILE")
    if not Path(file_name).is_file():
        raise CLIError(f"JOB_FILE not found: {file_name}")
    require_command("nomad")
    log_info(f"Validating Nomad job file: {file_name}")
    run(["nomad", "job", "validate", file_name])


def cmd_validate(args: argparse.Namespace) -> int:
    validate_job_file(args.job_file)
    return 0


def normalize_nomad_args(nomad_args: list[str] | None) -> list[str]:
    extra = list(nomad_args or [])
    if extra and extra[0] == "--":
        extra = extra[1:]
    return extra


def run_plan(job_file: str, nomad_args: list[str] | None, *, validate: bool) -> int:
    if validate:
        validate_job_file(job_file)
    extra = normalize_nomad_args(nomad_args)
    log_nomad_target(job_file)
    log_info(f"Planning Nomad job file: {job_file}")
    result = run(["nomad", "job", "plan", *extra, job_file], check=False)
    return 0 if result.returncode in (0, 1) else result.returncode


def cmd_plan(args: argparse.Namespace) -> int:
    return run_plan(args.job_file, args.nomad_args, validate=True)


def cmd_apply(args: argparse.Namespace) -> int:
    validate_job_file(args.job_file)
    plan_result = run_plan(args.job_file, getattr(args, "nomad_args", []), validate=False)
    if plan_result != 0:
        return plan_result
    if not args.auto_approve:
        answer = input(f"Run nomad job run for {args.job_file}? Type yes to continue: ")
        if answer != "yes":
            raise CLIError("Apply cancelled")
    run_args: list[str] = []
    if args.detach:
        run_args.append("-detach")
    if args.check_index:
        run_args.append(f"-check-index={args.check_index}")
    log_info(f"Running Nomad job file: {args.job_file}")
    run(["nomad", "job", "run", *run_args, args.job_file])
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    require_command("nomad")
    log_nomad_target()
    if args.job:
        log_info(f"Showing Nomad job status: {args.job}")
        run(["nomad", "job", "status", args.job])
    else:
        log_info("Showing Nomad job status list")
        run(["nomad", "job", "status"])
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    require_command("nomad")
    command = ["nomad", "job", "stop"]
    if args.purge:
        command.append("-purge")
    command.append(args.job)
    log_nomad_target()
    log_info(f"Stopping Nomad job: {args.job}")
    run(command)
    return 0


def cmd_quickstart(_: argparse.Namespace) -> int:
    print(
        """Nomad job quickstart:
  1. Generate a Docker job:
     nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl

  2. Review and validate:
     nomad-job validate jobs/web.nomad.hcl

  3. Preview the scheduler changes:
     nomad-job plan jobs/web.nomad.hcl

  4. Apply after review:
     nomad-job apply jobs/web.nomad.hcl

  5. Inspect and stop:
     nomad-job status web
     nomad-job stop web
"""
    )
    return 0


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    topics = {
        "overview": """Nomad job tutor:
  Purpose:
    Generate, review and operate Nomad job files.

  Common path:
    nomad-job quickstart
    nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl
    nomad-job validate jobs/web.nomad.hcl
    nomad-job plan jobs/web.nomad.hcl
    nomad-job apply jobs/web.nomad.hcl

  Topics:
    docker, compose, vault, volume, lifecycle, troubleshoot, web-service, private-image, service-update, batch
""",
        "docker": "Start with a Docker job:\n  nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl",
        "compose": "Use Docker Compose as an intermediate parser:\n  nomad-job compose convert docker-compose.yml --out jobs/app.nomad.hcl",
        "vault": "Prepare workload identity first:\n  nomad-manager vault-jwt apply --profile default ...\n  nomad-job scaffold docker ... --vault-role nomad-workloads --template-file app.ctmpl:secrets/app.env:env",
        "volume": "Use Docker mounts or managed host volumes:\n  nomad-manager host-volume add logs --create\n  nomad-job scaffold docker ... --host-volume logs:/var/log/app:rw",
        "lifecycle": "Run a review loop:\n  nomad-job validate jobs/web.nomad.hcl\n  nomad-job plan jobs/web.nomad.hcl\n  nomad-job apply jobs/web.nomad.hcl\n  nomad-job status web",
        "troubleshoot": "Inspect job and allocation state:\n  nomad-job status web\n  nomad alloc status <alloc-id>\n  nomad alloc logs <alloc-id>",
        "web-service": "Generate an HTTP service:\n  nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --check-http /health --out jobs/web.nomad.hcl",
        "private-image": "Configure registry auth before running private images:\n  nomad-manager docker enable --auth-config /root/.docker/config.json",
        "service-update": "Regenerate the HCL with a new image tag, then review and apply:\n  nomad-job plan jobs/web.nomad.hcl\n  nomad-job apply jobs/web.nomad.hcl",
        "batch": "Generate a one-shot task:\n  nomad-job scaffold docker --type batch --no-service --job backup --image alpine:3.20 --command sh --arg -c --arg 'echo ok'",
    }
    if topic not in topics:
        raise CLIError(f"Unknown tutor topic: {topic}")
    print(topics[topic])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = CLIArgumentParser(
        prog="nomad-job",
        description="Generate, validate and run Nomad job files.",
        epilog="""Examples:
  nomad-job quickstart
  nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl
  nomad-job validate jobs/web.nomad.hcl
  nomad-job plan jobs/web.nomad.hcl -- -namespace default
  nomad-job apply jobs/web.nomad.hcl
""",
    )
    subparsers = parser.add_subparsers(dest="command")
    parser.set_defaults(func=lambda _: missing_subcommand(parser, "nomad-job"))

    scaffold = subparsers.add_parser(
        "scaffold",
        help="Generate Nomad job HCL",
        description="Generate Nomad job HCL from explicit command-line options.",
    )
    scaffold_sub = scaffold.add_subparsers(dest="scaffold_command")
    scaffold.set_defaults(func=lambda _: missing_subcommand(scaffold, "nomad-job scaffold"))
    docker = scaffold_sub.add_parser(
        "docker",
        help="Generate a Docker task job",
        description="Generate a single-group Nomad job using the Docker driver.",
        epilog="""Format examples:
  --port http:8080:80        static host port 8080 to container port 80
  --port http:80             dynamic host port to container port 80
  --mount bind:/srv/app:/app:ro
  --host-volume logs:/var/log/app:rw
  --template-file app.ctmpl:secrets/app.env:env
  --interactive              prompt for missing and common options
""",
    )
    docker.add_argument("--interactive", action="store_true", help="Prompt for missing and common scaffold options")
    docker.add_argument("--job", help="Nomad job name")
    docker.add_argument("--image", help="Docker image reference")
    docker.add_argument("--out", help="Output HCL path, or '-' for stdout")
    docker.add_argument("--force", action="store_true", help="Overwrite an existing output file")
    docker.add_argument("--type", choices=["service", "batch"], default="service", help="Nomad job type")
    docker.add_argument("--datacenters", default="dc1", help="Comma-separated Nomad datacenters")
    docker.add_argument("--namespace", help="Nomad namespace to write into the job file")
    docker.add_argument("--region", help="Nomad region to write into the job file")
    docker.add_argument("--group", help="Task group name; defaults to --job")
    docker.add_argument("--task", help="Task name; defaults to --group")
    docker.add_argument("--count", type=parse_positive_int_argument, default=1, help="Task group count")
    docker.add_argument("--cpu", type=parse_positive_int_argument, default=500, help="CPU reservation in MHz")
    docker.add_argument("--memory", type=parse_positive_int_argument, default=256, help="Memory reservation in MB")
    docker.add_argument("--command", help="Docker command override")
    docker.add_argument("--arg", action="append", help="Docker command argument; repeat for multiple args")
    docker.add_argument("--env", action="append", help="Environment variable in KEY=VALUE format")
    docker.add_argument("--env-file", action="append", help="File containing KEY=VALUE environment lines")
    docker.add_argument("--port", action="append", help="Port spec name:to[/proto] or name:static:to[/proto]")
    docker.add_argument("--mount", action="append", help="Mount spec bind:source:target[:ro|rw], volume:name:target[:ro|rw], or tmpfs:target[:ro|rw]")
    docker.add_argument("--host-volume", action="append", help="Host volume spec name:destination[:ro|rw]")
    docker.add_argument("--service-name", help="Nomad service name; defaults to --job")
    docker.add_argument("--service-provider", choices=["nomad", "consul"], default="nomad", help="Service registration provider")
    docker.add_argument("--no-service", dest="emit_service", action="store_false", help="Do not emit a service block")
    docker.set_defaults(emit_service=True, func=cmd_scaffold_docker)
    docker.add_argument("--check-http", help="HTTP health check path, for example /health")
    docker.add_argument("--check-tcp", action="store_true", help="Emit a TCP health check")
    docker.add_argument("--check-interval", default="10s", help="Health check interval")
    docker.add_argument("--check-timeout", default="2s", help="Health check timeout")
    docker.add_argument("--vault-role", help="Vault role for Nomad workload identity")
    docker.add_argument("--vault-cluster", default="default", help="Nomad Vault cluster name")
    docker.add_argument("--identity-aud", help="Comma-separated workload identity audiences")
    docker.add_argument("--identity-ttl", default="1h", help="Workload identity token TTL")
    docker.add_argument("--template-file", action="append", help="Template spec source:destination[:env]")

    compose = subparsers.add_parser(
        "compose",
        help="Convert Docker Compose to Nomad HCL",
        description="Convert Docker Compose services into Nomad HCL for review.",
    )
    compose_sub = compose.add_subparsers(dest="compose_command")
    compose.set_defaults(func=lambda _: missing_subcommand(compose, "nomad-job compose"))
    convert = compose_sub.add_parser("convert", help="Convert a Compose file")
    convert.add_argument("compose_file", help="Docker Compose YAML or JSON file")
    convert.add_argument("--out", default="-", help="Output HCL path, or '-' for stdout")
    convert.add_argument("--force", action="store_true", help="Overwrite an existing output file")
    convert.add_argument("--job", help="Nomad job name; defaults to compose name or directory name")
    convert.add_argument("--type", choices=["service", "batch"], default="service", help="Nomad job type")
    convert.add_argument("--datacenters", default="dc1", help="Comma-separated Nomad datacenters")
    convert.add_argument("--namespace", help="Nomad namespace to write into the job file")
    convert.add_argument("--region", help="Nomad region to write into the job file")
    convert.add_argument("--volume-root", help="Directory used to map named Compose volumes into bind mounts")
    convert.add_argument("--cpu-default", type=parse_positive_int_argument, default=500, help="Default CPU reservation in MHz")
    convert.add_argument("--memory-default", type=parse_positive_int_argument, default=256, help="Default memory reservation in MB")
    convert.add_argument("--service-provider", choices=["nomad", "consul"], default="nomad", help="Service registration provider")
    convert.add_argument("--strict", action="store_true", help="Fail if conversion emits warnings")
    convert.set_defaults(func=cmd_compose_convert)

    validate = subparsers.add_parser("validate", help="Run nomad job validate")
    validate.add_argument("job_file", help="Nomad HCL job file")
    validate.set_defaults(func=cmd_validate)

    plan = subparsers.add_parser("plan", help="Run nomad job plan")
    plan.add_argument("job_file", help="Nomad HCL job file")
    plan.add_argument("nomad_args", nargs=argparse.REMAINDER, help="Extra arguments passed to 'nomad job plan' after '--'")
    plan.set_defaults(func=cmd_plan)

    apply = subparsers.add_parser(
        "apply",
        help="Validate, plan and run a Nomad job",
        epilog="""Examples:
  nomad-job apply jobs/web.nomad.hcl --auto-approve
  nomad-job apply jobs/web.nomad.hcl -- -namespace default
""",
    )
    apply.add_argument("job_file", help="Nomad HCL job file")
    apply.add_argument("--auto-approve", action="store_true", help="Skip the interactive confirmation")
    apply.add_argument("--detach", action="store_true", help="Pass -detach to 'nomad job run'")
    apply.add_argument("--check-index", help="Pass -check-index to 'nomad job run'")
    apply.set_defaults(func=cmd_apply, nomad_args=[])

    status = subparsers.add_parser("status", help="Show job status")
    status.add_argument("job", nargs="?", help="Optional job ID")
    status.set_defaults(func=cmd_status)

    stop = subparsers.add_parser("stop", help="Stop a job")
    stop.add_argument("job", help="Job ID to stop")
    stop.add_argument("--purge", action="store_true", help="Purge the job from Nomad")
    stop.set_defaults(func=cmd_stop)

    quickstart = subparsers.add_parser("quickstart", help="Show a copyable job workflow")
    quickstart.set_defaults(func=cmd_quickstart)

    tutor = subparsers.add_parser("tutor", help="Show short workflow guidance")
    tutor.add_argument("topic", nargs="?", help="Topic name")
    tutor.set_defaults(func=cmd_tutor)
    return parser


def dispatch(argv: list[str]) -> int:
    parser = build_parser()
    if argv and argv[0] == "help":
        argv = ["--help", *argv[1:]]
    nomad_args: list[str] | None = None
    parse_argv = argv
    if argv and argv[0] == "apply" and "--" in argv:
        delimiter_index = argv.index("--")
        parse_argv = argv[:delimiter_index]
        nomad_args = argv[delimiter_index + 1 :]
    args = parser.parse_args(parse_argv)
    if nomad_args is not None:
        args.nomad_args = nomad_args
    return int(args.func(args))


def main(argv: list[str] | None = None) -> int:
    ensure_default_path()
    config = AuditConfig("nomad-job", AUDIT_LOG_FILE)
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
