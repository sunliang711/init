#!/bin/bash

if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath" ]; then
        rpath=${BASH_SOURCE}
    elif echo "$rpath" | grep -q '^/'; then
        # absolute path
        echo
    else
        # relative path
        rpath="$(dirname ${BASH_SOURCE})/$rpath"
    fi
    this="$(cd $(dirname $rpath) && pwd)"
fi

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

# 定义颜色
# Use colors, but only if connected to a terminal(-t 1), and that terminal supports them(ncolors >=8.
if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    # 品红色
    MAGENTA=$(tput setaf 5)
    # 青色
    CYAN="$(tput setaf 6)"
    # 粗体
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi

# 日志级别常量
LOG_LEVEL_FATAL=1
LOG_LEVEL_ERROR=2
LOG_LEVEL_WARNING=3
LOG_LEVEL_SUCCESS=4
LOG_LEVEL_INFO=5
LOG_LEVEL_DEBUG=6

# 默认日志级别
LOG_LEVEL=$LOG_LEVEL_INFO

# 导出 PATH 环境变量
export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
        exit ${err_require_command}
    fi
}

_require_commands() {
    errorNo=0
    for i in "$@";do
        if ! _command_exists "$i"; then
            echo "need command $i" 1>&2
            errorNo=$((errorNo+1))
        fi
    done

    if ((errorNo > 0 ));then
        exit ${err_require_command}
    fi
}

function _ensureDir() {
    local dirs=$@
    for dir in ${dirs}; do
        if [ ! -d ${dir} ]; then
            mkdir -p ${dir} || {
                echo "create $dir failed!"
                exit $err_create_dir
            }
        fi
    done
}

rootID=0
function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "need root privilege." 1>&2
        return $err_require_root
    fi
}

function _require_root() {
    if ! _root; then
        exit $err_require_root
    fi
}

function _linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "need Linux" 1>&2
        return $err_require_linux
    fi
}

function _require_linux() {
    if ! _linux; then
        exit $err_require_linux
    fi
}

function _wait() {
    # secs=$((5 * 60))
    secs=${1:?'missing seconds'}

    while [ $secs -gt 0 ]; do
        echo -ne "$secs\033[0K\r"
        sleep 1
        : $((secs--))
    done
    echo -ne "\033[0K\r"
}

function _parseOptions() {
    if [ $(uname) != "Linux" ]; then
        echo "getopt only on Linux"
        exit 1
    fi

    options=$(getopt -o dv --long debug --long name: -- "$@")
    [ $? -eq 0 ] || {
        echo "Incorrect option provided"
        exit 1
    }
    eval set -- "$options"
    while true; do
        case "$1" in
        -v)
            VERBOSE=1
            ;;
        -d)
            DEBUG=1
            ;;
        --debug)
            DEBUG=1
            ;;
        --name)
            shift # The arg is next in position args
            NAME=$1
            ;;
        --)
            shift
            break
            ;;
        esac
        shift
    done
}

# 设置ed
ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ]; then
    ed=${editor}
fi

_checkRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        # 检查是否有 sudo 命令
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: 'sudo' command is required." >&2
            return 1
        fi

        # 检查用户是否在 sudoers 中
        echo "Checking if you have sudo privileges..."
        if ! sudo -v 2>/dev/null; then
            echo "You do NOT have sudo privileges or failed to enter password." >&2
            return 1
        fi
    fi
}

_runAsRoot() {
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

# 日志级别名称数组及最大长度计算
LOG_LEVELS=("FATAL" "ERROR" "WARNING" "INFO" "SUCCESS" "DEBUG")
MAX_LEVEL_LENGTH=0

for level in "${LOG_LEVELS[@]}"; do
  len=${#level}
  if (( len > MAX_LEVEL_LENGTH )); then
    MAX_LEVEL_LENGTH=$len
  fi
done
MAX_LEVEL_LENGTH=$((MAX_LEVEL_LENGTH+2))

# 日志级别名称填充
pad_level() {
  printf "%-${MAX_LEVEL_LENGTH}s" "[$1]"
}

# 打印带颜色的日志函数
log() {
  local level="$(echo "$1" | awk '{print toupper($0)}')" # 转换为大写以支持大小写敏感
  shift
  local message="$@"
  local padded_level=$(pad_level "$level")
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    "FATAL")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_FATAL ]; then
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
        exit 1
      fi
      ;;

    "ERROR")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_ERROR ]; then
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "WARNING")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_WARNING ]; then
        echo -e "${YELLOW}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "INFO")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_INFO ]; then
        echo -e "${BLUE}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "SUCCESS")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_SUCCESS ]; then
        echo -e "${GREEN}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "DEBUG")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_DEBUG ]; then
        echo -e "${CYAN}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    *)
      echo -e "${NC}[$timestamp] [$level] $message${NORMAL}"
      ;;
  esac
}

# 设置日志级别的函数
set_log_level() {
  local level="$(echo "$1" | awk '{print toupper($0)}')"
  case "$level" in
    "FATAL")
      LOG_LEVEL=$LOG_LEVEL_FATAL
      ;;
    "ERROR")
      LOG_LEVEL=$LOG_LEVEL_ERROR
      ;;
    "WARNING")
      LOG_LEVEL=$LOG_LEVEL_WARNING
      ;;
    "INFO")
      LOG_LEVEL=$LOG_LEVEL_INFO
      ;;
    "SUCCESS")
      LOG_LEVEL=$LOG_LEVEL_SUCCESS
      ;;
    "DEBUG")
      LOG_LEVEL=$LOG_LEVEL_DEBUG
      ;;
    *)
      echo "无效的日志级别: $1"
      ;;
  esac
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "install" "uninstall" "check" "components")
ALL_COMPONENTS=("git" "zsh" "fzf" "tmux" "vim" "update")
DEFAULT_INSTALL_COMPONENTS=("zsh" "fzf" "tmux" "vim")
DEFAULT_UNINSTALL_COMPONENTS=("zsh" "fzf" "tmux")
DEFAULT_CHECK_COMPONENTS=("${ALL_COMPONENTS[@]}")

repo="https://github.com/sunliang711/init"
dest="$HOME/.local/apps/init"

ACTION_PROXY=""
DRY_RUN=0
RAW_COMPONENTS=()
SELECTED_COMPONENTS=()

join_by() {
    local sep="$1"
    shift
    local output=""
    local item

    for item in "$@"; do
        if [ -n "$output" ]; then
            output="${output}${sep}${item}"
        else
            output="${item}"
        fi
    done

    printf '%s' "$output"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

add_component_once() {
    local candidate="$1"
    local existing
    for existing in "${SELECTED_COMPONENTS[@]}"; do
        if [ "$existing" = "$candidate" ]; then
            return 0
        fi
    done
    SELECTED_COMPONENTS+=("$candidate")
}

append_component_tokens() {
    local raw="$1"
    local token
    local IFS=','
    local -a parts=()

    read -r -a parts <<< "$raw"
    for token in "${parts[@]}"; do
        token="$(trim "$token")"
        [ -z "$token" ] && continue
        token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
        RAW_COMPONENTS+=("$token")
    done
}

component_exists() {
    local candidate="$1"
    case "$candidate" in
    git | zsh | fzf | tmux | vim | update)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

component_supports_action() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    install:git | check:git | \
        install:zsh | uninstall:zsh | check:zsh | \
        install:fzf | uninstall:fzf | check:fzf | \
        install:tmux | uninstall:tmux | check:tmux | \
        install:vim | check:vim | \
        install:update | uninstall:update | check:update)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

component_description() {
    case "$1" in
    git)
        echo "Git identity and global defaults"
        ;;
    zsh)
        echo "oh-my-zsh, plugins, shared zshrc, ssh config"
        ;;
    fzf)
        echo "fzf clone and shell integration"
        ;;
    tmux)
        echo "tmux config and TPM plugin manager"
        ;;
    vim)
        echo "user vimrc and nerdtree plugin"
        ;;
    update)
        echo "daily repo auto-update cron job"
        ;;
    esac
}

component_change_summary() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    install:git)
        echo "Sets global git identity and defaults in ~/.gitconfig."
        ;;
    install:zsh)
        echo "Installs oh-my-zsh plugins and links ~/.zshrc plus ~/.ssh/config."
        ;;
    install:fzf)
        echo "Clones ~/.fzf and runs its shell integration installer."
        ;;
    install:tmux)
        echo "Clones TPM and writes ~/.tmux.conf."
        ;;
    install:vim)
        echo "Copies ~/.vimrc and installs nerdtree under ~/.vim/pack."
        ;;
    install:update)
        echo "Adds a crontab entry to update this repo every day."
        ;;
    uninstall:zsh)
        echo "Removes zsh artifacts managed by scripts/zsh.sh."
        ;;
    uninstall:fzf)
        echo "Runs ~/.fzf/uninstall and removes ~/.fzf."
        ;;
    uninstall:tmux)
        echo "Removes ~/.tmux.conf and ~/.tmux."
        ;;
    uninstall:update)
        echo "Removes the repo auto-update crontab entry."
        ;;
    check:git)
        echo "Checks Git prerequisites."
        ;;
    check:zsh)
        echo "Checks shell bootstrap prerequisites."
        ;;
    check:fzf)
        echo "Checks fzf install prerequisites."
        ;;
    check:tmux)
        echo "Checks tmux prerequisites."
        ;;
    check:vim)
        echo "Checks vim prerequisites."
        ;;
    check:update)
        echo "Checks cron availability for repo auto-update."
        ;;
    *)
        echo "No summary available."
        ;;
    esac
}

print_component_list() {
    local component
    local install_supported
    local uninstall_supported
    local check_supported

    echo "Available components:"
    for component in "${ALL_COMPONENTS[@]}"; do
        install_supported="no"
        uninstall_supported="no"
        check_supported="no"
        component_supports_action install "$component" && install_supported="yes"
        component_supports_action uninstall "$component" && uninstall_supported="yes"
        component_supports_action check "$component" && check_supported="yes"
        printf "  %-8s install=%-3s uninstall=%-3s check=%-3s %s\n" \
            "$component" "$install_supported" "$uninstall_supported" "$check_supported" \
            "$(component_description "$component")"
    done
}

# 显示帮助信息
show_help() {
    cat <<EOF
Usage: $0 [-l LOG_LEVEL] <command> [options] [components...]

Commands:
  help         Show this help
  install      Install selected components
  uninstall    Uninstall selected components when supported
  check        Check prerequisites for selected components
  components   Show the component matrix

Component selection:
  Pass components as positional args: install zsh fzf
  Or use a comma-separated list:      install --components zsh,fzf
  Use "all" to select all supported components for that action.

Defaults:
  install      $(join_by ', ' "${DEFAULT_INSTALL_COMPONENTS[@]}")
  uninstall    $(join_by ', ' "${DEFAULT_UNINSTALL_COMPONENTS[@]}")
  check        $(join_by ', ' "${DEFAULT_CHECK_COMPONENTS[@]}")

Options:
  -l LOG_LEVEL       Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)
  --components LIST  Comma-separated component list
  --dry-run          Show the action summary without applying install or uninstall changes
  --proxy URL        Install only. Also updates global git proxy settings for this machine

Examples:
  $0 install
  $0 install --components zsh,fzf
  $0 install git zsh --proxy http://127.0.0.1:7890
  $0 uninstall --components tmux
  $0 check all
  $0 components
EOF
}

ensure_install_location() {
    if [ "$this" != "$dest" ]; then
        echo "Please clone this to $dest"
        echo "Run git clone $repo $dest"
        exit 1
    fi
}

configure_install_proxy() {
    local proxy="$1"
    [ -n "$proxy" ] || return 0

    _require_command git

    log INFO "Apply install proxy and update global git proxy settings"
    git config --global http.proxy "$proxy"
    git config --global https.proxy "$proxy"
    export http_proxy="$proxy"
    export HTTP_PROXY="$proxy"
    export https_proxy="$proxy"
    export HTTPS_PROXY="$proxy"
}

normalize_action_components() {
    local action="$1"
    local component
    local candidate
    local -a input_components=()

    SELECTED_COMPONENTS=()

    if [ "${#RAW_COMPONENTS[@]}" -eq 0 ]; then
        case "$action" in
        install)
            input_components=("${DEFAULT_INSTALL_COMPONENTS[@]}")
            ;;
        uninstall)
            input_components=("${DEFAULT_UNINSTALL_COMPONENTS[@]}")
            ;;
        check)
            input_components=("${DEFAULT_CHECK_COMPONENTS[@]}")
            ;;
        *)
            log FATAL "Unknown action: $action"
            ;;
        esac
    else
        input_components=("${RAW_COMPONENTS[@]}")
    fi

    for component in "${input_components[@]}"; do
        if [ "$component" = "all" ]; then
            for candidate in "${ALL_COMPONENTS[@]}"; do
                if component_supports_action "$action" "$candidate"; then
                    add_component_once "$candidate"
                fi
            done
            continue
        fi

        if ! component_exists "$component"; then
            log FATAL "Unknown component: $component"
        fi
        if ! component_supports_action "$action" "$component"; then
            log FATAL "Component '$component' does not support action '$action'"
        fi
        add_component_once "$component"
    done

    if [ "${#SELECTED_COMPONENTS[@]}" -eq 0 ]; then
        log FATAL "No components selected for action '$action'"
    fi
}

parse_action_args() {
    local action="$1"
    shift

    ACTION_PROXY=""
    DRY_RUN=0
    RAW_COMPONENTS=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --components | --component | --only)
            shift
            [ $# -gt 0 ] || log FATAL "Missing value for --components"
            append_component_tokens "$1"
            ;;
        --proxy)
            [ "$action" = "install" ] || log FATAL "--proxy is only supported for install"
            shift
            [ $# -gt 0 ] || log FATAL "Missing value for --proxy"
            ACTION_PROXY="$1"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                append_component_tokens "$1"
                shift
            done
            break
            ;;
        -*)
            log FATAL "Unknown option: $1"
            ;;
        *)
            if [ "$action" = "install" ] && [ -z "$ACTION_PROXY" ] && echo "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*://'; then
                ACTION_PROXY="$1"
            else
                append_component_tokens "$1"
            fi
            ;;
        esac
        shift
    done

    normalize_action_components "$action"
}

print_action_summary() {
    local action="$1"
    local component

    echo "Action: ${action}"
    echo "Components: $(join_by ', ' "${SELECTED_COMPONENTS[@]}")"

    if [ "$action" = "install" ] && [ -n "$ACTION_PROXY" ]; then
        echo "Proxy: ${ACTION_PROXY}"
        echo "  - proxy: sets global git http/https proxy and exports proxy env for this run."
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "Dry run: enabled"
    fi

    echo "Summary:"
    for component in "${SELECTED_COMPONENTS[@]}"; do
        echo "  - ${component}: $(component_change_summary "$action" "$component")"
    done
}

run_component_action() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    check:git)
        (cd "${this}/scripts" && bash setGit.sh check)
        ;;
    install:git)
        (cd "${this}/scripts" && bash setGit.sh set)
        ;;
    check:zsh)
        (cd "${this}/scripts" && bash zsh.sh check)
        ;;
    install:zsh)
        (cd "${this}/scripts" && bash zsh.sh install)
        ;;
    uninstall:zsh)
        (cd "${this}/scripts" && bash zsh.sh uninstall)
        ;;
    check:fzf)
        (cd "${this}/scripts" && bash installFzf.sh check)
        ;;
    install:fzf)
        (cd "${this}/scripts" && bash installFzf.sh install)
        ;;
    uninstall:fzf)
        (cd "${this}/scripts" && bash installFzf.sh uninstall)
        ;;
    check:tmux)
        (cd "${this}/scripts" && bash tmux.sh check)
        ;;
    install:tmux)
        (cd "${this}/scripts" && bash tmux.sh install)
        ;;
    uninstall:tmux)
        (cd "${this}/scripts" && bash tmux.sh uninstall)
        ;;
    check:vim)
        (cd "${this}/scripts" && bash vim.sh check)
        ;;
    install:vim)
        (cd "${this}/scripts" && bash vim.sh user)
        ;;
    check:update)
        (cd "${this}/tools" && bash updateInit.sh check)
        ;;
    install:update)
        (cd "${this}/tools" && bash updateInit.sh install)
        ;;
    uninstall:update)
        (cd "${this}/tools" && bash updateInit.sh uninstall)
        ;;
    *)
        log FATAL "Unsupported action '${action}' for component '${component}'"
        ;;
    esac
}

run_checks() {
    local component
    local error_checks=0

    for component in "${SELECTED_COMPONENTS[@]}"; do
        if ! run_component_action check "$component"; then
            error_checks=$((error_checks + 1))
        fi
    done

    if [ "$error_checks" -gt 0 ]; then
        log FATAL "Prerequisite checks failed for ${error_checks} component(s)"
    fi
}

install() {
    ensure_install_location
    parse_action_args install "$@"
    print_action_summary install
    run_checks

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "Dry run only. Skipping install."
        return 0
    fi

    configure_install_proxy "$ACTION_PROXY"

    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
        log INFO "Install component: ${component}"
        run_component_action install "$component"
    done
}

uninstall() {
    parse_action_args uninstall "$@"
    print_action_summary uninstall

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "Dry run only. Skipping uninstall."
        return 0
    fi

    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
        log INFO "Uninstall component: ${component}"
        run_component_action uninstall "$component"
    done
}

check() {
    parse_action_args check "$@"
    print_action_summary check
    run_checks
}

components() {
    print_component_list
}

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
