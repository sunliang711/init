#!/usr/bin/env bash

set -euo pipefail

SWAP=/var/swap.img
SWAP_SIZE_MB=1000
FSTAB=/etc/fstab
SYSCTL_CONF=/etc/sysctl.d/99-swappiness.conf
SWAPPINESS=10

log() {
    echo "$*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

Create and enable a Linux swap file.

Options:
  -f, --file PATH    Use a custom swap file path
  -s, --size SIZE    Use a custom swap size, such as 2048, 2048M, or 2G
  -h, --help         Show this help message and exit

Defaults:
  Swap file:    $SWAP
  Swap size:    ${SWAP_SIZE_MB}MiB
  fstab file:   $FSTAB
  sysctl file:  $SYSCTL_CONF
  swappiness:   $SWAPPINESS

Examples:
  sudo ${0##*/} --size 2G
  sudo ${0##*/} --file /var/swapfile --size 2048M

Notes:
  This script must be run as root unless --help is used.
  It creates the swap file if missing, enables it, and appends an fstab entry if needed.
  It writes vm.swappiness to the sysctl config file and applies it immediately.
  The size option is only used when the swap file does not already exist.
EOF
}

normalize_size() {
    local number
    local unit
    local value

    value=$1

    if [[ ! "$value" =~ ^([1-9][0-9]*)([mMgG]?)$ ]];then
        die "Swap size must be a positive integer with optional M or G suffix: $value"
    fi

    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}

    case "$unit" in
        g|G)
            SWAP_SIZE_MB=$((number * 1024))
            ;;
        ""|m|M)
            SWAP_SIZE_MB=$number
            ;;
    esac
}

validate_swap_path_value() {
    if [[ -z "$SWAP" || "$SWAP" != /* || "$SWAP" == "/" ]];then
        die "Invalid swap file path: $SWAP"
    fi
}

parse_args() {
    while (($# > 0));do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--file)
                if (($# < 2));then
                    die "Missing value for $1"
                fi
                SWAP=$2
                shift 2
                ;;
            --file=*)
                SWAP=${1#*=}
                shift
                ;;
            -s|--size)
                if (($# < 2));then
                    die "Missing value for $1"
                fi
                normalize_size "$2"
                shift 2
                ;;
            --size=*)
                normalize_size "${1#*=}"
                shift
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    validate_swap_path_value
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

    for cmd in awk chmod cp date dd mkswap swapon sysctl;do
        if ! command -v "$cmd" >/dev/null 2>&1;then
            die "Missing required command: $cmd"
        fi
    done
}

validate_paths() {
    local swap_dir
    local sysctl_dir

    # 写入系统文件前先校验路径，避免空路径、目录或符号链接导致误操作。
    validate_swap_path_value

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

    sysctl_dir=${SYSCTL_CONF%/*}
    if [[ ! -d "$sysctl_dir" || ! -w "$sysctl_dir" ]];then
        die "Cannot write sysctl directory: $sysctl_dir"
    fi

    if [[ -L "$SYSCTL_CONF" ]];then
        die "Sysctl config must not be a symbolic link: $SYSCTL_CONF"
    fi

    if [[ -e "$SYSCTL_CONF" && ! -f "$SYSCTL_CONF" ]];then
        die "Sysctl config exists but is not a regular file: $SYSCTL_CONF"
    fi

    if [[ -e "$SYSCTL_CONF" && ! -w "$SYSCTL_CONF" ]];then
        die "Cannot write sysctl config: $SYSCTL_CONF"
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

ensure_swappiness_sysctl() {
    if [[ -f "$SYSCTL_CONF" ]] && awk -v value="$SWAPPINESS" '$0 == "vm.swappiness = " value { found=1 } END { exit found ? 0 : 1 }' "$SYSCTL_CONF";then
        log "Sysctl swappiness config already exists."
    else
        # 覆盖 sysctl 专用配置前保留备份，便于手工回滚内核参数。
        if [[ -f "$SYSCTL_CONF" ]];then
            cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        fi

        printf 'vm.swappiness = %s\n' "$SWAPPINESS" > "$SYSCTL_CONF"
        chmod 0644 "$SYSCTL_CONF"
        log "Configured vm.swappiness=$SWAPPINESS in $SYSCTL_CONF."
    fi

    sysctl -p "$SYSCTL_CONF" >/dev/null
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
    ensure_swappiness_sysctl
}

main "$@"
