#!/bin/bash

COMMON_LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/init-common.sh"
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE

# 显示帮助信息
show_help() {
  echo "Usage: $0 [-l LOG_LEVEL] <command> [options]"
  echo ""
  echo "Commands:"
  for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
  done
  echo ""
  echo "Options:"
  echo "  -l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)"
  echo ""
  echo "Set command options:"
  echo "  --name NAME          Set git user.name"
  echo "  --email EMAIL        Set git user.email"
  echo "  --non-interactive    Fail instead of prompting when values are missing"
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "check" "set" "unset")

check() {
    _require_commands git
}

_trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

_current_git_config() {
    git config --global --get "$1" 2>/dev/null || true
}

_is_interactive_terminal() {
    [ -t 0 ] && [ -t 1 ]
}

_can_use_whiptail() {
    _is_interactive_terminal && command -v whiptail >/dev/null 2>&1 && [ "${TERM:-}" != "dumb" ]
}

_prompt_with_whiptail() {
    local title="${1:?missing title}"
    local prompt="${2:?missing prompt}"
    local default_value="${3:-}"
    local value

    value="$(whiptail --title "${title}" --inputbox "${prompt}" 8 60 "${default_value}" 3>&1 1>&2 2>&3)" || return 1
    printf '%s' "${value}"
}

_prompt_with_read() {
    local prompt="${1:?missing prompt}"
    local default_value="${2:-}"
    local input=""

    if [ -n "${default_value}" ]; then
        read -r -p "${prompt} (default: ${default_value}) " input
    else
        read -r -p "${prompt} " input
    fi

    if [ -z "${input}" ]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${input}"
    fi
}

_prompt_for_value() {
    local key="${1:?missing key}"
    local prompt="${2:?missing prompt}"
    local default_value="${3:-}"

    if _can_use_whiptail; then
        _prompt_with_whiptail "set git ${key}" "${prompt}" "${default_value}"
    else
        _prompt_with_read "${prompt}" "${default_value}"
    fi
}

_validate_email() {
    local email="${1:-}"
    case "${email}" in
    *@*)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

_resolve_email() {
    local output_var="${1:?missing output variable}"
    local candidate_email="$(_trim "${2:-}")"
    local non_interactive="${3:-0}"

    while :; do
        if [ -z "${candidate_email}" ]; then
            if [ "${non_interactive}" -eq 1 ] || ! _is_interactive_terminal; then
                echo "Missing git user.email. Pass --email, set INIT_GIT_USER_EMAIL, or run interactively." >&2
                return 1
            fi
        elif _validate_email "${candidate_email}"; then
            printf -v "${output_var}" '%s' "${candidate_email}"
            return 0
        elif [ "${non_interactive}" -eq 1 ] || ! _is_interactive_terminal; then
            echo "Invalid email address: ${candidate_email}" >&2
            return 1
        else
            echo "Invalid email address: ${candidate_email}" >&2
        fi

        candidate_email="$(_prompt_for_value "email" "enter email address: " "${candidate_email}")" || {
            echo "canceled"
            return 1
        }
        candidate_email="$(_trim "${candidate_email}")"
    done
}

_set_global_git_config() {
    local key="${1:?missing key}"
    shift

    git config --global "${key}" "$@" || {
        echo "Failed to set git config: ${key}" >&2
        return 1
    }
}

set() {
    check

    local name="${INIT_GIT_USER_NAME:-}"
    local email="${INIT_GIT_USER_EMAIL:-}"
    local non_interactive=0

    while [ $# -gt 0 ]; do
        case "$1" in
        --name)
            shift
            [ $# -gt 0 ] || {
                echo "Missing value for --name" >&2
                return 1
            }
            name="$1"
            ;;
        --email)
            shift
            [ $# -gt 0 ] || {
                echo "Missing value for --email" >&2
                return 1
            }
            email="$1"
            ;;
        --non-interactive)
            non_interactive=1
            ;;
        -h | --help)
            show_help
            return 0
            ;;
        *)
            echo "Unknown option for set: $1" >&2
            return 1
            ;;
        esac
        shift
    done

    name="$(_trim "${name}")"
    email="$(_trim "${email}")"

    [ -n "${name}" ] || name="$(_trim "$(_current_git_config user.name)")"
    [ -n "${email}" ] || email="$(_trim "$(_current_git_config user.email)")"

    _resolve_email email "${email}" "${non_interactive}" || return 1

    if [ -z "${name}" ]; then
        if [ "${non_interactive}" -eq 1 ] || ! _is_interactive_terminal; then
            echo "Missing git user.name. Pass --name, set INIT_GIT_USER_NAME, or run interactively." >&2
            return 1
        fi
        name="$(_prompt_for_value "name" "enter name: " "${name}")" || {
            echo "canceled"
            return 1
        }
    fi

    name="$(_trim "${name}")"
    email="$(_trim "${email}")"

    if [ -z "${name}" ] || [ -z "${email}" ]; then
        echo "git user.name and user.email must not be empty." >&2
        return 1
    fi

    _set_global_git_config user.email "${email}" || return 1
    _set_global_git_config user.name "${name}" || return 1
    _set_global_git_config http.postBuffer 524288000 || return 1
    _set_global_git_config push.default simple || return 1
    _set_global_git_config pull.rebase false || return 1
    #save password for several minutes
    _set_global_git_config credential.helper cache || return 1
    if command -v vimdiff >/dev/null 2>&1; then
        _set_global_git_config merge.tool vimdiff || return 1
    else
        echo "No vimdiff, so merge.tool is empty"
    fi
    # git config --global alias.tree "log --oneline --graph --decorate --all"
    _set_global_git_config alias.tree 'log --pretty=format:%Cgreen%h %Cred%d %Cblue%s %x09%Creset[%cn %cd] --graph --date=iso' || return 1
    _set_global_git_config alias.list 'config --global --list' || return 1
    if command -v nvim >/dev/null 2>&1; then
        _set_global_git_config core.editor nvim || return 1
    elif command -v vim >/dev/null 2>&1; then
        _set_global_git_config core.editor vim || return 1
    elif command -v vi >/dev/null 2>&1; then
        _set_global_git_config core.editor vi || return 1
    fi
    if command -v vimdiff >/dev/null 2>&1; then
        _set_global_git_config diff.tool vimdiff || return 1
    fi
}

unset() {
    local keys=(
        user.email
        user.name
        http.postBuffer
        push.default
        pull.rebase
        credential.helper
        merge.tool
        alias.tree
        alias.list
        core.editor
        diff.tool
    )
    local key

    for key in "${keys[@]}"; do
        git config --global --unset-all "${key}" >/dev/null 2>&1 || true
    done
}
# write your code above


# ------------------------------------------------------------

# 解析命令行参数
while getopts ":l:" opt; do
  case ${opt} in
    l )
      set_log_level "$OPTARG"
      ;;
    \? )
      show_help
      exit 1
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      show_help
      exit 1
      ;;
  esac
done
# NOTE: 这里全局使用了OPTIND，如果在某个函数中也使用了getopts，那么在函数的开头需要重置OPTIND (OPTIND=1)
shift $((OPTIND -1))

# 解析子命令
command=$1
shift

if [[ -z "$command" ]]; then
  show_help
  exit 0
fi

case "$command" in
  help)
    show_help
    ;;
  *)
    ${command} "$@"
    ;;
esac
