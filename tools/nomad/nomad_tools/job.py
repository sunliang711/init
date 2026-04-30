from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from .common import (
    AuditConfig,
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
    validate_name,
)


NOMAD_ROOT_DIR = Path("/opt/nomad")
TOOL_LOG_DIR = NOMAD_ROOT_DIR / "log" / "nomad-init-tools"
AUDIT_LOG_FILE = TOOL_LOG_DIR / "job.audit.log"


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
    proto = pieces[1] if len(pieces) == 2 else "tcp"
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
        "static": int(static) if static else None,
        "to": int(to),
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
        lines.append("")
        lines.append(f"{indent}  template {{")
        lines.append(f"{indent}    destination = {hcl_string(template['destination'])}")
        lines.append(f"{indent}    env         = {hcl_bool(template['env'])}")
        lines.append(f"{indent}    data = <<EOH")
        lines.append(str(template["data"]).rstrip("\n"))
        lines.append("EOH")
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


def cmd_scaffold_docker(args: argparse.Namespace) -> int:
    args.group = args.group or args.job
    args.task = args.task or args.group
    write_output(args.out, build_scaffold_hcl(args), args.force)
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
    target_int = int(str(target))
    name = "http" if target_int in (80, 8080) and index == 1 else f"p{target_int}"
    return {
        "name": sanitize_name(name),
        "to": target_int,
        "static": int(str(published)) if published not in (None, "") else None,
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
    replicas = ((service.get("deploy") or {}).get("replicas") or 1)
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
    compose = load_compose(args.compose_file, warnings)
    write_output(args.out, build_compose_hcl(compose, args.compose_file, args, warnings), args.force)
    for item in warnings:
        log_warn(item)
    return 0


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


def cmd_plan(args: argparse.Namespace) -> int:
    validate_job_file(args.job_file)
    extra = args.nomad_args or []
    if extra and extra[0] == "--":
        extra = extra[1:]
    log_info(f"Planning Nomad job file: {args.job_file}")
    result = run(["nomad", "job", "plan", *extra, args.job_file], check=False)
    return 0 if result.returncode in (0, 1) else result.returncode


def cmd_apply(args: argparse.Namespace) -> int:
    validate_job_file(args.job_file)
    plan_result = cmd_plan(argparse.Namespace(job_file=args.job_file, nomad_args=[]))
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
    log_info(f"Stopping Nomad job: {args.job}")
    run(command)
    return 0


def cmd_tutor(args: argparse.Namespace) -> int:
    topic = args.topic or "overview"
    topics = {
        "overview": "Use scaffold/compose to generate HCL, validate and plan it, then apply reviewed jobs.",
        "docker": "Start with: nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --out jobs/web.nomad.hcl",
        "compose": "Use Docker Compose as an intermediate parser: nomad-job compose convert docker-compose.yml --out jobs/app.nomad.hcl",
        "vault": "Use nomad-manager vault-jwt apply first, then add --vault-role and --template-file to generated jobs.",
        "volume": "Use --mount for Docker mounts, or --host-volume after nomad-manager host-volume add.",
        "lifecycle": "Run validate, plan, apply, status and stop as a review loop.",
        "troubleshoot": "Inspect nomad job status, alloc status, alloc logs and node status.",
        "web-service": "Generate an HTTP service with --port and --check-http, then validate, plan and apply it.",
        "private-image": "Configure registry auth with nomad-manager docker enable --auth-config before running private images.",
        "service-update": "Regenerate the HCL with a new image tag, run plan, then apply.",
        "batch": "Use --type batch --no-service for one-shot tasks.",
    }
    if topic not in topics:
        raise CLIError(f"Unknown tutor topic: {topic}")
    print(topics[topic])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nomad-job", description="Generate, validate and run Nomad job files.")
    subparsers = parser.add_subparsers(dest="command")

    scaffold = subparsers.add_parser("scaffold", help="Generate Nomad job HCL")
    scaffold_sub = scaffold.add_subparsers(dest="scaffold_command")
    docker = scaffold_sub.add_parser("docker", help="Generate a Docker task job")
    docker.add_argument("--job", required=True)
    docker.add_argument("--image", required=True)
    docker.add_argument("--out", default="-")
    docker.add_argument("--force", action="store_true")
    docker.add_argument("--type", choices=["service", "batch"], default="service")
    docker.add_argument("--datacenters", default="dc1")
    docker.add_argument("--namespace")
    docker.add_argument("--region")
    docker.add_argument("--group")
    docker.add_argument("--task")
    docker.add_argument("--count", type=int, default=1)
    docker.add_argument("--cpu", type=int, default=500)
    docker.add_argument("--memory", type=int, default=256)
    docker.add_argument("--command")
    docker.add_argument("--arg", action="append")
    docker.add_argument("--env", action="append")
    docker.add_argument("--env-file", action="append")
    docker.add_argument("--port", action="append")
    docker.add_argument("--mount", action="append")
    docker.add_argument("--host-volume", action="append")
    docker.add_argument("--service-name")
    docker.add_argument("--service-provider", choices=["nomad", "consul"], default="nomad")
    docker.add_argument("--no-service", dest="emit_service", action="store_false")
    docker.set_defaults(emit_service=True, func=cmd_scaffold_docker)
    docker.add_argument("--check-http")
    docker.add_argument("--check-tcp", action="store_true")
    docker.add_argument("--check-interval", default="10s")
    docker.add_argument("--check-timeout", default="2s")
    docker.add_argument("--vault-role")
    docker.add_argument("--vault-cluster", default="default")
    docker.add_argument("--identity-aud")
    docker.add_argument("--identity-ttl", default="1h")
    docker.add_argument("--template-file", action="append")

    compose = subparsers.add_parser("compose", help="Convert Docker Compose to Nomad HCL")
    compose_sub = compose.add_subparsers(dest="compose_command")
    convert = compose_sub.add_parser("convert", help="Convert a Compose file")
    convert.add_argument("compose_file")
    convert.add_argument("--out", default="-")
    convert.add_argument("--force", action="store_true")
    convert.add_argument("--job")
    convert.add_argument("--type", choices=["service", "batch"], default="service")
    convert.add_argument("--datacenters", default="dc1")
    convert.add_argument("--namespace")
    convert.add_argument("--region")
    convert.add_argument("--volume-root")
    convert.add_argument("--cpu-default", type=int, default=500)
    convert.add_argument("--memory-default", type=int, default=256)
    convert.add_argument("--service-provider", choices=["nomad", "consul"], default="nomad")
    convert.set_defaults(func=cmd_compose_convert)

    validate = subparsers.add_parser("validate", help="Run nomad job validate")
    validate.add_argument("job_file")
    validate.set_defaults(func=cmd_validate)

    plan = subparsers.add_parser("plan", help="Run nomad job plan")
    plan.add_argument("job_file")
    plan.add_argument("nomad_args", nargs=argparse.REMAINDER)
    plan.set_defaults(func=cmd_plan)

    apply = subparsers.add_parser("apply", help="Validate, plan and run a Nomad job")
    apply.add_argument("job_file")
    apply.add_argument("--auto-approve", action="store_true")
    apply.add_argument("--detach", action="store_true")
    apply.add_argument("--check-index")
    apply.set_defaults(func=cmd_apply)

    status = subparsers.add_parser("status", help="Show job status")
    status.add_argument("job", nargs="?")
    status.set_defaults(func=cmd_status)

    stop = subparsers.add_parser("stop", help="Stop a job")
    stop.add_argument("job")
    stop.add_argument("--purge", action="store_true")
    stop.set_defaults(func=cmd_stop)

    tutor = subparsers.add_parser("tutor", help="Show short workflow guidance")
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
    config = AuditConfig("nomad-job", AUDIT_LOG_FILE)
    return run_with_audit(config, sys.argv[1:] if argv is None else argv, dispatch)
