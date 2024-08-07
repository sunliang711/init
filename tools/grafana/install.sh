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

err_require_root=33
err_require_linux=55
err_require_command=88

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
COMMANDS=("help" "example" "installNodeExporter" "installPrometheus" "installGrafana" "configNodeExporter")

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

# 示例子命令函数
example_command() {
  log "INFO" "This is an example command."
  log "DEBUG" "This is some debug information."
  _wait 3
  log "SUCCESS" "This is a success message."
  log "WARNING" "This is a warning message."
  log "error" "This is an error message."
}

#todo
installNodeExporter() {
    _require_root
    _require_command curl
    _require_command tar
    _require_command systemctl

    case "$(uname -m)" in
        "x86_64")
            target="amd64"
            ;;
        "aarch64")
            target="arm64"
            ;;
        *)
        log "FATAL" "Unsupported architecture: $(name -m)"
    esac
 
    set -e

    version="1.8.1"
    nodeExporterLink="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.linux-${target}.tar.gz"
    tarFile="${nodeExporterLink##*/}"
    dirName="${tarFile%.tar.gz}"
    log DEBUG "Downloading node_exporter from $nodeExporterLink"
    log DEBUG "Saving to $tarFile"


    nodeExporterInstallTmpDir="/tmp/node_exporter_install$$"
    log INFO "Creating temporary directory $nodeExporterInstallTmpDir"
    mkdir -p "$nodeExporterInstallTmpDir"
    cd "$nodeExporterInstallTmpDir"

    log INFO "Downloading node_export"
    curl -m 30 -L -O $nodeExporterLink
    if [ ! -e "$tarFile" ];then
        log FAIL "Download node_exporter failed"
    fi
    log SUCCESS "Downloaded node_exporter"

    log INFO "Extracting node_exporter"
    # extract node_exporter
    tar -zxvf $tarFile

    log INFO "Copying node_exporter"
    find . -name "node_exporter" -exec cp {} /usr/local/bin/ \;

    rm -rf "${nodeExporterInstallTmpDir}"

    log INFO "Add user node_exporter"
    useradd -rs /bin/false node_exporter

    log INFO "Creating node_exporter service"
    cp ${this}/node_exporter.service /etc/systemd/system/

    log INFO "Starting node_exporter"
    systemctl enable --now node_exporter

    # TODO check node_exporter status
    log SUCCESS "Node exporter installed"
}

installPrometheus(){
    _require_root
    _require_linux
    _require_command curl
    _require_command tar
    _require_command systemctl
    set -e

    case "$(uname -m)" in
        "x86_64")
            target="amd64"
            ;;
        "aarch64")
            target="arm64"
            ;;
        *)
        log "FATAL" "Unsupported architecture: $(name -m)"
    esac

    [ ! -d "/var/lib/prometheus" ] && mkdir /var/lib/prometheus
    mkdir -p /etc/prometheus/rules
    mkdir -p /etc/prometheus/rules.d
    mkdir -p /etc/prometheus/files_sd

    installPrometheusTmpDir="/tmp/prometheus_install$$"
    log INFO "Creating temporary directory $installPrometheusTmpDir"
    mkdir -p "$installPrometheusTmpDir"
    cd "$installPrometheusTmpDir"

    log INFO "Downloading prometheus"
    curl https://api.github.com/repos/prometheus/prometheus/releases/latest \
        | grep browser_download_url \
        | grep linux-${target} \
        | cut -d '"' -f 4 \
        | xargs -IR curl -LO R

    log INFO "Extracting prometheus"
    tar xvf prometheus*.tar.gz

    log INFO "Copying prometheus"
    cd prometheus*/
    mv prometheus promtool /usr/local/bin/
    mv prometheus.yml  /etc/prometheus/prometheus.yml
    mv consoles/ console_libraries/ /etc/prometheus/

    cd ~/
    rm -rf "$installPrometheusTmpDir"

    if ! id -u prometheus>/dev/null;then
      log INFO "Add user prometheus"
      useradd -rs /bin/false prometheus
    fi
    if ! id -g prometheus>/dev/null;then
      log INFO "Add group prometheus"
      groupadd --system prometheus
    fi

    log INFO "Install prometheus service"
    cp ${this}/prometheus.service /etc/systemd/system/

    chown -R prometheus:prometheus /var/lib/prometheus

    chown -R prometheus:prometheus /etc/prometheus/rules
    chown -R prometheus:prometheus /etc/prometheus/rules.d
    chown -R prometheus:prometheus /etc/prometheus/files_sd

    chmod -R 775 /etc/prometheus/rules
    chmod -R 775 /etc/prometheus/rules.d
    chmod -R 775 /etc/prometheus/files_sd

    log INFO "Starting prometheus"
    systemctl enable --now prometheus

    log SUCCESS "Prometheus installed"
}

configNodeExporter(){
    _require_root

    echo "Input node exporter host ip: "
    read ip
    if [ -z "$ip" ];then
        log FATAL "empty ip address"
    fi

    local nodeExporterHeader="#node exporter begin"
    local nodeExporterTail="#node exporter end"

    # if grep "${nodeExporterHeader}" /etc/prometheus/prometheus.yml;then
    #     echo "already configured node exporter"
    # fi
    cat>>/etc/prometheus/prometheus.yml<<-EOF
	${nodeExporterHeader}
	  - job_name: 'node_exporter_metrics${ip}'
	    scrape_interval: 5s
	    static_configs:
	      - targets: ['$ip:9100']
	${nodeExporterTail}
	EOF

    log INFO "Restart prometheus"
    systemctl restart prometheus
}

installGrafana(){
    log INFO "Use docker compose to run grafana"
}

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
    #todo
  installNodeExporter)
    installNodeExporter "$@"
    ;;

  installPrometheus)
    installPrometheus "$@"
    ;;

  configNodeExporter)
    configNodeExporter "$@"
    ;;

  installGrafana)
    installGrafana "$@"
    ;;
 

  *)
    echo "Unknown command: $command" 1>&2
    show_help
    exit 1
    ;;
esac
