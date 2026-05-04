#!/usr/bin/env bash

set -euo pipefail

SWAP=/var/swap.img
SWAP_SIZE_MB=1000
FSTAB=/etc/fstab

log() {
    echo "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTION]

Create and enable a Linux swap file.

Options:
  -h, --help    Show this help message and exit

Defaults:
  Swap file:    $SWAP
  Swap size:    ${SWAP_SIZE_MB}MiB
  fstab file:   $FSTAB

Notes:
  This script must be run as root unless --help is used.
  It creates the swap file if missing, enables it, and appends an fstab entry if needed.
EOF
}

parse_args() {
    if (($# > 1));then
        die "Too many arguments."
    fi

    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        "")
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
}

require_root() {
    if ((EUID != 0));then
        die "Need run as root."
    fi
}

require_linux() {
    if [[ "$(uname)" != "Linux" ]];then
        die "Only run on Linux"
    fi
}

require_commands() {
    local cmd

    for cmd in awk chmod cp date dd mkswap swapon;do
        if ! command -v "$cmd" >/dev/null 2>&1;then
            die "Missing required command: $cmd"
        fi
    done
}

validate_paths() {
    local swap_dir

    # 写入系统文件前先校验路径，避免空路径、目录或符号链接导致误操作。
    if [[ -z "$SWAP" || "$SWAP" != /* || "$SWAP" == "/" ]];then
        die "Invalid swap file path: $SWAP"
    fi

    if [[ -L "$SWAP" ]];then
        die "Swap file must not be a symbolic link: $SWAP"
    fi

    if [[ -e "$SWAP" && ! -f "$SWAP" ]];then
        die "Swap path exists but is not a regular file: $SWAP"
    fi

    swap_dir=${SWAP%/*}
    if [[ ! -d "$swap_dir" ]];then
        die "Swap directory does not exist: $swap_dir"
    fi

    if [[ ! -f "$FSTAB" || ! -w "$FSTAB" ]];then
        die "Cannot write fstab: $FSTAB"
    fi
}

create_swap_file() {
    log "Create $SWAP file, wait a minute..."

    dd if=/dev/zero of="$SWAP" bs=1M count="$SWAP_SIZE_MB"

    chmod 0600 "$SWAP"
    mkswap "$SWAP"
}

is_swap_enabled() {
    awk -v path="$SWAP" 'NR > 1 && $1 == path { found=1 } END { exit found ? 0 : 1 }' /proc/swaps
}

enable_swap() {
    if is_swap_enabled;then
        log "Swap is already enabled."
        return
    fi

    if ! swapon "$SWAP";then
        die "Failed to enable swap: $SWAP"
    fi

    log "Swap enabled: $SWAP"
}

ensure_fstab_entry() {
    if awk -v path="$SWAP" '$1 == path { found=1 } END { exit found ? 0 : 1 }' "$FSTAB";then
        log "fstab entry already exists."
        return
    fi

    # 修改 fstab 前保留备份，便于手工回滚启动项。
    cp "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
    printf '%s none swap sw 0 0\n' "$SWAP" >> "$FSTAB"
    log "Added swap entry to $FSTAB."
}

main() {
    parse_args "$@"

    require_root
    require_linux
    require_commands
    validate_paths

    if [[ ! -e "$SWAP" ]];then
        create_swap_file
    else
        log "Already exist swap file."
        chmod 0600 "$SWAP"
    fi

    enable_swap
    ensure_fstab_entry
}

main "$@"
