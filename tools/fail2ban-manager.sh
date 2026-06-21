#!/usr/bin/env bash

set -euo pipefail

# 文件用途:
#   管理 fail2ban 的 service、jail、filter、ban/unban 和备份恢复。
# 配置说明:
#   F2B_CONFIG_DIR  覆盖 fail2ban 配置根目录，默认 /etc/fail2ban。
#   F2B_JAIL_DIR    覆盖 jail.d 目录，默认 ${F2B_CONFIG_DIR}/jail.d。
#   F2B_FILTER_DIR  覆盖 filter.d 目录，默认 ${F2B_CONFIG_DIR}/filter.d。
#   F2B_BACKUP_DIR  覆盖备份目录，默认 ${F2B_CONFIG_DIR}/backup/fail2ban-manager。
#   F2B_CLIENT      覆盖 fail2ban-client 命令路径。
#   F2B_REGEX       覆盖 fail2ban-regex 命令路径。
# 示例:
#   tools/fail2ban-manager.sh filter add custom-nginx-404 --failregex '^<HOST> - .* 404 .*$'
#   tools/fail2ban-manager.sh jail add nginx-404 --filter custom-nginx-404 --logpath /var/log/nginx/access.log
#   tools/fail2ban-manager.sh service reload
# 生成文件约定:
#   脚本新建的 jail、filter 和备份 manifest 都会写入管理标记、配置说明、示例和验证命令。

SCRIPT_NAME="$(basename "$0")"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

F2B_CONFIG_DIR="${F2B_CONFIG_DIR:-/etc/fail2ban}"
F2B_JAIL_DIR="${F2B_JAIL_DIR:-${F2B_CONFIG_DIR}/jail.d}"
F2B_FILTER_DIR="${F2B_FILTER_DIR:-${F2B_CONFIG_DIR}/filter.d}"
F2B_BACKUP_DIR="${F2B_BACKUP_DIR:-${F2B_CONFIG_DIR}/backup/fail2ban-manager}"
F2B_CLIENT="${F2B_CLIENT:-fail2ban-client}"
F2B_REGEX="${F2B_REGEX:-fail2ban-regex}"
F2B_SERVICE_NAME="${F2B_SERVICE_NAME:-fail2ban}"

MANAGED_MARKER="Managed by fail2ban-manager.sh"
JAIL_FILE_PREFIX="f2bm-"
CUSTOM_FILTER_PREFIX="custom-"

DRY_RUN=0
YES=0
QUIET=0
VERBOSE=0
OUTPUT_FORMAT="text"

declare -a POSITIONAL_ARGS=()

log_info() {
    if [ "${QUIET}" -eq 0 ]; then
        printf 'INFO %s\n' "$*" >&2
    fi
}

log_warn() {
    if [ "${QUIET}" -eq 0 ]; then
        printf 'WARN %s\n' "$*" >&2
    fi
}

log_debug() {
    if [ "${VERBOSE}" -eq 1 ] && [ "${QUIET}" -eq 0 ]; then
        printf 'DEBUG %s\n' "$*" >&2
    fi
}

die() {
    printf 'ERROR %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
用法:
  ${SCRIPT_NAME} <resource> <action> [options]

资源与命令:
  service status
      查看 fail2ban 服务状态。

  service reload
      先执行 fail2ban-client -t，再 reload fail2ban。

  jail list
      列出运行中的 jail；如果 fail2ban-client 不可用，则列出脚本管理的 jail 文件。

  jail show <jail>
      查看指定 jail 的运行状态和脚本管理的配置文件。

  jail add <jail> --filter <filter> --logpath <path> [options]
      新建 jail 配置文件，写入 ${F2B_JAIL_DIR}/${JAIL_FILE_PREFIX}<jail>.local。

  jail set <jail> key=value [key=value...]
      修改脚本管理的 jail 配置。

  jail enable <jail>
      设置 enabled = true。

  jail disable <jail>
      设置 enabled = false。

  jail remove <jail> --yes
      删除脚本管理的 jail 配置文件。

  filter list [--builtin|--custom]
      列出 filter。内置 filter 只允许查看和引用，自定义 filter 才允许脚本修改。

  filter show <filter>
      查看 filter 文件内容。

  filter add custom-xxx --failregex <regex> [--ignoreregex <regex>]
      新建自定义 filter，文件名为 custom-xxx.conf。

  filter import custom-xxx --source <path>
      从已有 filter 文件导入为自定义 filter，并补充管理注释。

  filter test <filter> --logfile <path>
      使用 fail2ban-regex 测试 filter。

  filter remove custom-xxx --yes
      删除自定义 filter。删除前会检查是否仍被 jail 引用。

  ban list <jail>
      查看 jail 当前封禁信息。

  ban add <jail> <ip>
      手动封禁 IP。

  ban remove <jail> <ip>
      手动解封 IP。

  backup create
      备份当前 jail.d 和 filter.d。

  backup list
      列出脚本创建的备份。

  backup restore <backup-id> --yes
      从备份恢复 jail.d 与 filter.d 中的文件。

  doctor
      检查系统、依赖命令、目录和 fail2ban 基础状态。

全局参数:
  --dry-run
      只打印将要执行的操作，不写文件、不 reload、不封禁、不解封。

  --yes
      确认执行删除、恢复等危险操作。

  --format text|kv
      输出格式，默认 text。kv 只覆盖部分查询命令。

  --quiet
      减少日志输出。

  --verbose
      输出更多诊断日志。

  -h, --help
      显示帮助。

jail add 参数:
  --filter <filter>
      jail 引用的 filter 名称，不带 .conf 后缀。可以是内置 filter 或 custom-* filter。

  --logpath <path>
      绝对日志路径，可以包含通配符，但不能包含路径穿越。

  --port <port>
      端口配置，例如 ssh 或 http,https。

  --maxretry <number>
      findtime 窗口内允许失败次数，默认 5。

  --findtime <duration>
      检测窗口，默认 10m。

  --bantime <duration>
      封禁时间，默认 1h。

  --enabled true|false
      是否启用，默认 true。

示例:
  # 查看服务状态
  ${SCRIPT_NAME} service status

  # 新增使用内置 sshd filter 的 jail
  ${SCRIPT_NAME} jail add sshd-extra \\
    --filter sshd \\
    --logpath /var/log/auth.log \\
    --port ssh \\
    --maxretry 5 \\
    --findtime 10m \\
    --bantime 1h

  # 新增自定义 nginx 404 filter
  ${SCRIPT_NAME} filter add custom-nginx-404 \\
    --failregex '^<HOST> - .* "(GET|POST) .*" 404 .*$'

  # 测试 filter
  ${SCRIPT_NAME} filter test custom-nginx-404 --logfile /var/log/nginx/access.log

  # 应用配置
  ${SCRIPT_NAME} service reload
EOF
}

parse_global_args() {
    local arg

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "${arg}" in
            -h|--help)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                YES=1
                shift
                ;;
            --quiet)
                QUIET=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --format)
                [ "$#" -ge 2 ] || die "Missing value for --format"
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --format=*)
                OUTPUT_FORMAT="${arg#*=}"
                shift
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    POSITIONAL_ARGS+=("$1")
                    shift
                done
                ;;
            *)
                POSITIONAL_ARGS+=("${arg}")
                shift
                ;;
        esac
    done

    case "${OUTPUT_FORMAT}" in
        text|kv)
            ;;
        *)
            die "Invalid output format: ${OUTPUT_FORMAT}"
            ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "Missing required command: $1"
}

require_client_for_real() {
    if [ "${DRY_RUN}" -eq 0 ]; then
        require_command "${F2B_CLIENT}"
    fi
}

require_linux() {
    if [ "$(uname)" != "Linux" ]; then
        die "Only Linux is supported"
    fi
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "Root permission required"
    fi
}

require_root_for_write() {
    if [ "${DRY_RUN}" -eq 0 ]; then
        require_root
    fi
}

require_yes_for_danger() {
    if [ "${DRY_RUN}" -eq 0 ] && [ "${YES}" -ne 1 ]; then
        die "This operation requires --yes"
    fi
}

validate_name() {
    local label="${1:?missing label}"
    local value="${2:?missing value}"

    [ -n "${value}" ] || die "${label} must not be empty"
    case "${value}" in
        -*|*[^a-zA-Z0-9._-]*)
            die "Invalid ${label}: ${value}"
            ;;
    esac
}

validate_backup_id() {
    local value="${1:?missing backup id}"

    if [[ ! "${value}" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
        die "Invalid backup id: ${value}"
    fi
}

validate_custom_filter_name() {
    local name="${1:?missing filter name}"

    validate_name "filter name" "${name}"
    case "${name}" in
        "${CUSTOM_FILTER_PREFIX}"*)
            ;;
        *)
            die "Custom filter name must start with ${CUSTOM_FILTER_PREFIX}"
            ;;
    esac
}

validate_key() {
    local key="${1:?missing key}"

    case "${key}" in
        enabled|filter|logpath|port|maxretry|findtime|bantime|backend|ignoreip)
            ;;
        *)
            die "Unsupported jail key: ${key}"
            ;;
    esac
}

validate_no_newline() {
    local label="${1:?missing label}"
    local value="${2-}"

    case "${value}" in
        *$'\n'*|*$'\r'*)
            die "${label} must not contain newlines"
            ;;
    esac
}

validate_path_value() {
    local label="${1:?missing label}"
    local value="${2:?missing path}"

    validate_no_newline "${label}" "${value}"
    case "${value}" in
        /*)
            ;;
        *)
            die "${label} must be an absolute path: ${value}"
            ;;
    esac
    case "${value}" in
        *"/../"*|*"/.."|*".."/*)
            die "${label} must not contain path traversal: ${value}"
            ;;
    esac
}

strip_trailing_slash() {
    local value="${1:?missing path}"

    while [ "${#value}" -gt 1 ] && [[ "${value}" == */ ]]; do
        value="${value%/}"
    done
    printf '%s\n' "${value}"
}

reject_dangerous_path() {
    local label="${1:?missing label}"
    local value="${2:?missing path}"
    local path

    path="$(strip_trailing_slash "${value}")"
    case "${path}" in
        /|/etc|/home|/root|/usr|/var|/tmp|/private|/Users|/System|/bin|/sbin|/lib|/opt)
            die "${label} points to a dangerous path: ${value}"
            ;;
    esac
}

reject_symlink_path() {
    local label="${1:?missing label}"
    local value="${2:?missing path}"

    if [ -L "${value}" ]; then
        die "${label} must not be a symbolic link: ${value}"
    fi
}

reject_symlink_components() {
    local label="${1:?missing label}"
    local value="${2:?missing path}"
    local path
    local current=""
    local part
    local -a parts=()

    path="$(strip_trailing_slash "${value}")"
    IFS='/' read -r -a parts <<<"${path}"

    for part in "${parts[@]}"; do
        [ -n "${part}" ] || continue
        if [ -z "${current}" ]; then
            current="/${part}"
        else
            current="${current}/${part}"
        fi

        if [ -L "${current}" ]; then
            die "${label} contains symbolic link component: ${current}"
        fi
        if [ ! -e "${current}" ]; then
            break
        fi
    done
}

path_is_strict_child() {
    local child
    local parent

    child="$(strip_trailing_slash "${1:?missing child}")"
    parent="$(strip_trailing_slash "${2:?missing parent}")"
    [ "${child}" != "${parent}" ] || return 1
    case "${child}" in
        "${parent}/"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_path_under() {
    local label="${1:?missing label}"
    local child
    local parent

    child="$(strip_trailing_slash "${2:?missing child}")"
    parent="$(strip_trailing_slash "${3:?missing parent}")"
    if ! path_is_strict_child "${child}" "${parent}"; then
        die "${label} must be a strict child of ${parent}: ${child}"
    fi
}

require_no_path_overlap() {
    local left_label="${1:?missing left label}"
    local left
    local right_label="${3:?missing right label}"
    local right

    left="$(strip_trailing_slash "${2:?missing left path}")"
    right="$(strip_trailing_slash "${4:?missing right path}")"

    if [ "${left}" = "${right}" ]; then
        die "${left_label} and ${right_label} must not be the same path: ${left}"
    fi
    if path_is_strict_child "${left}" "${right}"; then
        die "${left_label} must not be inside ${right_label}: ${left}"
    fi
    if path_is_strict_child "${right}" "${left}"; then
        die "${right_label} must not be inside ${left_label}: ${right}"
    fi
}

require_safe_write_paths() {
    validate_path_value "config directory" "${F2B_CONFIG_DIR}"
    validate_path_value "jail directory" "${F2B_JAIL_DIR}"
    validate_path_value "filter directory" "${F2B_FILTER_DIR}"
    validate_path_value "backup directory" "${F2B_BACKUP_DIR}"

    reject_dangerous_path "config directory" "${F2B_CONFIG_DIR}"
    reject_dangerous_path "jail directory" "${F2B_JAIL_DIR}"
    reject_dangerous_path "filter directory" "${F2B_FILTER_DIR}"
    reject_dangerous_path "backup directory" "${F2B_BACKUP_DIR}"

    reject_symlink_path "config directory" "${F2B_CONFIG_DIR}"
    reject_symlink_path "jail directory" "${F2B_JAIL_DIR}"
    reject_symlink_path "filter directory" "${F2B_FILTER_DIR}"
    reject_symlink_path "backup directory" "${F2B_BACKUP_DIR}"

    reject_symlink_components "config directory" "${F2B_CONFIG_DIR}"
    reject_symlink_components "jail directory" "${F2B_JAIL_DIR}"
    reject_symlink_components "filter directory" "${F2B_FILTER_DIR}"
    reject_symlink_components "backup directory" "${F2B_BACKUP_DIR}"

    require_path_under "jail directory" "${F2B_JAIL_DIR}" "${F2B_CONFIG_DIR}"
    require_path_under "filter directory" "${F2B_FILTER_DIR}" "${F2B_CONFIG_DIR}"
    require_path_under "backup directory" "${F2B_BACKUP_DIR}" "${F2B_CONFIG_DIR}"
    require_no_path_overlap "jail directory" "${F2B_JAIL_DIR}" "filter directory" "${F2B_FILTER_DIR}"
    require_no_path_overlap "jail directory" "${F2B_JAIL_DIR}" "backup directory" "${F2B_BACKUP_DIR}"
    require_no_path_overlap "filter directory" "${F2B_FILTER_DIR}" "backup directory" "${F2B_BACKUP_DIR}"
}

validate_duration() {
    local label="${1:?missing label}"
    local value="${2:?missing duration}"

    validate_no_newline "${label}" "${value}"
    if [[ ! "${value}" =~ ^-?[0-9]+[smhdw]?$ ]]; then
        die "Invalid ${label}: ${value}"
    fi
}

validate_positive_duration() {
    local label="${1:?missing label}"
    local value="${2:?missing duration}"

    validate_no_newline "${label}" "${value}"
    if [[ ! "${value}" =~ ^[0-9]+[smhdw]?$ ]]; then
        die "Invalid ${label}: ${value}"
    fi
}

validate_positive_integer() {
    local label="${1:?missing label}"
    local value="${2:?missing value}"

    if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -eq 0 ]; then
        die "Invalid ${label}: ${value}"
    fi
}

validate_bool() {
    local label="${1:?missing label}"
    local value="${2:?missing value}"

    case "${value}" in
        true|false)
            ;;
        *)
            die "Invalid ${label}: ${value}. Use true or false"
            ;;
    esac
}

validate_ignoreip() {
    local value="${1:?missing ignoreip}"
    local token
    local normalized

    validate_no_newline "ignoreip" "${value}"
    normalized="${value//,/ }"
    for token in ${normalized}; do
        [ -n "${token}" ] || continue
        case "${token}" in
            0.0.0.0/0|::/0)
                die "ignoreip must not allow all addresses: ${token}"
                ;;
        esac
        if [[ ! "${token}" =~ ^[a-zA-Z0-9_.:-]+(/[0-9]{1,3})?$ ]]; then
            die "Invalid ignoreip token: ${token}"
        fi
    done
}

validate_jail_value() {
    local key="${1:?missing key}"
    local value="${2-}"

    validate_no_newline "${key}" "${value}"
    [ -n "${value}" ] || die "Value for ${key} must not be empty"
    case "${key}" in
        enabled)
            validate_bool "${key}" "${value}"
            ;;
        filter)
            validate_name "filter name" "${value}"
            filter_exists "${value}" || die "Filter not found: ${value}"
            ;;
        logpath)
            validate_path_value "logpath" "${value}"
            ;;
        maxretry)
            validate_positive_integer "${key}" "${value}"
            ;;
        findtime)
            validate_positive_duration "${key}" "${value}"
            ;;
        bantime)
            validate_duration "${key}" "${value}"
            ;;
        port)
            if [[ ! "${value}" =~ ^[a-zA-Z0-9_,:.-]+$ ]]; then
                die "Invalid port: ${value}"
            fi
            ;;
        backend)
            case "${value}" in
                auto|systemd|polling|gamin|pyinotify)
                    ;;
                *)
                die "Invalid backend: ${value}"
                    ;;
            esac
            ;;
        ignoreip)
            validate_ignoreip "${value}"
            ;;
        *)
            die "Unsupported jail key: ${key}"
            ;;
    esac
}

validate_ip() {
    local ip="${1:?missing ip}"
    local part
    local -a parts

    validate_no_newline "ip" "${ip}"

    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a parts <<<"${ip}"
        for part in "${parts[@]}"; do
            if [ "${part}" -gt 255 ]; then
                die "Invalid IP address: ${ip}"
            fi
        done
        return 0
    fi

    if [[ "${ip}" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "${ip}" == *:* ]]; then
        return 0
    fi

    die "Invalid IP address: ${ip}"
}

quote_cmd() {
    local part

    for part in "$@"; do
        printf '%q ' "${part}"
    done
}

run_or_print() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would run: $(quote_cmd "$@")"
        return 0
    fi

    "$@"
}

ensure_dir() {
    local dir="${1:?missing dir}"

    validate_path_value "directory" "${dir}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would create directory: ${dir}"
        return 0
    fi
    install -d -m 0755 "${dir}"
}

managed_jail_file() {
    local jail="${1:?missing jail}"

    printf '%s/%s%s.local\n' "${F2B_JAIL_DIR}" "${JAIL_FILE_PREFIX}" "${jail}"
}

filter_file() {
    local filter="${1:?missing filter}"

    printf '%s/%s.conf\n' "${F2B_FILTER_DIR}" "${filter}"
}

filter_exists() {
    local filter="${1:?missing filter}"
    local path

    path="$(filter_file "${filter}")"
    [ -f "${path}" ]
}

is_managed_file() {
    local path="${1:?missing path}"

    [ -f "${path}" ] && grep -Fq "${MANAGED_MARKER}" "${path}" 2>/dev/null
}

require_managed_file() {
    local path="${1:?missing path}"

    [ -f "${path}" ] || die "Managed file not found: ${path}"
    is_managed_file "${path}" || die "Refuse to modify unmanaged file: ${path}"
}

timestamp() {
    date '+%Y%m%d-%H%M%S'
}

new_backup_id() {
    local base
    local candidate
    local counter=1

    base="$(timestamp)"
    candidate="${base}"
    while [ -e "$(backup_path "${candidate}")" ]; do
        candidate="${base}-${counter}"
        counter=$((counter + 1))
    done
    printf '%s\n' "${candidate}"
}

create_backup_directory() {
    local base
    local candidate
    local backup_dir
    local counter=0

    base="$(timestamp)"
    while [ "${counter}" -le 100 ]; do
        if [ "${counter}" -eq 0 ]; then
            candidate="${base}"
        else
            candidate="${base}-${counter}"
        fi
        backup_dir="$(backup_path "${candidate}")"
        if mkdir "${backup_dir}" 2>/dev/null; then
            chmod 0755 "${backup_dir}"
            printf '%s\n' "${candidate}"
            return 0
        fi
        counter=$((counter + 1))
    done

    die "Cannot create unique backup directory"
}

current_iso_time() {
    date '+%Y-%m-%d %H:%M:%S %z'
}

backup_path() {
    local backup_id="${1:?missing backup id}"

    printf '%s/%s\n' "${F2B_BACKUP_DIR}" "${backup_id}"
}

path_owner_uid() {
    local path="${1:?missing path}"

    stat -c '%u' "${path}" 2>/dev/null || stat -f '%u' "${path}" 2>/dev/null || true
}

path_mode() {
    local path="${1:?missing path}"

    stat -c '%a' "${path}" 2>/dev/null || stat -f '%Lp' "${path}" 2>/dev/null || true
}

require_trusted_backup_path() {
    local path="${1:?missing path}"
    local owner_uid
    local mode

    owner_uid="$(path_owner_uid "${path}")"
    mode="$(path_mode "${path}")"

    [ -n "${owner_uid}" ] || die "Cannot inspect backup owner: ${path}"
    [ -n "${mode}" ] || die "Cannot inspect backup mode: ${path}"
    [ "${owner_uid}" -eq 0 ] || die "Backup path must be owned by root: ${path}"
    if (( (8#${mode}) & 0022 )); then
        die "Backup path must not be group/world writable: ${path}"
    fi
}

require_trusted_backup_tree() {
    local path="${1:?missing path}"

    require_trusted_backup_path "${path}"
    if find "${path}" -type l -print -quit | grep -q .; then
        die "Backup tree must not contain symlinks: ${path}"
    fi
    if find "${path}" \( -perm -002 -o -perm -020 \) -print -quit | grep -q .; then
        die "Backup tree must not contain group/world writable entries: ${path}"
    fi
    if find "${path}" ! -user root -print -quit | grep -q .; then
        die "Backup tree must be owned by root: ${path}"
    fi
}

require_valid_backup() {
    local backup_id="${1:?missing backup id}"
    local backup_dir
    local manifest

    validate_backup_id "${backup_id}"
    backup_dir="$(backup_path "${backup_id}")"
    manifest="${backup_dir}/manifest.txt"

    require_path_under "backup directory" "${backup_dir}" "${F2B_BACKUP_DIR}"
    [ "$(basename "${backup_dir}")" = "${backup_id}" ] || die "Backup directory name does not match id: ${backup_id}"
    [ -d "${backup_dir}" ] || die "Backup not found: ${backup_id}"
    [ -d "${backup_dir}/jail.d" ] || die "Backup is missing jail.d: ${backup_id}"
    [ -d "${backup_dir}/filter.d" ] || die "Backup is missing filter.d: ${backup_id}"
    [ -f "${manifest}" ] || die "Backup is missing manifest: ${backup_id}"
    grep -Fq "${MANAGED_MARKER}" "${manifest}" || die "Backup manifest is not managed by this script: ${backup_id}"
    grep -Fxq "backup_id=${backup_id}" "${manifest}" || die "Backup manifest id does not match directory: ${backup_id}"
    grep -Fxq "jail_dir=${F2B_JAIL_DIR}" "${manifest}" || die "Backup jail_dir does not match current configuration: ${backup_id}"
    grep -Fxq "filter_dir=${F2B_FILTER_DIR}" "${manifest}" || die "Backup filter_dir does not match current configuration: ${backup_id}"

    if [ "${EUID}" -eq 0 ]; then
        require_trusted_backup_path "${F2B_BACKUP_DIR}"
        require_trusted_backup_tree "${backup_dir}"
        require_trusted_backup_path "${manifest}"
        require_trusted_backup_tree "${backup_dir}/jail.d"
        require_trusted_backup_tree "${backup_dir}/filter.d"
    fi
}

create_backup() {
    local reason="${1:-manual}"
    local backup_id
    local backup_dir
    local manifest

    if [ "${DRY_RUN}" -eq 0 ]; then
        require_safe_write_paths
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        backup_id="$(new_backup_id)"
        backup_dir="$(backup_path "${backup_id}")"
        log_info "DRY-RUN Would create backup: ${backup_dir}"
        printf '%s\n' "${backup_id}"
        return 0
    fi

    ensure_dir "${F2B_BACKUP_DIR}"
    backup_id="$(create_backup_directory)"
    backup_dir="$(backup_path "${backup_id}")"
    manifest="${backup_dir}/manifest.txt"

    if [ -d "${F2B_JAIL_DIR}" ]; then
        cp -a "${F2B_JAIL_DIR}" "${backup_dir}/jail.d"
    else
        install -d -m 0755 "${backup_dir}/jail.d"
    fi

    if [ -d "${F2B_FILTER_DIR}" ]; then
        cp -a "${F2B_FILTER_DIR}" "${backup_dir}/filter.d"
    else
        install -d -m 0755 "${backup_dir}/filter.d"
    fi

    cat >"${manifest}" <<EOF
# ${MANAGED_MARKER}
# 文件用途:
#   记录 fail2ban-manager.sh 创建的备份信息。
# 配置说明:
#   backup_id 是备份目录名，可用于 backup restore。
#   reason 是触发备份的操作来源。
# 示例:
#   ${SCRIPT_NAME} backup restore ${backup_id} --yes
# 验证:
#   ${SCRIPT_NAME} service reload --dry-run

backup_id=${backup_id}
created_at=$(current_iso_time)
reason=${reason}
jail_dir=${F2B_JAIL_DIR}
filter_dir=${F2B_FILTER_DIR}
EOF

    chmod 0644 "${manifest}"
    log_info "Backup created: ${backup_dir}"
    printf '%s\n' "${backup_id}"
}

restore_one_file_from_backup() {
    local backup_id="${1:?missing backup id}"
    local kind="${2:?missing kind}"
    local target="${3:?missing target}"
    local backup_dir
    local source

    backup_dir="$(backup_path "${backup_id}")"
    source="${backup_dir}/${kind}/$(basename "${target}")"

    case "${kind}" in
        jail.d|filter.d)
            ;;
        *)
            die "Invalid backup kind: ${kind}"
            ;;
    esac

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would restore file from backup: ${target}"
        return 0
    fi

    if [ -f "${source}" ]; then
        cp -p "${source}" "${target}"
    else
        rm -f "${target}"
    fi
}

require_known_restore_target() {
    local dir
    local jail_dir
    local filter_dir

    dir="$(strip_trailing_slash "${1:?missing dir}")"
    jail_dir="$(strip_trailing_slash "${F2B_JAIL_DIR}")"
    filter_dir="$(strip_trailing_slash "${F2B_FILTER_DIR}")"

    case "${dir}" in
        "${jail_dir}"|"${filter_dir}")
            ;;
        *)
            die "Refuse to clear unexpected directory: ${dir}"
            ;;
    esac
}

clear_directory_contents() {
    local dir="${1:?missing dir}"
    local entry
    local -a entries=()

    require_known_restore_target "${dir}"
    [ -d "${dir}" ] || return 0

    shopt -s dotglob nullglob
    entries=("${dir}"/*)
    shopt -u dotglob nullglob

    for entry in "${entries[@]}"; do
        rm -rf -- "${entry}"
    done
}

restore_directory_snapshot() {
    local source="${1:?missing source}"
    local target="${2:?missing target}"

    [ -d "${source}" ] || die "Snapshot source not found: ${source}"
    require_known_restore_target "${target}"
    ensure_dir "${target}"
    clear_directory_contents "${target}"
    cp -a "${source}/." "${target}/"
}

test_config_or_rollback() {
    local backup_id="${1:?missing backup id}"
    local kind="${2:?missing kind}"
    local target="${3:?missing target}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would test fail2ban configuration"
        return 0
    fi

    require_command "${F2B_CLIENT}"
    if ! "${F2B_CLIENT}" -t; then
        log_warn "Configuration test failed, restoring previous file"
        restore_one_file_from_backup "${backup_id}" "${kind}" "${target}"
        die "Configuration test failed"
    fi
    log_info "Configuration test passed"
    log_info "Run '${SCRIPT_NAME} service reload' to apply changes"
}

write_temp_file() {
    local target="${1:?missing target}"
    local tmp="${2:?missing tmp}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would write file: ${target}"
        return 0
    fi

    mv "${tmp}" "${target}"
    chmod 0644 "${target}"
}

make_temp_for_target() {
    local target="${1:?missing target}"
    local target_dir
    local target_base

    target_dir="$(dirname "${target}")"
    target_base="$(basename "${target}")"
    mktemp "${target_dir}/.${target_base}.tmp.XXXXXX"
}

service_status() {
    require_linux

    if command_exists systemctl; then
        systemctl status --no-pager "${F2B_SERVICE_NAME}"
    elif command_exists service; then
        service "${F2B_SERVICE_NAME}" status
    else
        require_command "${F2B_CLIENT}"
        "${F2B_CLIENT}" ping
        "${F2B_CLIENT}" status
    fi
}

service_reload() {
    require_linux
    require_root_for_write
    require_client_for_real

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would test fail2ban configuration"
    else
        "${F2B_CLIENT}" -t
    fi
    run_or_print "${F2B_CLIENT}" reload
}

jail_list_from_files() {
    local file
    local base
    local jail

    [ -d "${F2B_JAIL_DIR}" ] || return 0
    for file in "${F2B_JAIL_DIR}/${JAIL_FILE_PREFIX}"*.local; do
        [ -e "${file}" ] || continue
        base="$(basename "${file}")"
        jail="${base#"${JAIL_FILE_PREFIX}"}"
        jail="${jail%.local}"
        printf '%s\n' "${jail}"
    done
}

jail_list() {
    if command_exists "${F2B_CLIENT}" && "${F2B_CLIENT}" ping >/dev/null 2>&1; then
        if [ "${OUTPUT_FORMAT}" = "kv" ]; then
            "${F2B_CLIENT}" status | awk -F: '/Jail list:/ {gsub(/^[ \t]+/, "", $2); print "jails=" $2}'
        else
            "${F2B_CLIENT}" status
        fi
        return 0
    fi

    log_warn "fail2ban-client is unavailable; showing managed jail files only"
    jail_list_from_files
}

jail_show() {
    local jail="${1:-}"
    local path

    validate_name "jail name" "${jail}"
    path="$(managed_jail_file "${jail}")"

    if command_exists "${F2B_CLIENT}" && "${F2B_CLIENT}" ping >/dev/null 2>&1; then
        "${F2B_CLIENT}" status "${jail}" || log_warn "Runtime jail status unavailable: ${jail}"
    fi

    if [ -f "${path}" ]; then
        if [ "${OUTPUT_FORMAT}" = "kv" ]; then
            printf 'jail=%s\n' "${jail}"
            printf 'managed_file=%s\n' "${path}"
        else
            printf '\n# %s\n' "${path}"
            cat "${path}"
        fi
    elif [ "${OUTPUT_FORMAT}" = "kv" ]; then
        printf 'jail=%s\nmanaged_file=\n' "${jail}"
    else
        log_warn "Managed jail file not found: ${path}"
    fi
}

write_jail_file() {
    local jail="${1:?missing jail}"
    local filter="${2:?missing filter}"
    local logpath="${3:?missing logpath}"
    local port="${4:-}"
    local maxretry="${5:?missing maxretry}"
    local findtime="${6:?missing findtime}"
    local bantime="${7:?missing bantime}"
    local enabled="${8:?missing enabled}"
    local path
    local tmp

    path="$(managed_jail_file "${jail}")"

    if [ -e "${path}" ]; then
        die "Jail file already exists: ${path}"
    fi

    validate_path_value "jail directory" "${F2B_JAIL_DIR}"
    ensure_dir "${F2B_JAIL_DIR}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would create jail file: ${path}"
        return 0
    fi

    tmp="$(make_temp_for_target "${path}")"
    cat >"${tmp}" <<EOF
# ${MANAGED_MARKER}
# 创建时间: $(current_iso_time)
# 文件用途:
#   定义 fail2ban jail，把日志路径、filter 和封禁策略组合起来。
# 配置说明:
#   enabled  是否启用 jail，true 表示启用。
#   filter   日志匹配规则名称，不带 .conf 后缀，可以引用内置 filter 或 custom-* filter。
#   logpath  被监控的日志绝对路径。
#   port     被保护的服务端口或端口组。
#   maxretry findtime 窗口内允许失败次数。
#   findtime 检测窗口，例如 10m。
#   bantime  封禁时长，例如 1h，-1 表示永久封禁。
# 示例:
#   ${SCRIPT_NAME} jail set ${jail} maxretry=10 findtime=10m bantime=1h
#   ${SCRIPT_NAME} service reload
# 验证:
#   fail2ban-client -t

[${jail}]
enabled = ${enabled}
filter = ${filter}
logpath = ${logpath}
EOF

    if [ -n "${port}" ]; then
        printf 'port = %s\n' "${port}" >>"${tmp}"
    fi

    cat >>"${tmp}" <<EOF
maxretry = ${maxretry}
findtime = ${findtime}
bantime = ${bantime}
EOF

    write_temp_file "${path}" "${tmp}"
}

jail_add() {
    local jail="${1:-}"
    local filter=""
    local logpath=""
    local port=""
    local maxretry="5"
    local findtime="10m"
    local bantime="1h"
    local enabled="true"
    local path
    local backup_id

    [ -n "${jail}" ] || die "Missing jail name"
    shift || true
    validate_name "jail name" "${jail}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --filter)
                [ "$#" -ge 2 ] || die "Missing value for --filter"
                filter="$2"
                shift 2
                ;;
            --logpath)
                [ "$#" -ge 2 ] || die "Missing value for --logpath"
                logpath="$2"
                shift 2
                ;;
            --port)
                [ "$#" -ge 2 ] || die "Missing value for --port"
                port="$2"
                shift 2
                ;;
            --maxretry)
                [ "$#" -ge 2 ] || die "Missing value for --maxretry"
                maxretry="$2"
                shift 2
                ;;
            --findtime)
                [ "$#" -ge 2 ] || die "Missing value for --findtime"
                findtime="$2"
                shift 2
                ;;
            --bantime)
                [ "$#" -ge 2 ] || die "Missing value for --bantime"
                bantime="$2"
                shift 2
                ;;
            --enabled)
                [ "$#" -ge 2 ] || die "Missing value for --enabled"
                enabled="$2"
                shift 2
                ;;
            *)
                die "Unknown jail add option: $1"
                ;;
        esac
    done

    [ -n "${filter}" ] || die "Missing --filter"
    [ -n "${logpath}" ] || die "Missing --logpath"
    validate_jail_value "filter" "${filter}"
    validate_jail_value "logpath" "${logpath}"
    validate_jail_value "maxretry" "${maxretry}"
    validate_jail_value "findtime" "${findtime}"
    validate_jail_value "bantime" "${bantime}"
    validate_jail_value "enabled" "${enabled}"
    if [ -n "${port}" ]; then
        validate_jail_value "port" "${port}"
    fi

    require_root_for_write
    require_client_for_real
    path="$(managed_jail_file "${jail}")"
    backup_id="$(create_backup "jail-add:${jail}")"
    write_jail_file "${jail}" "${filter}" "${logpath}" "${port}" "${maxretry}" "${findtime}" "${bantime}" "${enabled}"
    test_config_or_rollback "${backup_id}" "jail.d" "${path}"
}

update_jail_key_value() {
    local path="${1:?missing path}"
    local jail="${2:?missing jail}"
    local key="${3:?missing key}"
    local value="${4-}"
    local tmp

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would set ${key} in ${path}"
        return 0
    fi

    tmp="$(make_temp_for_target "${path}")"
    awk -v section="[${jail}]" -v key="${key}" -v value="${value}" '
        BEGIN {
            in_section = 0
            done = 0
        }
        $0 == section {
            in_section = 1
            print
            next
        }
        in_section && $0 ~ /^\[/ {
            if (!done) {
                print key " = " value
                done = 1
            }
            in_section = 0
        }
        in_section && $0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            split(line, parts, "=")
            current = parts[1]
            gsub(/[[:space:]]/, "", current)
            if (current == key) {
                print key " = " value
                done = 1
                next
            }
        }
        {
            print
        }
        END {
            if (in_section && !done) {
                print key " = " value
            }
        }
    ' "${path}" >"${tmp}"
    write_temp_file "${path}" "${tmp}"
}

jail_set() {
    local jail="${1:-}"
    local path
    local item
    local key
    local value
    local backup_id

    [ -n "${jail}" ] || die "Missing jail name"
    shift || true
    [ "$#" -gt 0 ] || die "Missing key=value"
    validate_name "jail name" "${jail}"
    path="$(managed_jail_file "${jail}")"
    require_managed_file "${path}"

    for item in "$@"; do
        case "${item}" in
            *=*)
                key="${item%%=*}"
                value="${item#*=}"
                ;;
            *)
                die "Invalid key=value: ${item}"
                ;;
        esac
        validate_key "${key}"
        validate_jail_value "${key}" "${value}"
    done

    require_root_for_write
    require_client_for_real
    backup_id="$(create_backup "jail-set:${jail}")"

    for item in "$@"; do
        key="${item%%=*}"
        value="${item#*=}"
        update_jail_key_value "${path}" "${jail}" "${key}" "${value}"
    done

    test_config_or_rollback "${backup_id}" "jail.d" "${path}"
}

jail_enable() {
    local jail="${1:-}"

    [ -n "${jail}" ] || die "Missing jail name"
    jail_set "${jail}" "enabled=true"
}

jail_disable() {
    local jail="${1:-}"

    [ -n "${jail}" ] || die "Missing jail name"
    jail_set "${jail}" "enabled=false"
}

jail_remove() {
    local jail="${1:-}"
    local path
    local backup_id

    [ -n "${jail}" ] || die "Missing jail name"
    validate_name "jail name" "${jail}"
    path="$(managed_jail_file "${jail}")"
    require_managed_file "${path}"
    require_yes_for_danger
    require_root_for_write
    require_client_for_real

    backup_id="$(create_backup "jail-remove:${jail}")"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would remove jail file: ${path}"
    else
        rm -f "${path}"
    fi
    test_config_or_rollback "${backup_id}" "jail.d" "${path}"
}

filter_kind() {
    local path="${1:?missing path}"
    local base
    local name

    base="$(basename "${path}")"
    name="${base%.conf}"
    if [[ "${name}" == "${CUSTOM_FILTER_PREFIX}"* ]] || is_managed_file "${path}"; then
        printf 'custom\n'
    else
        printf 'builtin\n'
    fi
}

filter_list() {
    local mode="all"
    local file
    local base
    local name
    local kind

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --builtin)
                mode="builtin"
                shift
                ;;
            --custom)
                mode="custom"
                shift
                ;;
            *)
                die "Unknown filter list option: $1"
                ;;
        esac
    done

    [ -d "${F2B_FILTER_DIR}" ] || return 0
    for file in "${F2B_FILTER_DIR}"/*.conf; do
        [ -e "${file}" ] || continue
        base="$(basename "${file}")"
        name="${base%.conf}"
        kind="$(filter_kind "${file}")"
        if [ "${mode}" != "all" ] && [ "${mode}" != "${kind}" ]; then
            continue
        fi
        if [ "${OUTPUT_FORMAT}" = "kv" ]; then
            printf 'filter=%s kind=%s file=%s\n' "${name}" "${kind}" "${file}"
        else
            printf '%-8s %s\n' "${kind}" "${name}"
        fi
    done
}

filter_show() {
    local filter="${1:-}"
    local path

    [ -n "${filter}" ] || die "Missing filter name"
    validate_name "filter name" "${filter}"
    path="$(filter_file "${filter}")"
    [ -f "${path}" ] || die "Filter not found: ${filter}"
    cat "${path}"
}

write_filter_file() {
    local filter="${1:?missing filter}"
    local failregex="${2:?missing failregex}"
    local ignoreregex="${3-}"
    local path
    local tmp

    path="$(filter_file "${filter}")"
    if [ -e "${path}" ]; then
        die "Filter file already exists: ${path}"
    fi

    validate_path_value "filter directory" "${F2B_FILTER_DIR}"
    ensure_dir "${F2B_FILTER_DIR}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would create filter file: ${path}"
        return 0
    fi

    tmp="$(make_temp_for_target "${path}")"
    cat >"${tmp}" <<EOF
# ${MANAGED_MARKER}
# 创建时间: $(current_iso_time)
# 文件用途:
#   定义自定义 fail2ban filter，用于从日志行中识别失败或异常行为。
# 配置说明:
#   failregex   匹配失败日志的正则，必须使用 <HOST> 标记来源 IP。
#   ignoreregex 可选，匹配后需要忽略的日志。
# 示例日志:
#   1.2.3.4 - - [21/Jun/2026:10:00:00 +0800] "GET /bad-path HTTP/1.1" 404 123
# 示例命令:
#   ${SCRIPT_NAME} filter test ${filter} --logfile /var/log/example.log
#   ${SCRIPT_NAME} jail add example --filter ${filter} --logpath /var/log/example.log
# 验证:
#   fail2ban-regex /var/log/example.log ${path}

[Definition]
failregex = ${failregex}
ignoreregex = ${ignoreregex}
EOF

    write_temp_file "${path}" "${tmp}"
}

filter_add() {
    local filter="${1:-}"
    local failregex=""
    local ignoreregex=""
    local path
    local backup_id

    [ -n "${filter}" ] || die "Missing filter name"
    shift || true
    validate_custom_filter_name "${filter}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --failregex)
                [ "$#" -ge 2 ] || die "Missing value for --failregex"
                failregex="$2"
                shift 2
                ;;
            --ignoreregex)
                [ "$#" -ge 2 ] || die "Missing value for --ignoreregex"
                ignoreregex="$2"
                shift 2
                ;;
            *)
                die "Unknown filter add option: $1"
                ;;
        esac
    done

    [ -n "${failregex}" ] || die "Missing --failregex"
    validate_no_newline "failregex" "${failregex}"
    validate_no_newline "ignoreregex" "${ignoreregex}"
    case "${failregex}" in
        *"<HOST>"*)
            ;;
        *)
            die "failregex must contain <HOST>"
            ;;
    esac

    require_root_for_write
    require_client_for_real
    path="$(filter_file "${filter}")"
    backup_id="$(create_backup "filter-add:${filter}")"
    write_filter_file "${filter}" "${failregex}" "${ignoreregex}"
    test_config_or_rollback "${backup_id}" "filter.d" "${path}"
}

filter_import() {
    local filter="${1:-}"
    local source=""
    local path
    local tmp
    local backup_id

    [ -n "${filter}" ] || die "Missing filter name"
    shift || true
    validate_custom_filter_name "${filter}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source)
                [ "$#" -ge 2 ] || die "Missing value for --source"
                source="$2"
                shift 2
                ;;
            *)
                die "Unknown filter import option: $1"
                ;;
        esac
    done

    [ -n "${source}" ] || die "Missing --source"
    validate_path_value "source" "${source}"
    [ -r "${source}" ] || die "Source file is not readable: ${source}"
    grep -q '^\[Definition\]' "${source}" || die "Source filter must contain [Definition]"

    require_root_for_write
    require_client_for_real

    path="$(filter_file "${filter}")"
    [ ! -e "${path}" ] || die "Filter file already exists: ${path}"
    backup_id="$(create_backup "filter-import:${filter}")"
    validate_path_value "filter directory" "${F2B_FILTER_DIR}"
    ensure_dir "${F2B_FILTER_DIR}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would import filter file: ${source} -> ${path}"
    else
        tmp="$(make_temp_for_target "${path}")"
        cat >"${tmp}" <<EOF
# ${MANAGED_MARKER}
# 创建时间: $(current_iso_time)
# 文件用途:
#   从已有 filter 文件导入的自定义 fail2ban filter。
# 配置说明:
#   下方内容来自 source 文件，脚本只补充管理注释。
# 示例命令:
#   ${SCRIPT_NAME} filter test ${filter} --logfile /var/log/example.log
#   ${SCRIPT_NAME} jail add example --filter ${filter} --logpath /var/log/example.log
# 验证:
#   fail2ban-regex /var/log/example.log ${path}
# Source: ${source}

EOF
        cat "${source}" >>"${tmp}"
        write_temp_file "${path}" "${tmp}"
    fi

    test_config_or_rollback "${backup_id}" "filter.d" "${path}"
}

filter_is_referenced() {
    local filter="${1:?missing filter}"
    local file
    local -a candidates=()

    candidates=(
        "${F2B_JAIL_DIR}"/*.local
        "${F2B_JAIL_DIR}"/*.conf
        "${F2B_CONFIG_DIR}/jail.local"
        "${F2B_CONFIG_DIR}/jail.conf"
    )
    for file in "${candidates[@]}"; do
        [ -f "${file}" ] || continue
        if awk -v expected="${filter}" '
            /^[[:space:]]*#/ {
                next
            }
            /^[[:space:]]*filter[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=/, "", value)
                sub(/[[:space:]]*[#;].*$/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (value == expected) {
                    matched = 1
                }
            }
            END {
                exit matched ? 0 : 1
            }
        ' "${file}"; then
            printf '%s\n' "${file}"
            return 0
        fi
    done
    return 1
}

filter_test() {
    local filter="${1:-}"
    local logfile=""
    local path

    [ -n "${filter}" ] || die "Missing filter name"
    shift || true
    validate_name "filter name" "${filter}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --logfile)
                [ "$#" -ge 2 ] || die "Missing value for --logfile"
                logfile="$2"
                shift 2
                ;;
            *)
                die "Unknown filter test option: $1"
                ;;
        esac
    done

    [ -n "${logfile}" ] || die "Missing --logfile"
    validate_path_value "logfile" "${logfile}"
    [ -r "${logfile}" ] || die "Log file is not readable: ${logfile}"
    path="$(filter_file "${filter}")"
    [ -f "${path}" ] || die "Filter not found: ${filter}"
    require_command "${F2B_REGEX}"
    "${F2B_REGEX}" "${logfile}" "${path}"
}

filter_remove() {
    local filter="${1:-}"
    local path
    local referenced_by
    local backup_id

    [ -n "${filter}" ] || die "Missing filter name"
    validate_custom_filter_name "${filter}"
    path="$(filter_file "${filter}")"
    require_managed_file "${path}"

    if referenced_by="$(filter_is_referenced "${filter}")"; then
        die "Filter is still referenced by: ${referenced_by}"
    fi

    require_yes_for_danger
    require_root_for_write
    require_client_for_real
    backup_id="$(create_backup "filter-remove:${filter}")"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would remove filter file: ${path}"
    else
        rm -f "${path}"
    fi
    test_config_or_rollback "${backup_id}" "filter.d" "${path}"
}

ban_list() {
    local jail="${1:-}"

    [ -n "${jail}" ] || die "Missing jail name"
    validate_name "jail name" "${jail}"
    require_command "${F2B_CLIENT}"
    "${F2B_CLIENT}" status "${jail}"
}

ban_add() {
    local jail="${1:-}"
    local ip="${2:-}"

    [ -n "${jail}" ] || die "Missing jail name"
    [ -n "${ip}" ] || die "Missing IP address"
    validate_name "jail name" "${jail}"
    validate_ip "${ip}"
    require_root_for_write
    require_client_for_real
    run_or_print "${F2B_CLIENT}" set "${jail}" banip "${ip}"
}

ban_remove() {
    local jail="${1:-}"
    local ip="${2:-}"

    [ -n "${jail}" ] || die "Missing jail name"
    [ -n "${ip}" ] || die "Missing IP address"
    validate_name "jail name" "${jail}"
    validate_ip "${ip}"
    require_root_for_write
    require_client_for_real
    run_or_print "${F2B_CLIENT}" set "${jail}" unbanip "${ip}"
}

backup_create_command() {
    require_root_for_write
    create_backup "manual" >/dev/null
}

backup_list() {
    local dir

    [ -d "${F2B_BACKUP_DIR}" ] || return 0
    for dir in "${F2B_BACKUP_DIR}"/*; do
        [ -d "${dir}" ] || continue
        basename "${dir}"
    done
}

backup_restore() {
    local backup_id="${1:-}"
    local backup_dir
    local pre_restore_id

    [ -n "${backup_id}" ] || die "Missing backup id"
    if [ "${DRY_RUN}" -eq 0 ]; then
        require_safe_write_paths
    fi
    require_valid_backup "${backup_id}"
    backup_dir="$(backup_path "${backup_id}")"

    require_yes_for_danger
    require_root_for_write
    require_client_for_real

    pre_restore_id="$(create_backup "backup-restore-before:${backup_id}")"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "DRY-RUN Would restore backup: ${backup_id}"
        log_info "DRY-RUN Would replace ${F2B_JAIL_DIR} with ${backup_dir}/jail.d"
        log_info "DRY-RUN Would replace ${F2B_FILTER_DIR} with ${backup_dir}/filter.d"
        return 0
    fi

    restore_directory_snapshot "${backup_dir}/jail.d" "${F2B_JAIL_DIR}"
    restore_directory_snapshot "${backup_dir}/filter.d" "${F2B_FILTER_DIR}"

    if ! "${F2B_CLIENT}" -t; then
        log_warn "Restored backup failed configuration test, rolling back to ${pre_restore_id}"
        restore_directory_snapshot "$(backup_path "${pre_restore_id}")/jail.d" "${F2B_JAIL_DIR}"
        restore_directory_snapshot "$(backup_path "${pre_restore_id}")/filter.d" "${F2B_FILTER_DIR}"
        die "Backup restore failed configuration test"
    fi

    log_info "Backup restored: ${backup_id}"
    log_info "Run '${SCRIPT_NAME} service reload' to apply changes"
}

doctor_check_path() {
    local label="${1:?missing label}"
    local path="${2:?missing path}"

    if [ -e "${path}" ]; then
        printf 'OK   %-18s %s\n' "${label}" "${path}"
    else
        printf 'WARN %-18s %s\n' "${label}" "${path}"
    fi
}

doctor() {
    printf 'fail2ban-manager doctor\n'
    printf 'system=%s\n' "$(uname -s)"
    printf 'user=%s\n' "$(id -un)"

    if [ "${EUID}" -eq 0 ]; then
        printf 'OK   root              yes\n'
    else
        printf 'WARN root              no\n'
    fi

    if command_exists "${F2B_CLIENT}"; then
        printf 'OK   fail2ban-client   %s\n' "$(command -v "${F2B_CLIENT}")"
        if "${F2B_CLIENT}" ping >/dev/null 2>&1; then
            printf 'OK   client-ping       success\n'
        else
            printf 'WARN client-ping       failed\n'
        fi
    else
        printf 'WARN fail2ban-client   missing\n'
    fi

    if command_exists "${F2B_REGEX}"; then
        printf 'OK   fail2ban-regex    %s\n' "$(command -v "${F2B_REGEX}")"
    else
        printf 'WARN fail2ban-regex    missing\n'
    fi

    if command_exists systemctl; then
        printf 'OK   service-manager   systemctl\n'
    elif command_exists service; then
        printf 'OK   service-manager   service\n'
    else
        printf 'WARN service-manager   missing\n'
    fi

    doctor_check_path "config-dir" "${F2B_CONFIG_DIR}"
    doctor_check_path "jail-dir" "${F2B_JAIL_DIR}"
    doctor_check_path "filter-dir" "${F2B_FILTER_DIR}"
    doctor_check_path "backup-dir" "${F2B_BACKUP_DIR}"
}

dispatch_service() {
    local action="${1:-}"

    shift || true
    case "${action}" in
        status)
            [ "$#" -eq 0 ] || die "service status does not accept extra arguments"
            service_status
            ;;
        reload)
            [ "$#" -eq 0 ] || die "service reload does not accept extra arguments"
            service_reload
            ;;
        *)
            die "Unknown service action: ${action:-}"
            ;;
    esac
}

dispatch_jail() {
    local action="${1:-}"

    shift || true
    case "${action}" in
        list)
            [ "$#" -eq 0 ] || die "jail list does not accept extra arguments"
            jail_list
            ;;
        show)
            jail_show "$@"
            ;;
        add)
            jail_add "$@"
            ;;
        set)
            jail_set "$@"
            ;;
        enable)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} jail enable <jail>"
            jail_enable "$1"
            ;;
        disable)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} jail disable <jail>"
            jail_disable "$1"
            ;;
        remove)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} jail remove <jail> --yes"
            jail_remove "$1"
            ;;
        *)
            die "Unknown jail action: ${action:-}"
            ;;
    esac
}

dispatch_filter() {
    local action="${1:-}"

    shift || true
    case "${action}" in
        list)
            filter_list "$@"
            ;;
        show)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} filter show <filter>"
            filter_show "$1"
            ;;
        add)
            filter_add "$@"
            ;;
        import)
            filter_import "$@"
            ;;
        test)
            filter_test "$@"
            ;;
        remove)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} filter remove <filter> --yes"
            filter_remove "$1"
            ;;
        *)
            die "Unknown filter action: ${action:-}"
            ;;
    esac
}

dispatch_ban() {
    local action="${1:-}"

    shift || true
    case "${action}" in
        list)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} ban list <jail>"
            ban_list "$1"
            ;;
        add)
            [ "$#" -eq 2 ] || die "Usage: ${SCRIPT_NAME} ban add <jail> <ip>"
            ban_add "$1" "$2"
            ;;
        remove)
            [ "$#" -eq 2 ] || die "Usage: ${SCRIPT_NAME} ban remove <jail> <ip>"
            ban_remove "$1" "$2"
            ;;
        *)
            die "Unknown ban action: ${action:-}"
            ;;
    esac
}

dispatch_backup() {
    local action="${1:-}"

    shift || true
    case "${action}" in
        create)
            [ "$#" -eq 0 ] || die "backup create does not accept extra arguments"
            backup_create_command
            ;;
        list)
            [ "$#" -eq 0 ] || die "backup list does not accept extra arguments"
            backup_list
            ;;
        restore)
            [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} backup restore <backup-id> --yes"
            backup_restore "$1"
            ;;
        *)
            die "Unknown backup action: ${action:-}"
            ;;
    esac
}

main() {
    local resource="${1:-}"

    if [ -z "${resource}" ]; then
        usage
        exit 1
    fi
    shift || true

    log_debug "F2B_CONFIG_DIR=${F2B_CONFIG_DIR}"
    log_debug "F2B_JAIL_DIR=${F2B_JAIL_DIR}"
    log_debug "F2B_FILTER_DIR=${F2B_FILTER_DIR}"
    log_debug "F2B_BACKUP_DIR=${F2B_BACKUP_DIR}"

    case "${resource}" in
        service)
            dispatch_service "$@"
            ;;
        jail)
            dispatch_jail "$@"
            ;;
        filter)
            dispatch_filter "$@"
            ;;
        ban)
            dispatch_ban "$@"
            ;;
        backup)
            dispatch_backup "$@"
            ;;
        doctor)
            [ "$#" -eq 0 ] || die "doctor does not accept extra arguments"
            doctor
            ;;
        *)
            die "Unknown resource: ${resource}"
            ;;
    esac
}

parse_global_args "$@"
main "${POSITIONAL_ARGS[@]}"
