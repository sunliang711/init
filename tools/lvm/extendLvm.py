#!/usr/bin/env python3
"""Safely extend an LVM logical volume with a new disk."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import shlex
import stat
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional, Sequence


SUPPORTED_FS_TYPES = {"auto", "ext2", "ext3", "ext4", "xfs"}
RESIZABLE_EXT_TYPES = {"ext2", "ext3", "ext4"}
USAGE_TEXT = """Usage:
  extendLvm.py add [options] /dev/DISK /dev/VG/LV

Options:
  --vg VG_NAME             Require the target LV to belong to this VG.
  --fs-type TYPE           Filesystem type: auto, ext2, ext3, ext4, xfs. Default: auto.
  --dry-run                Print the execution plan without changing disks.
  --yes                    Execute without interactive confirmation.
  --force                  Allow overwriting a disk that already has partitions.
  -h, --help               Show this help.

Examples:
  extendLvm.py add --dry-run /dev/sdb /dev/vg0/root
  extendLvm.py add --yes --fs-type xfs /dev/nvme1n1 /dev/vg0/data
"""


@dataclass(frozen=True)
class AddConfig:
    disk: str
    lv_path: str
    vg_name: str
    fs_type: str
    partition_path: str
    mountpoint: str
    dry_run: bool
    yes: bool
    force: bool


class CommandError(RuntimeError):
    pass


class Runner:
    def __init__(self, dry_run: bool) -> None:
        self.dry_run = dry_run

    def run(self, args: Sequence[str]) -> None:
        log_command(args)
        if self.dry_run:
            return
        subprocess.run(args, check=True)

    def capture(self, args: Sequence[str], allow_failure: bool = False) -> str:
        try:
            completed = subprocess.run(
                args,
                check=not allow_failure,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except subprocess.CalledProcessError as exc:
            raise CommandError(f"Command failed: {shlex.join(args)}") from exc

        if allow_failure and completed.returncode != 0:
            return ""
        return completed.stdout


def log(message: str) -> None:
    sys.stdout.write(f"{message}\n")


def die(message: str) -> None:
    sys.stderr.write(f"ERROR: {message}\n")
    raise SystemExit(1)


def print_add_usage() -> None:
    sys.stderr.write(USAGE_TEXT)


def capture_optional(args: Sequence[str]) -> str:
    if shutil.which(args[0]) is None:
        return ""
    completed = subprocess.run(
        args,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        return ""
    return completed.stdout


def print_available_disks() -> None:
    sys.stderr.write("\nAvailable unused disks:\n")
    if shutil.which("lsblk") is None:
        sys.stderr.write("  lsblk is not available.\n")
        return

    output = capture_optional(["lsblk", "-dnrpo", "NAME,SIZE,RO,RM,TYPE,MODEL"])
    available: list[str] = []
    unavailable: list[str] = []
    for line in output.splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) < 5 or fields[4] != "disk":
            continue

        name = fields[0]
        size = fields[1]
        ro = fields[2]
        rm = fields[3]
        model = fields[5] if len(fields) > 5 else "unknown"
        reasons = disk_unavailable_reasons(name, ro, rm)
        if reasons:
            unavailable.append(f"  {name}  {size}  {model}  ({', '.join(reasons)})")
        else:
            available.append(f"  {name}  {size}  {model}")

    if available:
        for line in available:
            sys.stderr.write(f"{line}\n")
    else:
        sys.stderr.write("  No unused disks found.\n")

    if unavailable:
        sys.stderr.write("\nUnavailable disks:\n")
        for line in unavailable:
            sys.stderr.write(f"{line}\n")


def list_disk_children_optional(disk: str) -> list[str]:
    output = capture_optional(["lsblk", "-nrpo", "NAME", disk])
    names = [line.strip() for line in output.splitlines() if line.strip()]
    return names[1:]


def has_mountpoint_optional(path: str) -> bool:
    output = capture_optional(["lsblk", "-nrpo", "MOUNTPOINT", path])
    return any(line.strip() for line in output.splitlines())


def is_lvm_pv_optional(path: str) -> bool:
    output = capture_optional(["pvs", "--noheadings", path])
    return bool(output.strip())


def disk_unavailable_reasons(disk: str, ro: str, rm: str) -> list[str]:
    reasons: list[str] = []

    if ro == "1":
        reasons.append("read-only")
    if rm == "1":
        reasons.append("removable")
    if has_mountpoint_optional(disk):
        reasons.append("mounted")
    if is_lvm_pv_optional(disk):
        reasons.append("lvm-pv")

    children = list_disk_children_optional(disk)
    if children:
        reasons.append("has-partitions")
        if any(has_mountpoint_optional(child) for child in children):
            reasons.append("mounted-child")
        if any(is_lvm_pv_optional(child) for child in children):
            reasons.append("lvm-pv-child")

    return reasons


def print_available_lvs() -> None:
    sys.stderr.write("\nAvailable logical volumes:\n")
    if shutil.which("lvs") is None:
        sys.stderr.write("  lvs is not available.\n")
        return

    output = capture_optional(["lvs", "--noheadings", "-o", "lv_path,vg_name,lv_size"])
    found = False
    for line in output.splitlines():
        if line.strip():
            sys.stderr.write(f"  {line}\n")
            found = True
    if not found:
        sys.stderr.write("  No logical volumes found.\n")


def require_add_arguments(args: argparse.Namespace) -> None:
    if not args.disk:
        print_add_usage()
        print_available_disks()
        die("Missing /dev/DISK.")
    if not args.lv_path:
        print_add_usage()
        print_available_lvs()
        die("Missing /dev/VG/LV.")


def log_command(args: Sequence[str]) -> None:
    log(f"+ {shlex.join(args)}")


def require_linux() -> None:
    if platform.system() != "Linux":
        die("Linux is required.")


def require_root_for_write(dry_run: bool) -> None:
    if not dry_run and os.geteuid() != 0:
        die("Root privilege is required when not using --dry-run.")


def require_command(name: str) -> None:
    if shutil.which(name) is None:
        die(f"Command is required: {name}")


def require_commands(names: Sequence[str]) -> None:
    for name in names:
        require_command(name)


def is_block_device(path: str) -> bool:
    try:
        mode = os.stat(path).st_mode
    except FileNotFoundError:
        return False
    return stat.S_ISBLK(mode)


def list_child_partitions(runner: Runner, disk: str) -> list[str]:
    output = runner.capture(["lsblk", "-nrpo", "NAME", disk])
    names = [line.strip() for line in output.splitlines() if line.strip()]
    return names[1:]


def has_mountpoint(runner: Runner, path: str) -> bool:
    output = runner.capture(["lsblk", "-nrpo", "MOUNTPOINT", path], allow_failure=True)
    return any(line.strip() for line in output.splitlines())


def is_lvm_pv(runner: Runner, path: str) -> bool:
    output = runner.capture(["pvs", "--noheadings", path], allow_failure=True)
    return bool(output.strip())


def predict_partition_path(disk: str) -> str:
    name = os.path.basename(disk)
    if name.startswith("nvme") or name.startswith("mmcblk") or name.startswith("loop"):
        return f"{disk}p1"
    return f"{disk}1"


def resolve_lv_vg(runner: Runner, lv_path: str, expected_vg: str) -> str:
    output = runner.capture(["lvs", "--noheadings", "-o", "vg_name", lv_path], allow_failure=True)
    vg_name = first_word(output)
    if not vg_name:
        print_add_usage()
        print_available_lvs()
        die(f"Cannot find LV: {lv_path}")

    if expected_vg and expected_vg != vg_name:
        print_available_lvs()
        die(f"LV {lv_path} belongs to VG {vg_name}, not {expected_vg}.")

    return vg_name


def first_word(output: str) -> str:
    for line in output.splitlines():
        words = line.split()
        if words:
            return words[0]
    return ""


def detect_filesystem_type(runner: Runner, lv_path: str, fs_type: str) -> str:
    if fs_type != "auto":
        return fs_type

    output = runner.capture(["findmnt", "-rn", "-o", "FSTYPE", "--source", lv_path], allow_failure=True)
    detected = first_word(output)
    if detected:
        return detected

    output = runner.capture(["blkid", "-s", "TYPE", "-o", "value", lv_path], allow_failure=True)
    detected = first_word(output)
    if detected:
        return detected

    die(f"Cannot detect filesystem type for {lv_path}. Use --fs-type.")


def get_mountpoint(runner: Runner, lv_path: str) -> str:
    output = runner.capture(["findmnt", "-rn", "-o", "TARGET", "--source", lv_path], allow_failure=True)
    return first_word(output)


def require_resize_command(fs_type: str) -> None:
    if fs_type in RESIZABLE_EXT_TYPES:
        require_command("resize2fs")
        return
    if fs_type == "xfs":
        require_command("xfs_growfs")
        return
    die(f"Unsupported filesystem type for online resize: {fs_type}")


def validate_disk(runner: Runner, disk: str, force: bool) -> None:
    if not is_block_device(disk):
        print_add_usage()
        print_available_disks()
        die(f"Disk is not a block device: {disk}")

    if has_mountpoint(runner, disk):
        die(f"Disk or its partitions are mounted: {disk}")

    if is_lvm_pv(runner, disk):
        die(f"Disk is already an LVM PV: {disk}")

    partitions = list_child_partitions(runner, disk)
    for partition in partitions:
        if has_mountpoint(runner, partition):
            die(f"Partition is mounted: {partition}")
        if is_lvm_pv(runner, partition):
            die(f"Partition is already an LVM PV: {partition}")

    if partitions and not force:
        die(f"Disk already has partitions. Re-run with --force to overwrite: {disk}")


def validate_partition_plan(partition_path: str, force: bool) -> None:
    if is_block_device(partition_path) and not force:
        die(f"Planned partition already exists. Re-run with --force to overwrite: {partition_path}")


def build_config(args: argparse.Namespace, runner: Runner) -> AddConfig:
    validate_disk(runner, args.disk, args.force)
    vg_name = resolve_lv_vg(runner, args.lv_path, args.vg_name)
    fs_type = detect_filesystem_type(runner, args.lv_path, args.fs_type)
    require_resize_command(fs_type)
    partition_path = predict_partition_path(args.disk)
    mountpoint = ""
    validate_partition_plan(partition_path, args.force)

    if fs_type == "xfs":
        mountpoint = get_mountpoint(runner, args.lv_path)
        if not mountpoint:
            die(f"XFS resize requires a mounted filesystem: {args.lv_path}")

    return AddConfig(
        disk=args.disk,
        lv_path=args.lv_path,
        vg_name=vg_name,
        fs_type=fs_type,
        partition_path=partition_path,
        mountpoint=mountpoint,
        dry_run=args.dry_run,
        yes=args.yes,
        force=args.force,
    )


def print_plan(config: AddConfig) -> None:
    log("Execution plan:")
    log(f"  disk: {config.disk}")
    log(f"  new partition: {config.partition_path}")
    log(f"  vg: {config.vg_name}")
    log(f"  lv: {config.lv_path}")
    log(f"  filesystem: {config.fs_type}")
    log(f"  dry-run: {int(config.dry_run)}")
    log(f"  force: {int(config.force)}")
    log("")
    log("Commands to run:")
    log_command(["parted", config.disk, "-a", "optimal", "-s", "mklabel", "gpt", "mkpart", "primary", "1MiB", "100%", "set", "1", "lvm", "on"])
    log_command(["partprobe", config.disk])
    if shutil.which("udevadm") is not None:
        log_command(["udevadm", "settle"])
    log_command(["pvcreate", config.partition_path])
    log_command(["vgextend", config.vg_name, config.partition_path])
    log_command(["lvextend", "-l", "+100%FREE", config.lv_path])
    if config.fs_type in RESIZABLE_EXT_TYPES:
        log_command(["resize2fs", config.lv_path])
    elif config.fs_type == "xfs":
        log_command(["xfs_growfs", config.mountpoint])
    log("")


def confirm_plan(config: AddConfig) -> None:
    if config.dry_run or config.yes:
        return

    # 这里会重写目标磁盘分区表，必须让操作者显式确认。
    sys.stderr.write(f"Type EXTEND-LVM to overwrite {config.disk} and extend {config.lv_path}: ")
    sys.stderr.flush()
    answer = sys.stdin.readline().strip()
    if answer != "EXTEND-LVM":
        die("Confirmation failed.")


def resize_filesystem(runner: Runner, config: AddConfig) -> None:
    if config.fs_type in RESIZABLE_EXT_TYPES:
        runner.run(["resize2fs", config.lv_path])
        return

    if config.fs_type == "xfs":
        runner.run(["xfs_growfs", config.mountpoint])
        return

    die(f"Unsupported filesystem type for resize: {config.fs_type}")


def add_command(args: argparse.Namespace) -> int:
    require_add_arguments(args)
    require_linux()
    require_root_for_write(args.dry_run)
    require_commands(
        [
            "lsblk",
            "parted",
            "partprobe",
            "pvcreate",
            "pvs",
            "vgextend",
            "lvextend",
            "lvs",
            "findmnt",
            "blkid",
        ]
    )

    runner = Runner(args.dry_run)
    config = build_config(args, runner)

    print_plan(config)
    confirm_plan(config)

    runner.run(["parted", config.disk, "-a", "optimal", "-s", "mklabel", "gpt", "mkpart", "primary", "1MiB", "100%", "set", "1", "lvm", "on"])
    runner.run(["partprobe", config.disk])
    if shutil.which("udevadm") is not None:
        runner.run(["udevadm", "settle"])

    runner.run(["pvcreate", config.partition_path])
    runner.run(["vgextend", config.vg_name, config.partition_path])
    runner.run(["lvextend", "-l", "+100%FREE", config.lv_path])
    resize_filesystem(runner, config)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", nargs="?")

    parser.add_argument("disk", nargs="?")
    parser.add_argument("lv_path", nargs="?")
    parser.add_argument("extra", nargs="*")
    parser.add_argument("--vg", dest="vg_name", default="")
    parser.add_argument("--fs-type", choices=sorted(SUPPORTED_FS_TYPES), default="auto")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.help or args.command in (None, "help"):
        sys.stdout.write(USAGE_TEXT)
        return 0

    if args.command != "add":
        print_add_usage()
        die(f"Unknown command: {args.command}")

    if args.extra:
        print_add_usage()
        die("Too many arguments.")

    return add_command(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CommandError as exc:
        die(str(exc))
    except subprocess.CalledProcessError as exc:
        die(f"Command failed: {shlex.join(exc.cmd)}")
    except KeyboardInterrupt:
        sys.stderr.write("\nERROR: Interrupted by user.\n")
        raise SystemExit(130)
