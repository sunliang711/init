#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
YES=0
FORCE=0
VG_NAME=""
FS_TYPE="auto"
DISK=""
LV_PATH=""

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} add [options] /dev/DISK /dev/VG/LV

Options:
  --vg VG_NAME             Require the target LV to belong to this VG.
  --fs-type TYPE           Filesystem type: auto, ext2, ext3, ext4, xfs. Default: auto.
  --dry-run                Print the execution plan without changing disks.
  --yes                    Execute without interactive confirmation.
  --force                  Allow overwriting a disk that already has partitions.
  -h, --help               Show this help.

Examples:
  ${SCRIPT_NAME} add --dry-run /dev/sdb /dev/vg0/root
  ${SCRIPT_NAME} add --yes --fs-type xfs /dev/nvme1n1 /dev/vg0/data
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

quote_cmd() {
    local arg
    printf '+'
    for arg in "$@"; do
        printf ' %q' "${arg}"
    done
    printf '\n'
}

run_cmd() {
    quote_cmd "$@"
    if [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi
    "$@"
}

require_linux() {
    [ "$(uname -s)" = "Linux" ] || die "Linux is required."
}

require_root_for_write() {
    if [ "${DRY_RUN}" -eq 0 ] && [ "${EUID}" -ne 0 ]; then
        die "Root privilege is required when not using --dry-run."
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Command is required: $1"
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        require_command "${command_name}"
    done
}

parse_add_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --vg)
            [ "$#" -ge 2 ] || die "--vg requires a value."
            VG_NAME="$2"
            shift 2
            ;;
        --fs-type)
            [ "$#" -ge 2 ] || die "--fs-type requires a value."
            FS_TYPE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            YES=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
        esac
    done

    [ "$#" -eq 2 ] || die "Usage: ${SCRIPT_NAME} add [options] /dev/DISK /dev/VG/LV"
    DISK="$1"
    LV_PATH="$2"

    case "${FS_TYPE}" in
    auto | ext2 | ext3 | ext4 | xfs)
        ;;
    *)
        die "Unsupported filesystem type: ${FS_TYPE}"
        ;;
    esac
}

list_child_partitions() {
    lsblk -nrpo NAME "${DISK}" | sed '1d'
}

has_mountpoint() {
    lsblk -nrpo MOUNTPOINT "$1" | awk 'NF { found=1 } END { exit found ? 0 : 1 }'
}

is_lvm_pv() {
    pvs --noheadings "$1" >/dev/null 2>&1
}

predict_partition_path() {
    local disk="$1"
    case "$(basename "${disk}")" in
    nvme*n* | mmcblk* | loop*)
        printf '%sp1\n' "${disk}"
        ;;
    *)
        printf '%s1\n' "${disk}"
        ;;
    esac
}

resolve_lv_vg() {
    local vg
    vg="$(lvs --noheadings -o vg_name "${LV_PATH}" 2>/dev/null | awk 'NF { print $1; exit }')"
    [ -n "${vg}" ] || die "Cannot find LV: ${LV_PATH}"

    if [ -n "${VG_NAME}" ] && [ "${VG_NAME}" != "${vg}" ]; then
        die "LV ${LV_PATH} belongs to VG ${vg}, not ${VG_NAME}."
    fi

    VG_NAME="${vg}"
}

detect_filesystem_type() {
    local detected=""

    if [ "${FS_TYPE}" != "auto" ]; then
        printf '%s\n' "${FS_TYPE}"
        return 0
    fi

    detected="$(findmnt -rn -o FSTYPE --source "${LV_PATH}" 2>/dev/null | sed -n '1p' || true)"
    if [ -z "${detected}" ]; then
        detected="$(blkid -s TYPE -o value "${LV_PATH}" 2>/dev/null || true)"
    fi

    [ -n "${detected}" ] || die "Cannot detect filesystem type for ${LV_PATH}. Use --fs-type."
    printf '%s\n' "${detected}"
}

get_mountpoint() {
    findmnt -rn -o TARGET --source "${LV_PATH}" 2>/dev/null | sed -n '1p'
}

validate_disk() {
    local partition
    local existing_partitions=()

    [ -b "${DISK}" ] || die "Disk is not a block device: ${DISK}"

    if has_mountpoint "${DISK}"; then
        die "Disk or its partitions are mounted: ${DISK}"
    fi

    if is_lvm_pv "${DISK}"; then
        die "Disk is already an LVM PV: ${DISK}"
    fi

    mapfile -t existing_partitions < <(list_child_partitions)
    if [ "${#existing_partitions[@]}" -gt 0 ]; then
        for partition in "${existing_partitions[@]}"; do
            if has_mountpoint "${partition}"; then
                die "Partition is mounted: ${partition}"
            fi
            if is_lvm_pv "${partition}"; then
                die "Partition is already an LVM PV: ${partition}"
            fi
        done

        if [ "${FORCE}" -ne 1 ]; then
            die "Disk already has partitions. Re-run with --force to overwrite: ${DISK}"
        fi
    fi
}

validate_partition_plan() {
    local partition="$1"

    if [ -b "${partition}" ] && [ "${FORCE}" -ne 1 ]; then
        die "Planned partition already exists. Re-run with --force to overwrite: ${partition}"
    fi
}

require_resize_command() {
    local fs_type="$1"

    case "${fs_type}" in
    ext2 | ext3 | ext4)
        require_command resize2fs
        ;;
    xfs)
        require_command xfs_growfs
        ;;
    *)
        die "Unsupported filesystem type for online resize: ${fs_type}"
        ;;
    esac
}

confirm_plan() {
    local partition="$1"
    local fs_type="$2"
    local answer=""

    log "Execution plan:"
    log "  disk: ${DISK}"
    log "  new partition: ${partition}"
    log "  vg: ${VG_NAME}"
    log "  lv: ${LV_PATH}"
    log "  filesystem: ${fs_type}"
    log "  dry-run: ${DRY_RUN}"
    log "  force: ${FORCE}"
    log ""
    log "Commands to run:"
    quote_cmd parted "${DISK}" -a optimal -s mklabel gpt mkpart primary 1MiB 100% set 1 lvm on
    quote_cmd partprobe "${DISK}"
    if command -v udevadm >/dev/null 2>&1; then
        quote_cmd udevadm settle
    fi
    quote_cmd pvcreate "${partition}"
    quote_cmd vgextend "${VG_NAME}" "${partition}"
    quote_cmd lvextend -l +100%FREE "${LV_PATH}"
    case "${fs_type}" in
    ext2 | ext3 | ext4)
        quote_cmd resize2fs "${LV_PATH}"
        ;;
    xfs)
        quote_cmd xfs_growfs "$(get_mountpoint)"
        ;;
    esac
    log ""

    if [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi

    if [ "${YES}" -eq 1 ]; then
        return 0
    fi

    # 这里会重写目标磁盘分区表，必须让操作者显式确认。
    printf 'Type EXTEND-LVM to overwrite %s and extend %s: ' "${DISK}" "${LV_PATH}" >&2
    read -r answer
    [ "${answer}" = "EXTEND-LVM" ] || die "Confirmation failed."
}

resize_filesystem() {
    local fs_type="$1"
    local mountpoint="$2"

    case "${fs_type}" in
    ext2 | ext3 | ext4)
        run_cmd resize2fs "${LV_PATH}"
        ;;
    xfs)
        run_cmd xfs_growfs "${mountpoint}"
        ;;
    *)
        die "Unsupported filesystem type for resize: ${fs_type}"
        ;;
    esac
}

add() {
    local partition
    local fs_type
    local mountpoint=""

    parse_add_args "$@"
    require_linux
    require_root_for_write
    require_commands lsblk sed awk parted partprobe pvcreate pvs vgextend lvextend lvs findmnt blkid

    validate_disk
    resolve_lv_vg
    fs_type="$(detect_filesystem_type)"
    require_resize_command "${fs_type}"
    partition="$(predict_partition_path "${DISK}")"
    validate_partition_plan "${partition}"
    if [ "${fs_type}" = "xfs" ]; then
        mountpoint="$(get_mountpoint)"
        [ -n "${mountpoint}" ] || die "XFS resize requires a mounted filesystem: ${LV_PATH}"
    fi

    confirm_plan "${partition}" "${fs_type}"

    run_cmd parted "${DISK}" -a optimal -s mklabel gpt mkpart primary 1MiB 100% set 1 lvm on
    run_cmd partprobe "${DISK}"
    if command -v udevadm >/dev/null 2>&1; then
        run_cmd udevadm settle
    fi

    run_cmd pvcreate "${partition}"
    run_cmd vgextend "${VG_NAME}" "${partition}"
    run_cmd lvextend -l +100%FREE "${LV_PATH}"
    resize_filesystem "${fs_type}" "${mountpoint}"
}

main() {
    local command="${1:-}"

    case "${command}" in
    "" | -h | --help | help)
        usage
        ;;
    add)
        shift
        add "$@"
        ;;
    *)
        die "Unknown command: ${command}"
        ;;
    esac
}

main "$@"
