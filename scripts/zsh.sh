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

checkRoot() {
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

# 显示帮助信息
show_help() {
  echo "Usage: $0 [-l LOG_LEVEL] <command>"
  echo ""
  echo "Commands:"
  for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
  done
  echo ""
  echo "Options:"
  echo "  -l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)"
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "check" "install" "uninstall" "linksshpems")

ZSH=${ZSH:-${HOME}/.oh-my-zsh}
ZSH_CUSTOM=${ZSH_CUSTOM:-${ZSH}/custom}
STATE_DIR="${home}/.local/state/init"
STATE_FILE="${STATE_DIR}/zsh.state"
ZSHRC_LINK_TARGET="${this}/../softlinks/zshrc"
SSH_CONFIG_LINK_TARGET="${this}/../softlinks/sshconfig"
AUTOSUGGESTIONS_DIR="${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
AUTOSUGGESTIONS_REPO="https://github.com/zsh-users/zsh-autosuggestions"
SYNTAX_HIGHLIGHTING_DIR="${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
SYNTAX_HIGHLIGHTING_REPO="https://github.com/zsh-users/zsh-syntax-highlighting.git"
EDITRC_MARKER_BEGIN="# BEGIN managed by init:zsh"
EDITRC_MARKER_END="# END managed by init:zsh"
INPUTRC_MARKER_BEGIN="# BEGIN managed by init:zsh"
INPUTRC_MARKER_END="# END managed by init:zsh"

_ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

_write_state() {
    _ensure_state_dir
    cat >"${STATE_FILE}" <<EOF
MANAGED_AUTOSUGGESTIONS_DIR=${1:-0}
MANAGED_SYNTAX_HIGHLIGHTING_DIR=${2:-0}
EOF
}

_state_get() {
    local key="${1:?missing state key}"
    [ -f "${STATE_FILE}" ] || return 1
    awk -F= -v key="${key}" '$1 == key { print $2 }' "${STATE_FILE}"
}

_cleanup_state_file() {
    [ -f "${STATE_FILE}" ] && /bin/rm -f "${STATE_FILE}"
}

_ensure_managed_block() {
    local file="${1:?missing file}"
    local begin="${2:?missing begin marker}"
    local end="${3:?missing end marker}"
    local body="${4:?missing body}"

    [ -f "${file}" ] || touch "${file}"

    if grep -Fq "${begin}" "${file}" || grep -Fxq "${body}" "${file}"; then
        return 0
    fi

    cat >>"${file}" <<EOF
${begin}
${body}
${end}
EOF
}

_remove_managed_block() {
    local file="${1:?missing file}"
    local begin="${2:?missing begin marker}"
    local end="${3:?missing end marker}"
    local tmp_file

    [ -f "${file}" ] || return 0
    grep -Fq "${begin}" "${file}" || return 0

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/init-zsh.XXXXXX")" || return 1
    awk -v begin="${begin}" -v end="${end}" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip != 1 { print }
    ' "${file}" >"${tmp_file}" && mv "${tmp_file}" "${file}"

    if [ ! -s "${file}" ]; then
        /bin/rm -f "${file}"
    fi
}

_remove_symlink_if_matches() {
    local path="${1:?missing path}"
    local expected_target="${2:?missing expected target}"
    local current_target

    [ -L "${path}" ] || return 0
    current_target="$(readlink "${path}")"
    if [ "${current_target}" = "${expected_target}" ]; then
        /bin/rm -f "${path}"
    fi
}

_git_remote_matches() {
    local repo_dir="${1:?missing repo dir}"
    local expected_remote="${2:?missing expected remote}"
    local current_remote

    [ -d "${repo_dir}/.git" ] || return 1
    current_remote="$(git -C "${repo_dir}" config --get remote.origin.url 2>/dev/null)"
    [ "${current_remote}" = "${expected_remote}" ]
}

_remove_plugin_dir_if_managed() {
    local repo_dir="${1:?missing repo dir}"
    local expected_remote="${2:?missing expected remote}"
    local state_key="${3:?missing state key}"

    [ "$(_state_get "${state_key}")" = "1" ] || return 0
    [ -d "${repo_dir}" ] || return 0

    if _git_remote_matches "${repo_dir}" "${expected_remote}"; then
        /bin/rm -rf "${repo_dir}"
    fi
}

_remove_repo_theme_symlinks() {
    local theme_source
    local theme_name
    local theme_target

    for theme_source in "${this}"/../softlinks/*.zsh-theme; do
        [ -e "${theme_source}" ] || continue
        theme_name="$(basename "${theme_source}")"
        theme_target="${ZSH_CUSTOM}/themes/${theme_name}"
        _remove_symlink_if_matches "${theme_target}" "${theme_source}"
    done
}

check() {
    _require_commands git curl zsh
}

install() {
    export SHELLRC_ROOT=${HOME}/.local/apps/init/shellConfigs
    check
    set -e
    local managed_autosuggestions_dir=0
    local managed_syntax_highlighting_dir=0

    [ "$(_state_get MANAGED_AUTOSUGGESTIONS_DIR)" = "1" ] && managed_autosuggestions_dir=1
    [ "$(_state_get MANAGED_SYNTAX_HIGHLIGHTING_DIR)" = "1" ] && managed_syntax_highlighting_dir=1

    _ensure_managed_block "$HOME/.editrc" "${EDITRC_MARKER_BEGIN}" "${EDITRC_MARKER_END}" "bind -v"
    _ensure_managed_block "$HOME/.inputrc" "${INPUTRC_MARKER_BEGIN}" "${INPUTRC_MARKER_END}" "set editing-mode vi"

    # install omz
    (
        cd /tmp
        local installer="omzInstaller-$(date +%s).sh"
        curl -fsSL -o ${installer} https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh
        RUNZSH=no bash ${installer}
    )

    ln -sf "${ZSHRC_LINK_TARGET}" ~/.zshrc || {
        echo "Please fork the repo first"
        exit 1
    }

    # omz plugins
    # zsh-autosuggestions
    if [ ! -d "${AUTOSUGGESTIONS_DIR}" ]; then
        git clone "${AUTOSUGGESTIONS_REPO}" "${AUTOSUGGESTIONS_DIR}"
        managed_autosuggestions_dir=1
    fi
    # zsh-syntax-highlighting
    if [ ! -d "${SYNTAX_HIGHLIGHTING_DIR}" ]; then
        git clone "${SYNTAX_HIGHLIGHTING_REPO}" "${SYNTAX_HIGHLIGHTING_DIR}"
        managed_syntax_highlighting_dir=1
    fi

    # custom theme
    ln -svf "${this}"/../softlinks/*.zsh-theme "${ZSH_CUSTOM}/themes"

    # soft link sshconfig
    [ ! -d ~/.ssh ] && mkdir ~/.ssh
    ln -svf "${SSH_CONFIG_LINK_TARGET}" "$HOME"/.ssh/config

    _write_state "${managed_autosuggestions_dir}" "${managed_syntax_highlighting_dir}"
}

linksshpems() {
    ln -svf "${this}"/../softlinks/sshpems "$HOME"/.ssh/sshpems
    chmod 0600 "$HOME"/.ssh/sshpems/*
}

uninstall() {
    _remove_symlink_if_matches "$HOME/.zshrc" "${ZSHRC_LINK_TARGET}"
    _remove_symlink_if_matches "$HOME/.ssh/config" "${SSH_CONFIG_LINK_TARGET}"
    _remove_repo_theme_symlinks
    _remove_plugin_dir_if_managed "${AUTOSUGGESTIONS_DIR}" "${AUTOSUGGESTIONS_REPO}" "MANAGED_AUTOSUGGESTIONS_DIR"
    _remove_plugin_dir_if_managed "${SYNTAX_HIGHLIGHTING_DIR}" "${SYNTAX_HIGHLIGHTING_REPO}" "MANAGED_SYNTAX_HIGHLIGHTING_DIR"
    _remove_managed_block "$HOME/.editrc" "${EDITRC_MARKER_BEGIN}" "${EDITRC_MARKER_END}"
    _remove_managed_block "$HOME/.inputrc" "${INPUTRC_MARKER_BEGIN}" "${INPUTRC_MARKER_END}"
    _cleanup_state_file
}

_rm() {
    local target=${1}
    [ -e ${target} ] && /bin/rm -rf ${target}
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
