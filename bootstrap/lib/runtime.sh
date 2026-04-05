#!/bin/bash

resolve_script_dir() {
    local source_path="${1:-${PWD}}"
    local rpath=""

    if [ -n "${source_path}" ]; then
        rpath="$(readlink "${source_path}" 2>/dev/null || true)"
    fi

    if [ -z "${rpath}" ]; then
        rpath="${source_path}"
    elif printf '%s' "${rpath}" | grep -q '^/'; then
        :
    else
        rpath="$(dirname "${source_path}")/${rpath}"
    fi

    (
        cd "$(dirname "${rpath}")" && pwd
    )
}

# shellcheck disable=SC2034
this="$(resolve_script_dir "${INIT_CALLER_SOURCE:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}")"
INIT_LIB_DIR="$(resolve_script_dir "${BASH_SOURCE[0]}")"
INIT_REPO_ROOT="$(CDPATH='' cd -- "${INIT_LIB_DIR}/../.." && pwd)"
export INIT_LIB_DIR INIT_REPO_ROOT

INIT_TARGET_USER="${SUDO_USER:-$(id -un)}"
if [ -n "${INIT_HOME:-}" ]; then
    INIT_TARGET_HOME="${INIT_HOME}"
elif [ -n "${SUDO_USER:-}" ]; then
    INIT_TARGET_HOME="$(eval echo ~"${INIT_TARGET_USER}")"
elif [ -n "${HOME:-}" ]; then
    INIT_TARGET_HOME="${HOME}"
else
    INIT_TARGET_HOME="$(eval echo ~"${INIT_TARGET_USER}")"
fi
export INIT_TARGET_USER INIT_TARGET_HOME

if ! printf ':%s:' "${PATH}" | grep -q ':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'; then
    export PATH="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
    export PATH
fi

if command -v tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "${ncolors:-}" ] && [ "${ncolors}" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    MAGENTA="$(tput setaf 5)"
    CYAN="$(tput setaf 6)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    MAGENTA=""
    BOLD=""
    NORMAL=""
fi
NC="${NORMAL}"
# shellcheck disable=SC2034
red="${RED}"
# shellcheck disable=SC2034
green="${GREEN}"
# shellcheck disable=SC2034
yellow="${YELLOW}"
# shellcheck disable=SC2034
blue="${BLUE}"
# shellcheck disable=SC2034
magenta="${MAGENTA}"
# shellcheck disable=SC2034
cyan="${CYAN}"
# shellcheck disable=SC2034
bold="${BOLD}"
# shellcheck disable=SC2034
reset="${NORMAL}"

LOG_LEVEL_FATAL=1
LOG_LEVEL_ERROR=2
LOG_LEVEL_WARNING=3
LOG_LEVEL_SUCCESS=4
LOG_LEVEL_INFO=5
LOG_LEVEL_DEBUG=6
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"

err_require_command=100
err_require_root=200
err_require_linux=300
err_create_dir=400

_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_require_command() {
    if ! _command_exists "$1"; then
        echo "Require command $1" 1>&2
        exit "${err_require_command}"
    fi
}

_require_commands() {
    local error_no=0
    local command_name

    for command_name in "$@"; do
        if ! _command_exists "${command_name}"; then
            echo "need command ${command_name}" 1>&2
            error_no=$((error_no + 1))
        fi
    done

    if ((error_no > 0)); then
        exit "${err_require_command}"
    fi
}

_ensureDir() {
    local dir
    for dir in "$@"; do
        if [ ! -d "${dir}" ]; then
            mkdir -p "${dir}" || {
                echo "create ${dir} failed!"
                exit "${err_create_dir}"
            }
        fi
    done
}

_ensure_parent_dir() {
    local path="${1:?missing path}"
    _ensureDir "$(dirname "${path}")"
}

_timestamp() {
    date "+%Y%m%d%H%M%S"
}

_backup_existing_path() {
    local path="${1:?missing path}"
    local backup_path

    [ -e "${path}" ] || [ -L "${path}" ] || return 0

    backup_path="${path}.init.bak.$(_timestamp)"
    mv "${path}" "${backup_path}"
    log WARNING "Backed up existing ${path} to ${backup_path}"
}

_files_match() {
    local left="${1:?missing left path}"
    local right="${2:?missing right path}"

    [ -f "${left}" ] || return 1
    [ -f "${right}" ] || return 1
    cmp -s "${left}" "${right}"
}

_git_remote_matches() {
    local repo_dir="${1:?missing repo dir}"
    local expected_remote="${2:?missing expected remote}"
    local current_remote

    [ -d "${repo_dir}/.git" ] || return 1
    current_remote="$(git -C "${repo_dir}" config --get remote.origin.url 2>/dev/null)"
    [ "${current_remote}" = "${expected_remote}" ]
}

_kv_file_get() {
    local file="${1:?missing file}"
    local key="${2:?missing key}"

    [ -f "${file}" ] || return 1
    awk -F= -v key="${key}" '$1 == key { print $2 }' "${file}"
}

_write_kv_file() {
    local file="${1:?missing file}"
    shift

    if [ $(( $# % 2 )) -ne 0 ]; then
        echo "need key/value pairs for ${file}" >&2
        return 1
    fi

    _ensure_parent_dir "${file}"
    : >"${file}"

    while [ $# -gt 0 ]; do
        printf '%s=%s\n' "$1" "$2" >>"${file}"
        shift 2
    done
}

_canonicalize_path() {
    local path="${1:?missing path}"
    local dir
    local base

    if [ -L "${path}" ]; then
        dir="$(CDPATH='' cd -- "$(dirname -- "${path}")" && pwd -P)" || return 1
        path="$(readlink "${path}")"
        case "${path}" in
        /*)
            ;;
        *)
            path="${dir}/${path}"
            ;;
        esac
    fi

    [ -e "${path}" ] || [ -L "${path}" ] || return 1

    dir="$(CDPATH='' cd -- "$(dirname -- "${path}")" && pwd -P)" || return 1
    base="$(basename -- "${path}")"
    printf '%s/%s\n' "${dir}" "${base}"
}

_path_matches_target() {
    local path="${1:?missing path}"
    local expected_target="${2:?missing expected target}"
    local current_target
    local current_resolved
    local expected_resolved

    [ -L "${path}" ] || return 1

    current_target="$(readlink "${path}")"
    if [ "${current_target}" = "${expected_target}" ]; then
        return 0
    fi

    current_resolved="$(_canonicalize_path "${path}")" || return 1
    expected_resolved="$(_canonicalize_path "${expected_target}")" || return 1
    [ "${current_resolved}" = "${expected_resolved}" ]
}

_ensure_symlink() {
    local target="${1:?missing target}"
    local path="${2:?missing path}"

    _ensure_parent_dir "${path}"

    if _path_matches_target "${path}" "${target}"; then
        return 0
    fi

    if [ -e "${path}" ] || [ -L "${path}" ]; then
        _backup_existing_path "${path}"
    fi

    ln -s "${target}" "${path}"
}

_init_resolve_script_dir() {
    resolve_script_dir "$@"
}

rootID=0

_root() {
    if [ "${EUID}" -ne "${rootID}" ]; then
        echo "need root privilege." 1>&2
        return "${err_require_root}"
    fi
}

_require_root() {
    if ! _root; then
        exit "${err_require_root}"
    fi
}

_linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "need Linux" 1>&2
        return "${err_require_linux}"
    fi
}

_require_linux() {
    if ! _linux; then
        exit "${err_require_linux}"
    fi
}

_wait() {
    local secs="${1:?'missing seconds'}"

    while [ "${secs}" -gt 0 ]; do
        echo -ne "${secs}\033[0K\r"
        sleep 1
        : $((secs--))
    done
    echo -ne "\033[0K\r"
}

_parseOptions() {
    # shellcheck disable=SC2034
    local options

    if [ "$(uname)" != "Linux" ]; then
        echo "getopt only on Linux"
        exit 1
    fi

    if ! options=$(getopt -o dv --long debug --long name: -- "$@"); then
        echo "Incorrect option provided"
        exit 1
    fi
    eval set -- "${options}"
    while true; do
        case "$1" in
        -v)
            # shellcheck disable=SC2034
            VERBOSE=1
            ;;
        -d | --debug)
            # shellcheck disable=SC2034
            DEBUG=1
            ;;
        --name)
            shift
            # shellcheck disable=SC2034
            NAME="$1"
            ;;
        --)
            shift
            break
            ;;
        esac
        shift
    done
}

# shellcheck disable=SC2034
ed="vi"
if _command_exists vim; then
    ed="vim"
fi
if _command_exists nvim; then
    ed="nvim"
fi
if [ -n "${editor:-}" ]; then
    ed="${editor}"
fi
export ed

checkRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: 'sudo' command is required." >&2
            return 1
        fi

        echo "Checking if you have sudo privileges..."
        if ! sudo -v 2>/dev/null; then
            echo "You do NOT have sudo privileges or failed to enter password." >&2
            return 1
        fi
    fi
}

_checkRoot() {
    checkRoot
}

runAsRoot() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "Running as root: $*"
        "$@"
    else
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: 'sudo' is required but not found." >&2
            return 1
        fi
        echo "Using sudo: $*"
        sudo "$@"
    fi
}

_runAsRoot() {
    if [ -t 0 ]; then
        if [ $# -eq 0 ]; then
            echo "Usage: _runAsRoot <command> [args...]" >&2
            return 1
        fi
        echo "[Running as root]: $*"
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            sudo "$@"
        fi
    else
        echo "[Running script as root via stdin]"
        if [ "$(id -u)" -eq 0 ]; then
            bash -s
        elif command -v sudo >/dev/null 2>&1; then
            sudo -E bash -s
        elif command -v su >/dev/null 2>&1; then
            su -c "bash -s"
        else
            echo "Error: need sudo or su to run as root." >&2
            return 1
        fi
    fi
}

LOG_LEVELS=("FATAL" "ERROR" "WARNING" "INFO" "SUCCESS" "DEBUG")
MAX_LEVEL_LENGTH=0

for level in "${LOG_LEVELS[@]}"; do
    local_len=${#level}
    if ((local_len > MAX_LEVEL_LENGTH)); then
        MAX_LEVEL_LENGTH=${local_len}
    fi
done
MAX_LEVEL_LENGTH=$((MAX_LEVEL_LENGTH + 2))

pad_level() {
    printf "%-${MAX_LEVEL_LENGTH}s" "[$1]"
}

log() {
    local level
    level="$(echo "$1" | awk '{print toupper($0)}')"
    shift
    local message="$*"
    local padded_level
    local timestamp

    padded_level="$(pad_level "${level}")"
    timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
    case "${level}" in
    FATAL)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_FATAL}" ]; then
            echo -e "${RED}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
            exit 1
        fi
        ;;
    ERROR)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_ERROR}" ]; then
            echo -e "${RED}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
        fi
        ;;
    WARNING)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_WARNING}" ]; then
            echo -e "${YELLOW}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
        fi
        ;;
    INFO)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_INFO}" ]; then
            echo -e "${BLUE}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
        fi
        ;;
    SUCCESS)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_SUCCESS}" ]; then
            echo -e "${GREEN}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
        fi
        ;;
    DEBUG)
        if [ "${LOG_LEVEL}" -ge "${LOG_LEVEL_DEBUG}" ]; then
            echo -e "${CYAN}${BOLD}[${timestamp}] ${padded_level}${NC} ${message}${NORMAL}"
        fi
        ;;
    *)
        echo -e "${NC}[${timestamp}] [${level}] ${message}${NORMAL}"
        ;;
    esac
}

set_log_level() {
    local level
    level="$(echo "$1" | awk '{print toupper($0)}')"
    case "${level}" in
    FATAL)
        LOG_LEVEL="${LOG_LEVEL_FATAL}"
        ;;
    ERROR)
        LOG_LEVEL="${LOG_LEVEL_ERROR}"
        ;;
    WARNING)
        LOG_LEVEL="${LOG_LEVEL_WARNING}"
        ;;
    INFO)
        LOG_LEVEL="${LOG_LEVEL_INFO}"
        ;;
    SUCCESS)
        LOG_LEVEL="${LOG_LEVEL_SUCCESS}"
        ;;
    DEBUG)
        LOG_LEVEL="${LOG_LEVEL_DEBUG}"
        ;;
    *)
        echo "无效的日志级别: $1"
        ;;
    esac
}

_print_help_section() {
    local title="${1:?missing title}"
    local array_name="${2:?missing array name}"
    # shellcheck disable=SC2034
    local line

    printf '%s:\n' "${title}"
    eval "for line in \"\${${array_name}[@]}\"; do printf '  %s\n' \"\${line}\"; done"
}

_show_standard_help() {
    local usage="${1:?missing usage}"
    local commands_array="${2:?missing commands array}"
    local options_array="${3:-}"
    local title
    local array_name

    printf 'Usage: %s\n\n' "${usage}"
    _print_help_section "Commands" "${commands_array}"

    if [ -n "${options_array}" ]; then
        printf '\n'
        _print_help_section "Options" "${options_array}"
    fi

    shift 3
    while [ $# -gt 0 ]; do
        title="${1:?missing section title}"
        array_name="${2:?missing section array}"
        printf '\n'
        _print_help_section "${title}" "${array_name}"
        shift 2
    done
}

_resolve_cli_handler() {
    printf '%s\n' "${1:?missing command}"
}

_dispatch_cli() {
    local help_fn="${1:?missing help function}"
    local resolver_fn="${2:-_resolve_cli_handler}"
    local opt
    local command
    local handler

    shift 2

    OPTIND=1
    while getopts ":l:" opt; do
        case "${opt}" in
        l)
            set_log_level "${OPTARG}"
            ;;
        \?)
            "${help_fn}"
            return 1
            ;;
        :)
            echo "Invalid option: ${OPTARG} requires an argument" >&2
            "${help_fn}"
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    command="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    if [ "${command}" = "help" ]; then
        "${help_fn}"
        return 0
    fi

    handler="$("${resolver_fn}" "${command}")" || return 1
    if [ -z "${handler}" ] || ! declare -F "${handler}" >/dev/null 2>&1; then
        echo "Unknown command: ${command}" >&2
        "${help_fn}"
        return 1
    fi

    "${handler}" "$@"
}

command_exists() {
    _command_exists "$@"
}

require_command() {
    _require_command "$@"
}

require_commands() {
    _require_commands "$@"
}

ensure_dir() {
    _ensureDir "$@"
}

ensure_parent_dir() {
    _ensure_parent_dir "$@"
}

backup_path_if_needed() {
    _backup_existing_path "$@"
}

files_are_identical() {
    _files_match "$@"
}

git_remote_matches() {
    _git_remote_matches "$@"
}

kv_file_get() {
    _kv_file_get "$@"
}

kv_file_write() {
    _write_kv_file "$@"
}

canonicalize_path() {
    _canonicalize_path "$@"
}

path_matches_target() {
    _path_matches_target "$@"
}

ensure_symlink() {
    _ensure_symlink "$@"
}

wait_seconds() {
    _wait "$@"
}

show_standard_help() {
    _show_standard_help "$@"
}

resolve_cli_handler() {
    _resolve_cli_handler "$@"
}

dispatch_cli() {
    _dispatch_cli "$@"
}
