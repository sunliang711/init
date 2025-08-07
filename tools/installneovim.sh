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

rootID=0
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
COMMANDS=("help" "install")

install() {
	set -e
    version=${1}
    if [ "${version}x" == "x" ];then
        link="https://api.github.com/repos/neovim/neovim/releases/latest"
    else
        link="https://api.github.com/repos/neovim/neovim/releases/tags/v${version}"
    fi

    log INFO "get neovim link from ${link}.."
    link="$(curl -s ${link} | grep browser_download_url|grep -i $(uname -s) |  grep -i $(uname -m) | cut -d '"' -f 4   | grep tar.gz)"
    log INFO "latest link: ${link}"
    tarfileName="${link##*/}"
    dirName="${tarfileName%%.tar.*}"

    downloadDir=/tmp/nvim_download
    [ ! -d "${downloadDir}" ] && mkdir "${downloadDir}"
    log INFO "download lazygit to ${downloadDir}.."

    cd ${downloadDir}
    curl -LO "${link}" || { echo "download lazygit failed"; exit 1 ; }

    log INFO "extract ${tarfileName}.."
    tar xvf ${tarfileName}

    dest="/usr/local"
    [ ! -d "${dest}" ] && mkdir "${dest}"


    cd "${dirName}"
    log INFO "install to ${dest}.."
    runAsRoot cp -r bin/* ${dest}/bin
    runAsRoot cp -r lib/* ${dest}/lib
    runAsRoot cp -r share/* ${dest}/share

    rm -rf "${downloadDir}"
}

# checKernel(){
# 	case $(uname -s) in
# 		Linux)
# 		;;
# 		Darwin)
# 		;;
# 		FreeBSD)
# 		;;
# 	esac
# 	case $(uname -m) in
# 		x86_64|amd64)
# 		;;
# 		arm64)
# 		;;
# 	esac
# }

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
