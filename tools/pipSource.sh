#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"

MIRROR="tuna"
MIRROR_URL=""
CONFIG_STYLE="auto"
CONFIG_FILE=""
TARGET_USER=""
TARGET_HOME=""
DRY_RUN=0
BACKUP=1
TRUSTED_HOST=""

INDEX_URL=""
TARGET_GROUP=""

log_info() {
    printf 'INFO: %s\n' "$*"
}

log_warn() {
    printf 'WARN: %s\n' "$*" >&2
}

log_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Configure pip index-url for the target user.

Options:
  --mirror NAME          Mirror preset: tuna, ustc, aliyun, huaweicloud, pypi. Default: tuna
  --mirror-url URL       Custom index URL or mirror base URL. "/simple" is appended when missing
  --config-style STYLE   Config location: auto, modern, legacy. Default: auto
  --modern               Shortcut for --config-style modern
  --legacy               Shortcut for --config-style legacy
  --config FILE          Write an explicit pip.conf path
  --user USER            Target user. Default: SUDO_USER when run by sudo, otherwise current user
  --home DIR             Target home directory. Overrides detected home
  --trusted-host HOST    Write trusted-host. Use "auto" to derive the host from index-url
  --no-backup            Do not create a timestamped backup before overwriting
  --dry-run              Print the generated config instead of writing it
  --apply                Write config. This is the default
  -h, --help             Print this message

Config style:
  auto                   Use existing config path if found; otherwise use modern
  modern                 Write ~/.config/pip/pip.conf
  legacy                 Write ~/.pip/pip.conf

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --dry-run
  ${SCRIPT_NAME} --mirror ustc
  ${SCRIPT_NAME} --mirror-url https://pypi.org/simple
  sudo ${SCRIPT_NAME} --user alice
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mirror)
                require_arg "$@"
                MIRROR="$2"
                shift 2
                ;;
            --mirror-url)
                require_arg "$@"
                MIRROR_URL="$2"
                shift 2
                ;;
            --config-style)
                require_arg "$@"
                CONFIG_STYLE="$2"
                shift 2
                ;;
            --modern)
                CONFIG_STYLE="modern"
                shift
                ;;
            --legacy)
                CONFIG_STYLE="legacy"
                shift
                ;;
            --config)
                require_arg "$@"
                CONFIG_FILE="$2"
                shift 2
                ;;
            --user)
                require_arg "$@"
                TARGET_USER="$2"
                shift 2
                ;;
            --home)
                require_arg "$@"
                TARGET_HOME="$2"
                shift 2
                ;;
            --trusted-host)
                require_arg "$@"
                TRUSTED_HOST="$2"
                shift 2
                ;;
            --no-backup)
                BACKUP=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --apply)
                DRY_RUN=0
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

require_arg() {
    if [ "$#" -lt 2 ]; then
        log_error "$1 requires an argument"
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing required command: $1"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_index_url() {
    local url="$1"

    url="${url%/}"
    case "$url" in
        http://*|https://*)
            ;;
        *)
            log_error "Invalid index URL: $url"
            exit 1
            ;;
    esac

    case "$url" in
        */simple)
            printf '%s' "$url"
            ;;
        *)
            printf '%s/simple' "$url"
            ;;
    esac
}

select_mirror_url() {
    if [ -n "$MIRROR_URL" ]; then
        normalize_index_url "$MIRROR_URL"
        return
    fi

    case "$MIRROR" in
        tuna)
            printf '%s' "https://pypi.tuna.tsinghua.edu.cn/simple"
            ;;
        ustc)
            printf '%s' "https://mirrors.ustc.edu.cn/pypi/simple"
            ;;
        aliyun)
            printf '%s' "https://mirrors.aliyun.com/pypi/simple"
            ;;
        huaweicloud)
            printf '%s' "https://repo.huaweicloud.com/repository/pypi/simple"
            ;;
        pypi|official)
            printf '%s' "https://pypi.org/simple"
            ;;
        *)
            log_error "Unsupported mirror preset: $MIRROR"
            exit 1
            ;;
    esac
}

extract_url_host() {
    local url="$1"

    url="${url#*://}"
    printf '%s' "${url%%/*}"
}

resolve_trusted_host() {
    if [ "$TRUSTED_HOST" = "auto" ]; then
        TRUSTED_HOST="$(extract_url_host "$INDEX_URL")"
    elif [ -z "$TRUSTED_HOST" ]; then
        case "$INDEX_URL" in
            http://*)
                TRUSTED_HOST="$(extract_url_host "$INDEX_URL")"
                ;;
        esac
    fi
}

current_user() {
    id -un
}

resolve_user_home_with_getent() {
    local user="$1"
    local entry=""
    local _name _passwd _uid _gid _gecos home _shell

    if ! command_exists getent; then
        return 1
    fi

    entry="$(getent passwd "$user" || true)"
    if [ -z "$entry" ]; then
        return 1
    fi

    IFS=: read -r _name _passwd _uid _gid _gecos home _shell <<< "$entry"
    if [ -z "$home" ]; then
        return 1
    fi

    printf '%s' "$home"
}

resolve_user_home_with_shell() {
    local user="$1"
    local home=""

    if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    home="$(eval "printf '%s' ~${user}")"
    if [ "$home" = "~${user}" ] || [ -z "$home" ]; then
        return 1
    fi

    printf '%s' "$home"
}

resolve_target_user_home() {
    if [ -z "$TARGET_USER" ]; then
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
            TARGET_USER="$SUDO_USER"
        else
            TARGET_USER="$(current_user)"
        fi
    fi

    if [ -z "$TARGET_HOME" ]; then
        if [ "$TARGET_USER" = "$(current_user)" ] && [ -n "${HOME:-}" ]; then
            TARGET_HOME="$HOME"
        elif TARGET_HOME="$(resolve_user_home_with_getent "$TARGET_USER")"; then
            :
        elif TARGET_HOME="$(resolve_user_home_with_shell "$TARGET_USER")"; then
            :
        else
            log_error "Cannot resolve home for user: $TARGET_USER"
            exit 1
        fi
    fi

    if [ ! -d "$TARGET_HOME" ]; then
        log_error "Target home does not exist: $TARGET_HOME"
        exit 1
    fi

    TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
}

expand_target_path() {
    local path="$1"

    case "$path" in
        "~")
            printf '%s' "$TARGET_HOME"
            ;;
        "~/"*)
            printf '%s/%s' "$TARGET_HOME" "${path#~/}"
            ;;
        *)
            printf '%s' "$path"
            ;;
    esac
}

resolve_config_file() {
    if [ -n "$CONFIG_FILE" ]; then
        CONFIG_FILE="$(expand_target_path "$CONFIG_FILE")"
        return
    fi

    case "$CONFIG_STYLE" in
        auto)
            if [ -e "$TARGET_HOME/.config/pip/pip.conf" ]; then
                CONFIG_FILE="$TARGET_HOME/.config/pip/pip.conf"
            elif [ -e "$TARGET_HOME/.pip/pip.conf" ]; then
                CONFIG_FILE="$TARGET_HOME/.pip/pip.conf"
            else
                CONFIG_FILE="$TARGET_HOME/.config/pip/pip.conf"
            fi
            ;;
        modern)
            CONFIG_FILE="$TARGET_HOME/.config/pip/pip.conf"
            ;;
        legacy)
            CONFIG_FILE="$TARGET_HOME/.pip/pip.conf"
            ;;
        *)
            log_error "Unsupported config style: $CONFIG_STYLE"
            exit 1
            ;;
    esac
}

validate_config_file() {
    case "$CONFIG_FILE" in
        ""|"/"|"$TARGET_HOME"|"$TARGET_HOME/")
            log_error "Unsafe config path: ${CONFIG_FILE:-empty}"
            exit 1
            ;;
    esac
}

path_is_under_target_home() {
    local path="$1"

    case "$path/" in
        "$TARGET_HOME"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

chown_for_target_user() {
    local path="$1"

    if [ "$(id -u)" -ne 0 ] || ! path_is_under_target_home "$path"; then
        return 0
    fi

    if [ -n "$TARGET_GROUP" ]; then
        chown "$TARGET_USER:$TARGET_GROUP" "$path" 2>/dev/null || chown "$TARGET_USER" "$path"
    else
        chown "$TARGET_USER" "$path"
    fi
}

ensure_parent_dir() {
    local dir

    dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$dir"
    chown_for_target_user "$dir"
}

build_config() {
    printf '[global]\n'
    printf 'index-url = %s\n' "$INDEX_URL"
    if [ -n "$TRUSTED_HOST" ]; then
        printf 'trusted-host = %s\n' "$TRUSTED_HOST"
    fi
}

backup_config_file() {
    local backup_file
    local candidate
    local suffix
    local timestamp

    if [ "$BACKUP" -ne 1 ] || [ ! -e "$CONFIG_FILE" ]; then
        return 0
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_file="${CONFIG_FILE}.bak-${timestamp}"
    if [ -e "$backup_file" ]; then
        for suffix in {1..99}; do
            candidate="${backup_file}.${suffix}"
            if [ ! -e "$candidate" ]; then
                backup_file="$candidate"
                break
            fi
        done
    fi

    if [ -e "$backup_file" ]; then
        log_error "Cannot create unique backup file for: $CONFIG_FILE"
        exit 1
    fi

    cp -p "$CONFIG_FILE" "$backup_file"
    chown_for_target_user "$backup_file"
    log_info "Backup created: $backup_file"
}

write_config_file() {
    local temp_file

    ensure_parent_dir
    backup_config_file

    temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
    trap 'rm -f "$temp_file"' EXIT
    build_config > "$temp_file"
    chmod 0644 "$temp_file"
    chown_for_target_user "$temp_file"
    mv "$temp_file" "$CONFIG_FILE"
    trap - EXIT

    log_info "Config written: $CONFIG_FILE"
}

warn_if_pip_missing() {
    if ! command_exists pip && ! command_exists pip3; then
        log_warn "pip/pip3 is not installed. Config was still generated for future pip installs."
    fi
}

print_summary() {
    log_info "Target user: $TARGET_USER"
    log_info "Target home: $TARGET_HOME"
    log_info "Config file: $CONFIG_FILE"
    log_info "Index URL: $INDEX_URL"
    if [ -n "$TRUSTED_HOST" ]; then
        log_info "Trusted host: $TRUSTED_HOST"
    else
        log_info "Trusted host: disabled"
    fi
}

main() {
    parse_args "$@"
    require_command dirname
    require_command id

    if [ "$DRY_RUN" -ne 1 ]; then
        require_command cp
        require_command date
        require_command chmod
        require_command mkdir
        require_command mktemp
        require_command mv
        if [ "$(id -u)" -eq 0 ]; then
            require_command chown
        fi
    fi

    INDEX_URL="$(select_mirror_url)"
    resolve_trusted_host
    resolve_target_user_home
    resolve_config_file
    validate_config_file
    warn_if_pip_missing
    print_summary

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "----- BEGIN ${CONFIG_FILE} -----"
        build_config
        printf '%s\n' "----- END ${CONFIG_FILE} -----"
    else
        write_config_file
    fi
}

main "$@"
