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

_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_require_command() {
    if ! _command_exists "$1"; then
        echo "Require command $1" 1>&2
        exit ${err_require_command}
    fi
}

function _ensureDir() {
    local dirs=$@
    for dir in ${dirs}; do
        if [ ! -d ${dir} ]; then
            mkdir -p ${dir} || {
                echo "create $dir failed!"
                exit 1
            }
        fi
    done
}

function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "Require root privilege." 1>&2
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
        echo "Require Linux" 1>&2
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

# 用法: _runAsRoot [-x] [-s] [--no-stdout] [--no-stderr] <command>
_runAsRoot() {
    local trace=0
    local subshell=0
    local nostdout=0
    local nostderr=0

    local optNum=0
    for opt in ${@}; do
        case "${opt}" in
        --trace | -x)
            trace=1
            ((optNum++))
            ;;
        --subshell | -s)
            subshell=1
            ((optNum++))
            ;;
        --no-stdout)
            nostdout=1
            ((optNum++))
            ;;
        --no-stderr)
            nostderr=1
            ((optNum++))
            ;;
        *)
            break
            ;;
        esac
    done

    shift $(($optNum))
    local cmd="${*}"
    bash_c='bash -c'
    if [ "${EUID}" -ne "${rootID}" ]; then
        if _command_exists sudo; then
            bash_c='sudo -E bash -c'
        elif _command_exists su; then
            bash_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            return 1
        fi
    fi

    local fullcommand="${bash_c} ${cmd}"
    if [ $nostdout -eq 1 ]; then
        cmd="${cmd} >/dev/null"
    fi
    if [ $nostderr -eq 1 ]; then
        cmd="${cmd} 2>/dev/null"
    fi

    if [ $subshell -eq 1 ]; then
        if [ $trace -eq 1 ]; then
            (
                { set -x; } 2>/dev/null
                ${bash_c} "${cmd}"
            )
        else
            (${bash_c} "${cmd}")
        fi
    else
        if [ $trace -eq 1 ]; then
            { set -x; } 2>/dev/null
            ${bash_c} "${cmd}"
            local ret=$?
            { set +x; } 2>/dev/null
            return $ret
        else
            ${bash_c} "${cmd}"
        fi
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
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message"
        exit 1
      fi
      ;;

    "ERROR")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_ERROR ]; then
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message"
      fi
      ;;
    "WARNING")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_WARNING ]; then
        echo -e "${YELLOW}${BOLD}[$timestamp] $padded_level${NC} $message"
      fi
      ;;
    "INFO")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_INFO ]; then
        echo -e "${BLUE}${BOLD}[$timestamp] $padded_level${NC} $message"
      fi
      ;;
    "SUCCESS")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_SUCCESS ]; then
        echo -e "${GREEN}${BOLD}[$timestamp] $padded_level${NC} $message"
      fi
      ;;
    "DEBUG")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_DEBUG ]; then
        echo -e "${CYAN}${BOLD}[$timestamp] $padded_level${NC} $message"
      fi
      ;;
    *)
      echo -e "${NC}[$timestamp] [$level] $message"
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

# 子命令数组
# todo
COMMANDS=("help" "install" "uninstall", "reinstall")

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

check(){
    _require_command tmux
}

# 示例子命令函数
install() {
    check
    set -e

    log INFO "Install tmux plugins..."
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

    cat <<EOF >$home/.tmux.conf
##################################################
# enable vi mode
set-window-option -g mode-keys vi
set -g display-panes-time 10000 #10s

##################################################
# set croll history limit
set -g history-limit 8000

##################################################
# secape time: fix vim esc delay in tmux problem
set -s escape-time 0

##################################################
# split window
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

##################################################
# enable mouse
set -g mouse on

##################################################
# vi mode copy
# version 2.4+
 bind-key -T copy-mode-vi 'v' send -X begin-selection
 bind-key -T copy-mode-vi 'y' send -X copy-selection

# old version
# bind-key -t vi-copy v begin-selection;
# bind-key -t vi-copy y copy-selection;

# not work
# bind-key -T vi-copy 'v' begin-selection
# bind-key -T vi-copy 'y' copy-selection

##################################################
# select pane
bind k select-pane -U
bind j select-pane -D
bind h select-pane -L
bind l select-pane -R

##################################################
# resize pane
bind H resize-pane -L 4
bind L resize-pane -R 4
bind J resize-pane -D 4
bind K resize-pane -U 4

##################################################
# edit .tmux.conf
bind e new-window -n '~/.tmux.conf' "sh -c 'vim ~/.tmux.conf && tmux source ~/.tmux.conf'"

##################################################
# search text in current pane
bind-key / copy-mode \; send-key ?

##################################################
# reload config file
bind r source-file ~/.tmux.conf \; display "Reloaded tmux config!"

##################################################
# show options
bind o show-options -g


#### TMP Section
# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

#set -g @plugin 'wfxr/tmux-power'
set -g @plugin 'egel/tmux-gruvbox'
set -g @tmux-gruvbox 'light' # or 'dark'

# Other examples:
# set -g @plugin 'github_username/plugin_name'
# set -g @plugin 'github_username/plugin_name#branch'
# set -g @plugin 'git@github.com:user/plugin'
# set -g @plugin 'git@bitbucket.com:user/plugin'

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
EOF

    log SUCCESS "start tmux,then press <prefix> + I to install plugins"
}

uninstall() {
    log INFO "Uninstall tmux plugins..."

    log INFO "Remove $home/.tmux.conf"
    /bin/rm -rf $home/.tmux.conf

    log INFO "Remove $home/.tmux"
    /bin/rm -rf $home/.tmux

    log SUCCESS "Uninstall tmux plugins success!"
}

reinstall() {
    uninstall
    install
}

#todo

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
  install)
    install "$@"
    ;;
  uninstall)
    uninstall "$@"
    ;;
  reinstall)
    reinstall "$@"
    ;;
  *)
    echo "Unknown command: $command" 1>&2
    show_help
    exit 1
    ;;
esac
