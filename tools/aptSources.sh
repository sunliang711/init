#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APPLY=0
RUN_UPDATE=0
MIRROR="official"
MIRROR_URL=""
MIRROR_SECURITY=0
FORMAT="auto"
OUTPUT=""
NO_BACKPORTS=0

log_info() {
    echo "INFO: $*"
}

log_error() {
    echo "ERROR: $*" >&2
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  --mirror NAME        Use mirror preset: official, tuna, ustc, aliyun, 163. Default: official
  --mirror-url URL     Use custom mirror base URL
  --mirror-security    Use selected mirror for security updates too
  --format FORMAT      Output format: auto, deb822, list. Default: auto
  --output FILE        Write target file. Default depends on distro and format
  --no-backports       Do not generate backports entries
  --dry-run            Print generated content only. This is the default
  --apply              Write source file
  --update             Run apt-get update after writing. Requires --apply
  -h, --help           Print this message

Examples:
  ${SCRIPT_NAME} --mirror official --dry-run
  ${SCRIPT_NAME} --mirror official --apply
  ${SCRIPT_NAME} --mirror tuna --apply --update
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mirror)
                if [ "$#" -lt 2 ]; then
                    log_error "--mirror requires an argument"
                    exit 1
                fi
                MIRROR="$2"
                shift 2
                ;;
            --mirror-url)
                if [ "$#" -lt 2 ]; then
                    log_error "--mirror-url requires an argument"
                    exit 1
                fi
                MIRROR_URL="$2"
                shift 2
                ;;
            --mirror-security)
                MIRROR_SECURITY=1
                shift
                ;;
            --format)
                if [ "$#" -lt 2 ]; then
                    log_error "--format requires an argument"
                    exit 1
                fi
                FORMAT="$2"
                shift 2
                ;;
            --output)
                if [ "$#" -lt 2 ]; then
                    log_error "--output requires an argument"
                    exit 1
                fi
                OUTPUT="$2"
                shift 2
                ;;
            --no-backports)
                NO_BACKPORTS=1
                shift
                ;;
            --dry-run)
                APPLY=0
                shift
                ;;
            --apply)
                APPLY=1
                shift
                ;;
            --update)
                RUN_UPDATE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing required command: $1"
        exit 1
    fi
}

strip_quotes() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
}

read_os_value() {
    local key="$1"
    local value=""

    value="$(grep -E "^${key}=" /etc/os-release 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
    strip_quotes "$value"
}

detect_os() {
    if [ ! -r /etc/os-release ]; then
        log_error "No readable /etc/os-release"
        exit 1
    fi

    OS_ID="$(read_os_value "ID")"
    OS_CODENAME="$(read_os_value "VERSION_CODENAME")"

    if [ "$OS_ID" = "ubuntu" ] && [ -z "$OS_CODENAME" ]; then
        OS_CODENAME="$(read_os_value "UBUNTU_CODENAME")"
    fi

    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        log_error "Unsupported OS: ${OS_ID:-unknown}"
        exit 1
    fi

    if [ -z "$OS_CODENAME" ]; then
        log_error "Cannot detect VERSION_CODENAME from /etc/os-release"
        exit 1
    fi

}

detect_arch() {
    require_command dpkg
    ARCH="$(dpkg --print-architecture)"
}

normalize_url() {
    local url="$1"
    url="${url%/}"
    printf '%s' "$url"
}

is_ubuntu_ports_arch() {
    case "$ARCH" in
        amd64|i386)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

select_mirror_url() {
    local distro="$1"
    local mirror="$2"

    if [ -n "$MIRROR_URL" ]; then
        local custom_url
        custom_url="$(normalize_url "$MIRROR_URL")"
        case "$custom_url" in
            */ubuntu|*/ubuntu-ports|*/debian)
                printf '%s' "$custom_url"
                ;;
            *)
                if [ "$distro" = "ubuntu" ] && is_ubuntu_ports_arch; then
                    printf '%s' "${custom_url}/ubuntu-ports"
                elif [ "$distro" = "ubuntu" ]; then
                    printf '%s' "${custom_url}/ubuntu"
                else
                    printf '%s' "${custom_url}/debian"
                fi
                ;;
        esac
        return
    fi

    case "$mirror" in
        official)
            if [ "$distro" = "ubuntu" ]; then
                if is_ubuntu_ports_arch; then
                    printf '%s' "http://ports.ubuntu.com/ubuntu-ports"
                else
                    printf '%s' "http://archive.ubuntu.com/ubuntu"
                fi
            else
                printf '%s' "http://deb.debian.org/debian"
            fi
            ;;
        tuna)
            if [ "$distro" = "ubuntu" ] && is_ubuntu_ports_arch; then
                printf '%s' "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
            elif [ "$distro" = "ubuntu" ]; then
                printf '%s' "https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
            else
                printf '%s' "https://mirrors.tuna.tsinghua.edu.cn/debian"
            fi
            ;;
        ustc)
            if [ "$distro" = "ubuntu" ] && is_ubuntu_ports_arch; then
                printf '%s' "https://mirrors.ustc.edu.cn/ubuntu-ports"
            elif [ "$distro" = "ubuntu" ]; then
                printf '%s' "https://mirrors.ustc.edu.cn/ubuntu"
            else
                printf '%s' "https://mirrors.ustc.edu.cn/debian"
            fi
            ;;
        aliyun)
            if [ "$distro" = "ubuntu" ] && is_ubuntu_ports_arch; then
                printf '%s' "https://mirrors.aliyun.com/ubuntu-ports"
            elif [ "$distro" = "ubuntu" ]; then
                printf '%s' "https://mirrors.aliyun.com/ubuntu"
            else
                printf '%s' "https://mirrors.aliyun.com/debian"
            fi
            ;;
        163)
            if [ "$distro" = "ubuntu" ] && is_ubuntu_ports_arch; then
                printf '%s' "http://mirrors.163.com/ubuntu-ports"
            elif [ "$distro" = "ubuntu" ]; then
                printf '%s' "http://mirrors.163.com/ubuntu"
            else
                printf '%s' "http://mirrors.163.com/debian"
            fi
            ;;
        *)
            log_error "Unsupported mirror preset: $mirror"
            exit 1
            ;;
    esac
}

select_debian_security_mirror_url() {
    if [ -n "$MIRROR_URL" ]; then
        local custom_url
        custom_url="$(normalize_url "$MIRROR_URL")"
        case "$custom_url" in
            */debian-security)
                printf '%s' "$custom_url"
                ;;
            */debian)
                printf '%s' "${custom_url%/debian}/debian-security"
                ;;
            *)
                printf '%s' "${custom_url}/debian-security"
                ;;
        esac
        return
    fi

    case "$MIRROR" in
        official)
            printf '%s' "http://security.debian.org/debian-security"
            ;;
        tuna)
            printf '%s' "https://mirrors.tuna.tsinghua.edu.cn/debian-security"
            ;;
        ustc)
            printf '%s' "https://mirrors.ustc.edu.cn/debian-security"
            ;;
        aliyun)
            printf '%s' "https://mirrors.aliyun.com/debian-security"
            ;;
        163)
            printf '%s' "http://mirrors.163.com/debian-security"
            ;;
        *)
            log_error "Unsupported mirror preset: $MIRROR"
            exit 1
            ;;
    esac
}

select_security_url() {
    local distro="$1"

    if [ "$distro" = "ubuntu" ]; then
        if [ "$MIRROR" = "official" ] && [ -z "$MIRROR_URL" ]; then
            if is_ubuntu_ports_arch; then
                printf '%s' "http://ports.ubuntu.com/ubuntu-ports"
            else
                printf '%s' "http://security.ubuntu.com/ubuntu"
            fi
        elif [ "$MIRROR_SECURITY" -eq 1 ] || [ -n "$MIRROR_URL" ]; then
            select_mirror_url "$distro" "$MIRROR"
        elif is_ubuntu_ports_arch; then
            printf '%s' "http://ports.ubuntu.com/ubuntu-ports"
        else
            printf '%s' "http://security.ubuntu.com/ubuntu"
        fi
    else
        if [ "$MIRROR_SECURITY" -eq 1 ] || [ -n "$MIRROR_URL" ]; then
            select_debian_security_mirror_url
        else
            printf '%s' "http://security.debian.org/debian-security"
        fi
    fi
}

resolve_format() {
    case "$FORMAT" in
        auto|deb822|list)
            ;;
        *)
            log_error "Unsupported format: $FORMAT"
            exit 1
            ;;
    esac

    if [ "$FORMAT" != "auto" ]; then
        RESOLVED_FORMAT="$FORMAT"
        return
    fi

    if [ "$OS_ID" = "ubuntu" ] && [ -e "/etc/apt/sources.list.d/ubuntu.sources" ]; then
        RESOLVED_FORMAT="deb822"
    elif [ "$OS_ID" = "debian" ] && [ -e "/etc/apt/sources.list.d/debian.sources" ]; then
        RESOLVED_FORMAT="deb822"
    else
        RESOLVED_FORMAT="list"
    fi
}

resolve_output() {
    if [ -n "$OUTPUT" ]; then
        TARGET_FILE="$OUTPUT"
        return
    fi

    if [ "$RESOLVED_FORMAT" = "deb822" ]; then
        TARGET_FILE="/etc/apt/sources.list.d/${OS_ID}.sources"
    else
        TARGET_FILE="/etc/apt/sources.list"
    fi
}

validate_target_file() {
    case "$TARGET_FILE" in
        ""|"/"|"/etc"|"/etc/apt"|"/etc/apt/"|"/etc/apt/sources.list.d"|"/etc/apt/sources.list.d/")
            log_error "Unsafe output path: ${TARGET_FILE:-empty}"
            exit 1
            ;;
    esac

    if [ "$APPLY" -eq 1 ]; then
        local target_dir
        target_dir="$(dirname "$TARGET_FILE")"

        if [ ! -d "$target_dir" ]; then
            log_error "Output directory does not exist: $target_dir"
            exit 1
        fi

        if [ ! -w "$target_dir" ]; then
            log_error "Output directory is not writable: $target_dir"
            exit 1
        fi
    fi
}

build_ubuntu_deb822() {
    local mirror_url="$1"
    local security_url="$2"
    local suites="${OS_CODENAME} ${OS_CODENAME}-updates"

    if [ "$NO_BACKPORTS" -eq 0 ]; then
        suites="${suites} ${OS_CODENAME}-backports"
    fi

    cat <<EOF
Types: deb
URIs: ${mirror_url}/
Suites: ${suites}
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security_url}/
Suites: ${OS_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
}

build_ubuntu_list() {
    local mirror_url="$1"
    local security_url="$2"

    cat <<EOF
deb ${mirror_url}/ ${OS_CODENAME} main restricted universe multiverse
deb ${mirror_url}/ ${OS_CODENAME}-updates main restricted universe multiverse
EOF

    if [ "$NO_BACKPORTS" -eq 0 ]; then
        printf 'deb %s/ %s-backports main restricted universe multiverse\n' "$mirror_url" "$OS_CODENAME"
    fi

    printf 'deb %s/ %s-security main restricted universe multiverse\n' "$security_url" "$OS_CODENAME"
}

build_debian_deb822() {
    local mirror_url="$1"
    local security_url="$2"
    local suites="${OS_CODENAME} ${OS_CODENAME}-updates"

    if [ "$NO_BACKPORTS" -eq 0 ]; then
        suites="${suites} ${OS_CODENAME}-backports"
    fi

    cat <<EOF
Types: deb
URIs: ${mirror_url}/
Suites: ${suites}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${security_url}/
Suites: ${OS_CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

build_debian_list() {
    local mirror_url="$1"
    local security_url="$2"

    cat <<EOF
deb ${mirror_url}/ ${OS_CODENAME} main contrib non-free non-free-firmware
deb ${mirror_url}/ ${OS_CODENAME}-updates main contrib non-free non-free-firmware
EOF

    if [ "$NO_BACKPORTS" -eq 0 ]; then
        printf 'deb %s/ %s-backports main contrib non-free non-free-firmware\n' "$mirror_url" "$OS_CODENAME"
    fi

    printf 'deb %s/ %s-security main contrib non-free non-free-firmware\n' "$security_url" "$OS_CODENAME"
}

build_source_content() {
    local mirror_url="$1"
    local security_url="$2"

    if [ "$OS_ID" = "ubuntu" ] && [ "$RESOLVED_FORMAT" = "deb822" ]; then
        build_ubuntu_deb822 "$mirror_url" "$security_url"
    elif [ "$OS_ID" = "ubuntu" ]; then
        build_ubuntu_list "$mirror_url" "$security_url"
    elif [ "$RESOLVED_FORMAT" = "deb822" ]; then
        build_debian_deb822 "$mirror_url" "$security_url"
    else
        build_debian_list "$mirror_url" "$security_url"
    fi
}

backup_target_file() {
    if [ -e "$TARGET_FILE" ]; then
        local backup_file
        backup_file="${TARGET_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$TARGET_FILE" "$backup_file"
        log_info "Backup created: $backup_file"
    fi
}

write_source_file() {
    local content="$1"
    local temp_file

    temp_file="$(mktemp)"
    trap 'rm -f "$temp_file"' EXIT
    printf '%s\n' "$content" > "$temp_file"
    chmod 0644 "$temp_file"
    backup_target_file
    mv "$temp_file" "$TARGET_FILE"
    trap - EXIT
    log_info "Source file written: $TARGET_FILE"
}

run_update() {
    if [ "$RUN_UPDATE" -eq 1 ]; then
        log_info "Running apt-get update"
        apt-get update
    fi
}

main() {
    parse_args "$@"
    require_command grep
    require_command cut
    require_command head
    require_command dirname
    detect_os
    detect_arch
    resolve_format
    resolve_output
    validate_target_file

    if [ "$APPLY" -eq 1 ] && [ "${EUID}" -ne 0 ]; then
        log_error "--apply requires root privilege"
        exit 1
    fi

    if [ "$RUN_UPDATE" -eq 1 ] && [ "$APPLY" -ne 1 ]; then
        log_error "--update requires --apply"
        exit 1
    fi

    if [ "$APPLY" -eq 1 ]; then
        require_command cp
        require_command date
        require_command chmod
        require_command mktemp
        require_command mv
    fi

    if [ "$RUN_UPDATE" -eq 1 ]; then
        require_command apt-get
    fi

    local mirror_url
    local security_url
    local content

    mirror_url="$(select_mirror_url "$OS_ID" "$MIRROR")"
    security_url="$(select_security_url "$OS_ID")"
    content="$(build_source_content "$mirror_url" "$security_url")"

    log_info "OS: $OS_ID"
    log_info "Codename: $OS_CODENAME"
    log_info "Architecture: $ARCH"
    log_info "Format: $RESOLVED_FORMAT"
    log_info "Target: $TARGET_FILE"
    log_info "Mirror: $mirror_url"
    log_info "Security: $security_url"

    if [ "$APPLY" -eq 1 ]; then
        write_source_file "$content"
        run_update
    else
        log_info "Dry run mode. No files will be changed."
        printf '%s\n' "----- BEGIN ${TARGET_FILE} -----"
        printf '%s\n' "$content"
        printf '%s\n' "----- END ${TARGET_FILE} -----"
    fi
}

main "$@"
