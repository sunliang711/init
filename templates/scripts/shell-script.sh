#!/bin/bash

_init_resolve_script_dir() {
    local source_path="${1:-$0}"
    local resolved_path=""

    if [ -n "${source_path}" ] && [ -e "${source_path}" ]; then
        resolved_path="$(readlink "${source_path}" 2>/dev/null || true)"
    fi

    if [ -z "${resolved_path}" ]; then
        resolved_path="${source_path}"
    elif printf '%s' "${resolved_path}" | grep -q '^/'; then
        :
    else
        resolved_path="$(dirname "${source_path}")/${resolved_path}"
    fi

    (
        cd "$(dirname "${resolved_path}")" && pwd
    )
}

SCRIPT_DIR="$(_init_resolve_script_dir "${BASH_SOURCE[0]:-$0}")"
THIS="${SCRIPT_DIR}"
INIT_TARGET_USER="${SUDO_USER:-$(id -un)}"
if [ -n "${SUDO_USER:-}" ]; then
    INIT_TARGET_HOME="$(eval echo ~"${INIT_TARGET_USER}")"
elif [ -n "${HOME:-}" ]; then
    INIT_TARGET_HOME="${HOME}"
else
    INIT_TARGET_HOME="$(eval echo ~"${INIT_TARGET_USER}")"
fi
export SCRIPT_DIR THIS INIT_TARGET_USER INIT_TARGET_HOME

if ! printf ':%s:' "${PATH}" | grep -q ':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:'; then
    export PATH="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
    export PATH
fi

if command -v tput >/dev/null 2>&1; then
    INIT_NCOLORS="$(tput colors 2>/dev/null)"
fi
if [ -t 1 ] && [ -n "${INIT_NCOLORS:-}" ] && [ "${INIT_NCOLORS}" -ge 8 ]; then
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
    BLUE=""
    MAGENTA=""
    CYAN=""
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

ERR_REQUIRE_COMMAND=100
ERR_REQUIRE_ROOT=200
ERR_REQUIRE_LINUX=300
ERR_CREATE_DIR=400

_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_require_command() {
    if ! _command_exists "$1"; then
        echo "Require command $1" >&2
        exit "${ERR_REQUIRE_COMMAND}"
    fi
}

_require_commands() {
    local error_count=0
    local command_name

    for command_name in "$@"; do
        if ! _command_exists "${command_name}"; then
            echo "need command ${command_name}" >&2
            error_count=$((error_count + 1))
        fi
    done

    if [ "${error_count}" -gt 0 ]; then
        exit "${ERR_REQUIRE_COMMAND}"
    fi
}

_ensureDir() {
    local dir

    for dir in "$@"; do
        if [ ! -d "${dir}" ]; then
            mkdir -p "${dir}" || {
                echo "create ${dir} failed!" >&2
                exit "${ERR_CREATE_DIR}"
            }
        fi
    done
}

_ensure_parent_dir() {
    local path="${1:?missing path}"
    _ensureDir "$(dirname "${path}")"
}

_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo "need root privilege." >&2
        return "${ERR_REQUIRE_ROOT}"
    fi
}

_require_root() {
    if ! _root; then
        exit "${ERR_REQUIRE_ROOT}"
    fi
}

_linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "need Linux" >&2
        return "${ERR_REQUIRE_LINUX}"
    fi
}

_require_linux() {
    if ! _linux; then
        exit "${ERR_REQUIRE_LINUX}"
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

_runAsRoot() {
    if [ -t 0 ]; then
        if [ $# -eq 0 ]; then
            echo "Usage: _runAsRoot <command> [args...]" >&2
            return 1
        fi

        echo "[Running as root]: $*"
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        elif command -v sudo >/dev/null 2>&1; then
            sudo "$@"
        elif command -v su >/dev/null 2>&1; then
            su -c "$(printf '%q ' "$@")"
        else
            echo "Error: need sudo or su to run as root." >&2
            return 1
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

_run() {
    if [ $# -gt 0 ]; then
        (
            set -x
            "$@"
        )
    elif [ ! -t 0 ]; then
        (
            set -x
            bash -s
        )
    else
        echo "Usage: _run <command> [args...]  or  <script | _run" >&2
        return 1
    fi
}

_must_ok() {
    local status=$?
    if [ "${status}" -ne 0 ]; then
        echo "failed,exit.." >&2
        exit "${status}"
    fi
}

_info() {
    printf '%s %s' "$(date +%FT%T)" "${1:-}"
}

_infoln() {
    printf '%s %s\n' "$(date +%FT%T)" "${1:-}"
}

_error() {
    printf '%s %s%s%s' "$(date +%FT%T)" "${RED}" "${1:-}" "${NORMAL}"
}

_errorln() {
    printf '%s %s%s%s\n' "$(date +%FT%T)" "${RED}" "${1:-}" "${NORMAL}"
}

_checkService() {
    local service_name="${1:?missing service name}"

    _info "find service ${service_name}.."
    if systemctl --all --no-pager | grep -q -- "${service_name}"; then
        echo "OK"
    else
        echo "Not found"
        return 1
    fi
}

LOG_LEVELS=("FATAL" "ERROR" "WARNING" "INFO" "SUCCESS" "DEBUG")
MAX_LEVEL_LENGTH=0
for level in "${LOG_LEVELS[@]}"; do
    level_len=${#level}
    if [ "${level_len}" -gt "${MAX_LEVEL_LENGTH}" ]; then
        MAX_LEVEL_LENGTH="${level_len}"
    fi
done
MAX_LEVEL_LENGTH=$((MAX_LEVEL_LENGTH + 2))

pad_level() {
    printf "%-${MAX_LEVEL_LENGTH}s" "[$1]"
}

log() {
    local level
    local message
    local padded_level
    local timestamp

    level="$(printf '%s' "$1" | awk '{print toupper($0)}')"
    shift
    message="$*"
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

    level="$(printf '%s' "$1" | awk '{print toupper($0)}')"
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
    shift

    printf '%s:\n' "${title}"
    while [ $# -gt 0 ]; do
        printf '  %s\n' "$1"
        shift
    done
}

_show_standard_help() {
    local usage="${1:?missing usage}"
    shift

    printf 'Usage: %s\n\n' "${usage}"
    _print_help_section "Commands" "${COMMANDS[@]}"
    printf '\n'
    _print_help_section "Options" "${HELP_OPTIONS[@]}"
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

detect_os() {
    case "$(uname -s)" in
    Linux)
        OS_RE='linux'
        ;;
    Darwin)
        OS_RE='darwin|mac'
        ;;
    *)
        log FATAL "unsupported os: $(uname -s)"
        ;;
    esac

    case "$(uname -m)" in
    x86_64 | amd64)
        MACHINE_RE='amd64|x86_64'
        ;;
    i686 | 386)
        MACHINE_RE='386|i686'
        ;;
    arm64 | aarch64)
        MACHINE_RE='arm64|aarch64'
        ;;
    *)
        log FATAL "unsupported architecture: $(uname -m)"
        ;;
    esac

    export OS_RE MACHINE_RE
    log INFO "osRE: ${OS_RE}"
    log INFO "machineRE: ${MACHINE_RE}"
}

get_release_link() {
    local repo="${1:?missing repo}"
    local version="${2:?missing version}"
    local result_link=""
    local candidates=""
    local filter_pattern

    if [ "${version}" = "latest" ]; then
        result_link="https://api.github.com/repos/${repo}/releases/latest"
    elif [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        result_link="https://api.github.com/repos/${repo}/releases/tags/v${version}"
    else
        log FATAL "invalid version: ${version}"
    fi

    _require_command curl
    detect_os

    candidates="$(
        curl -fsSL "${result_link}" |
            grep browser_download_url |
            grep -iE "${OS_RE}" |
            grep -iE "${MACHINE_RE}"
    )"
    log INFO "link0: ${candidates}"

    shift 2
    for filter_pattern in "$@"; do
        log INFO "apply filter pattern: ${filter_pattern}"
        candidates="$(printf '%s\n' "${candidates}" | grep -iE "${filter_pattern}")"
        log INFO "filtered link0: ${candidates}"
    done

    link="$(printf '%s\n' "${candidates}" | head -n 1 | cut -d '"' -f 4)"
    if [ -z "${link}" ]; then
        log FATAL "failed to resolve download link for ${repo} ${version}"
    fi

    export link
    log INFO "link: ${link}"
}

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

em() {
    "${ed}" "$0"
}

show_help() {
    _show_standard_help "$0 [-l LOG_LEVEL] <command>"
}

# available vars:
#   SCRIPT_DIR, THIS, INIT_TARGET_USER, INIT_TARGET_HOME
# available functions:
#   _command_exists _require_command _require_commands
#   _ensureDir _ensure_parent_dir
#   _root _require_root _linux _require_linux
#   _wait _runAsRoot _run _must_ok
#   _info _infoln _error _errorln _checkService
#   log set_log_level
#   detect_os get_release_link
#   em
#
# write your code below (just define function[s])
# function names beginning with '_' are treated as private helpers

example() {
    log INFO "This is an example command."
    log DEBUG "This is some debug information."
    _wait 1
    log SUCCESS "This is a success message."
    log WARNING "This is a warning message."
    log ERROR "This is an error message."
}

# write your code above

COMMANDS=("help" "example" "em")
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

_dispatch_cli show_help _resolve_cli_handler "$@"
