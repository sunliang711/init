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

# _runAsRoot Usage:
# 1. 单条命令
# _runAsRoot ls -l /root
# 2. 多行命令
# script=$(cat<<'EOF'
# ...
# EOF)
# _runAsRoot <<< "${script}"
# 3. 多行命令
# _runAsRoot<<'EOF'
# ...
# EOF
_runAsRoot() {
    local run_as_root

    # 判断当前是否是 root
    if [ "$(id -u)" -eq 0 ]; then
        run_as_root="bash -s"
    elif command -v sudo >/dev/null 2>&1; then
        run_as_root="sudo -E bash -s"
    elif command -v su >/dev/null 2>&1; then
        run_as_root="su -c 'bash -s'"
    else
        echo "Error: need sudo or su to run as root." >&2
        return 1
    fi

    if [ -t 0 ]; then
        # 交互式 shell：使用命令参数方式
        if [ $# -eq 0 ]; then
            echo "Usage: _runAsRootUniversal <command> [args...]" >&2
            return 1
        fi
        echo "[Running as root]: $*"
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            sudo "$@"
        fi
    else
        # 标准输入传入：执行多行脚本
        echo "[Running script as root via stdin]"
        $run_as_root
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

em(){
    $ed $0
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
COMMANDS=("help" "install" "uninstall" "enable" "disable" "config" "rename" "addClient" "removeClient" "listClients" "start" "stop" "restart" "status")

wireguardRoot=/etc/wireguard
# clientDir=${wireguardRoot}/clients
dbFileOnDisk=${wireguardRoot}/db
dbFile=/tmp/wireguard_db
interfaceName=wg0

serverPubkey=server-publickey
serverPrikey=server-privatekey

source ${wireguardRoot}/settings


install(){
    set -e
    _require_root
    cd ${this}
    apt update
    apt install wireguard qrencode iptables sqlite3 -y

    while true;do
        echo -n "Enter server port: "
        read serverPort

        if [ -z "$serverPort" ];then
            continue
        fi

        if ! echo "$serverPort" | grep -q '[0-9][0-9]*';then
            echo "invalid port"
            continue
        fi

        if ((serverPort >=1)) && ((serverPort <= 65535));then
            break
        else
            echo "port range invalid"
        fi
    done

    echo -n "Enter server endpoint(ip or domain):"
    read endpoint

    echo -n "Enter client gateway:"
    read clientGateway

    echo -n "Enter client DNS:"
    read clientDns

    ln -sf ${this}/wireguard.sh /usr/local/bin

    if [ ! -d ${wireguardRoot} ];then
        mkdir -p ${wireguardRoot}
    fi

    cat<<-EOF>${wireguardRoot}/settings
		serverEndpoint=${endpoint}
		serverPort=${serverPort}
		subnet=10.10.10
		serverIp=\${subnet}.1/24
		clientDns=${clientDns}
		clientGateway=${clientGateway}
		serverPubkey=${serverPubkey}
		serverPrikey=${serverPrikey}
		interfaceName=${interfaceName}
		serverConfigFile=\${interfaceName}.conf
		MTU=1420
		tableNo=10
	EOF


    _drop_in

    _configServer

}

_drop_in(){
    echo "-- generate override config file of wg-quick@ service"
    overrideFile=/etc/systemd/system/wg-quick@wg0.service.d/override.conf
    startPre="${this}/wireguard.sh _start_pre"
    startPost="${this}/wireguard.sh _start_post"
    stopPost="${this}/wireguard.sh _stop_post"
    sed -e "s|<start_pre>|${startPre}|" \
        -e "s|<start_post>|${startPost}|" \
        -e "s|<stop_post>|${stopPost}|" \
            override.conf >/tmp/override.conf

    if [ ! -d /etc/systemd/system/wg-quick@wg0.service.d ];then
        mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
    fi
    mv /tmp/override.conf ${overrideFile}
    systemctl daemon-reload

    # enable service
    systemctl enable wg-quick@wg0

}

_initDb(){
    if [ -n "$dbFileOnDisk" ];then
        echo "-- generate db file: ${dbFileOnDisk}"
        sqlite3 "$dbFile" "create table clients(name varchar unique,hostnumber int unique, privatekey varchar,publickey varchar,enable int);"
    fi
}

_configServer(){
    if [ ! -d ${wireguardRoot} ];then
        mkdir -p ${wireguardRoot}
    fi
    # create server key pair when not exist
    if [ ! -f ${wireguardRoot}/${serverPrikey} ];then
        echo "-- create server key pair file.."
        wg genkey | tee ${wireguardRoot}/${serverPrikey} | wg pubkey | tee ${wireguardRoot}/${serverPubkey}
    fi
    _initDb

}

uninstall(){
	_require_root
    /usr/local/bin/wireguard.sh stop
    if [ -e /usr/local/bin/wireguard.sh ];then
        rm -rf /usr/local/bin/wireguard.sh
    fi
    if [ -d ${wireguardRoot} ];then
        rm -rf ${wireguardRoot}
    fi
}

_start_pre(){
    echo "_start_pre()"
    # 生成服务端配置文件
    while true;do
		gwInterface=$(ip -o -4 route show to default | awk '{print $5}')
		if [ -n "${gwInterface}" ];then
			break
		fi
		echo "cannot get gateway interface, retry after 2 seconds..."
		sleep 2
	done
    # gwInterface=$(ip -o -4 route show to default | awk '{print $5}')
    echo "gateway interface: ${gwInterface}"
    cat<<-EOF>${wireguardRoot}/${serverConfigFile}
		[Interface]
		Address = ${serverIp}
		MTU = ${MTU}
		SaveConfig = true
		PreUp = sysctl -w net.ipv4.ip_forward=1
		PostUp = iptables -t nat -A POSTROUTING -o ${gwInterface} -j MASQUERADE;ip rule add from ${subnet}.0/24 table ${tableNo};ip route add default via ${clientGateway} table ${tableNo};
		PostDown = iptables -t nat -D POSTROUTING -o ${gwInterface} -j MASQUERADE; ip rule del from ${subnet}.0/24 table ${tableNo};ip route del default table ${tableNo};
		ListenPort = ${serverPort}
		PrivateKey = $(cat ${wireguardRoot}/${serverPrikey})
	EOF

    # 把dbFile复制到/tmp中，因为statusf会频繁的读写dbFile，把它移到内存(/tmp)中比较好
    cp ${dbFileOnDisk} ${dbFile}
}

_start_post(){
    echo "_start_post()"
    # 客户端 [Peer]
    # 查询数据库中所有enable为1的client，把它们加入到wg中
    records=`sqlite3 ${dbFile} "select name,hostnumber,publickey from clients where enable = 1;"`
    local name hostnumber privatekey publickey
    for r in ${records};do
        IFS=$'|'
        read name hostnumber publickey<<<"$r"
        echo "add peer: ${name} host: ${subnet}.${hostnumber}/32 publickey: ${publickey}"
        _liveAdd ${publickey} ${hostnumber}
    done

}

_save_db(){
    cp ${dbFile} ${dbFileOnDisk}
}

_stop_post(){
    echo "_stop_post()"

    # 服务关闭后，把db文件写回硬盘
    _save_db
}

_liveAdd(){
    pubkey=$1
    hostnumber=$2
    wg set ${interfaceName} peer "${pubkey}" allowed-ips "${subnet}.${hostnumber}/32"
}

_liveRm(){
    pubkey=$1
    wg set ${interfaceName} peer "${pubkey}" remove
}

_isRunning(){
    ip a s ${interfaceName} >/dev/null 2>&1
}

enable(){
    clientName="${1:?'missing client name'}"
    records=`sqlite3 ${dbFile} "select hostnumber,publickey,enable from clients where name = '${clientName}';"`
    if [ -z "$records" ];then
        echo "no such client"
        exit 1
    fi

    # 只有一条记录，不需要循环
    local hostnumber publickey enable
    IFS=$'|'
    read hostnumber publickey enable<<<"$records"

    if ((enable==1));then
        echo "already enabled"
        exit
    fi

    sqlite3 ${dbFile} "update clients set enable = 1 where name = '${clientName}' "
    if _isRunning;then
        echo "-- wireguard is running, add client to it"
        _liveAdd "${publickey}" "${hostnumber}"
    fi

    _save_db
}

disable(){
    clientName="${1:?'missing client name'}"
    records=`sqlite3 ${dbFile} "select hostnumber,publickey,enable from clients where name = '${clientName}';"`
    if [ -z "$records" ];then
        echo "no such client"
        exit 1
    fi

    # 只有一条记录，不需要循环
    local hostnumber publickey enable
    IFS=$'|'
    read hostnumber publickey enable<<<"$records"

    if ((enable==0));then
        echo "already disabled"
        exit
    fi

    sqlite3 ${dbFile} "update clients set enable = 0 where name = '${clientName}' "
    if _isRunning;then
        echo "-- wireguard is running, remove client to it"
        _liveRm ${publickey}
    fi
    _save_db
}

config(){
    set -e
    settingsFile=${wireguardRoot}/settings

    before="$(md5sum ${settingsFile} | awk '{ print $1}')"
    $ed ${wireguardRoot}/settings
    after="$(md5sum ${settingsFile} | awk '{ print $1}')"
    if [ "$before" != "$after" ];then
        echo "${wireguardRoot}/settings changed, restart on your needs"
    fi
}

rename(){
    clientName="${1:?'missing client name'}"
    newName="${2:?'missing new name'}"
    records=`sqlite3 ${dbFile} "select hostnumber,publickey,enable from clients where name = '${clientName}';"`
    if [ -z "$records" ];then
        echo "no such client"
        exit 1
    fi

    sqlite3 "${dbFile}" "update clients set name = '${newName}' where name = '${clientName}'"
    _save_db
}

addClient(){
    set -e
    _require_root
    if (($#<1));then
        cat<<-EOF0
			usage: addClient <client_name> [host_number]

			[host_number]:          x of ${subnet}.x valid range: 2-254
		EOF0
        exit 1
    fi

    clientName=${1:?'missing client name'}
    hostNumber=${2}
    if [ -z "${hostNumber}" ];then
        # find a host number
        hostnumbers=`sqlite3 ${dbFile} "select hostnumber from clients;"`

        for ((idx=2;idx<=254;idx++));do
            if ! printf "%s" "${hostnumbers}" | grep -qw "${idx}";then
                break
            fi
        done
        if ((idx>254));then
            echo "no avaiable hostnumber!"
            exit 1
        fi

        echo "hostnumber: ${idx}"
        hostNumber=${idx}
    fi

    r=`sqlite3 ${dbFile} "select name from clients where name = '${clientName}' or hostnumber = ${hostNumber};"`
    if [ -n "$r" ];then
        echo "client name or hostNumber already exists"
        exit 1
    fi

    privatekey="$(wg genkey)"
    publickey="$(echo ${privatekey} | wg pubkey)"

    # add to db
    # values中类型如果是varchar，需要加上单引号
    # enable 默认为1
    sqlite3 "${dbFile}" "insert into clients(name,hostnumber,privatekey,publickey,enable) values('${clientName}',$hostNumber,'${privatekey}','${publickey}',1);"

    # 如果服务正在运行，需要把peer加入到wg0中
    if _isRunning;then
        echo "-- wireguard is running, add client to it"
        _liveAdd "${publickey}" "${hostNumber}"

    fi
    _save_db

    exportClient "${clientName}"
}

removeClient(){
    clientName=${1:?'missing client name'}
    _require_root
    set -e

    publickey=`sqlite3 ${dbFile} "select publickey from clients where name = '${clientName}';"`
    if [ -z "$publickey" ];then
        echo "no such client"
        exit 1
    fi

    sqlite3 "${dbFile}" "delete from clients where name = '${clientName}';"
    _save_db

    if _isRunning;then
        echo "-- wireguard is running, remove client from it"
        _liveRm "$publickey"
    fi

}

listClient(){
    flag=${1}
    records=`sqlite3 ${dbFile} "select name,hostnumber,privatekey,publickey,enable from clients;"`
    if [ -z "${records}" ];then
        echo "no clients"
        exit 0
    fi

    local name hostnumber privatekey publickey enable

    if [[ "${flag}" == "--insecure" ]];then
        printf "%-15s %-15s %-50s %-50s %-18s\n" "name" "ip" "privatekey" "publickey" "enable"
    else
        printf "%-15s %-15s %-50s %-18s\n" "name" "ip" "publickey" "enable"
    fi
    for r in $records;do
        IFS=$'|'
        read name hostnumber privatekey publickey enable<<<"$r"

        if [[ "${flag}" == "--insecure" ]];then
            printf "%-15s %-15s %-50s %-50s %-18s\n" "$name" "${subnet}.${hostnumber}" "${privatekey}" "${publickey}" "${enable}"
        else
            printf "%-15s %-15s %-50s %-18s\n" "$name" "${subnet}.${hostnumber}" "${publickey}" "${enable}"
        fi
    done

}

start(){
    set -e
    _require_root
    echo "Note: when start or restart, Must close clash gateway service!!"
    systemctl start wg-quick@wg0
}

stop(){
    set -e
    _require_root
    systemctl stop wg-quick@wg0
}

exportClient(){
    clientName=${1:?'missing client name'}
    set -e
    _require_root

    records=`sqlite3 ${dbFile} "select hostnumber,privatekey,publickey from clients where name = '${clientName}';"`
    if [ -z "$records" ];then
        echo "no such client"
        exit 1
    fi

    local name hostnumber privatekey publickey
    for r in ${records};do
        IFS=$'|'
        read hostnumber privatekey publickey<<<"$r"
        echo "-- generate client ${clientName} config file"
        clientConfigFile=/tmp/client-${clientName}.conf
        cat<<-EOF>${clientConfigFile}
			[Interface]
			    PrivateKey = ${privatekey}
			    Address = ${subnet}.${hostnumber}/24
			    DNS = ${clientDns}
			    MTU = ${MTU}

			[Peer]
			    PublicKey = $(cat ${wireguardRoot}/${serverPubkey})
			    Endpoint = ${serverEndpoint}:${serverPort}
			    AllowedIPs = 0.0.0.0/0, ::0/0
			    PersistentKeepalive = 25

		EOF
        cat ${clientConfigFile} | qrencode -t ansiutf8
        cat ${clientConfigFile}
    done

}

restart(){
    stop
    start
}

status(){
    _status
}

_status(){
    flag=${1}

    printf "server endpoint: %s\n" ${serverEndpoint}
    printf "server port: %s\n" ${serverPort}
    printf "client gateway: %s\n" ${clientGateway}
    printf "client DNS: %s\n" ${clientDns}
    printf "MTU: %s\n" ${MTU}
    echo

    records=`sqlite3 ${dbFile} "select name,privatekey,publickey,enable from clients where enable=1;"`
    if [ -z "${records}" ];then
        echo "no clients"
    fi

    local name privatekey publickey enable
    declare -A pubkey2name
    declare -A pubkey2enable

    oldIFS="$IFS"
    for r in $records;do
        IFS=$'|'
        read name privatekey publickey enable<<<"$r"
        pubkey2name[$publickey]=$name
        pubkey2enable[$publickey]=$enable
    done
    IFS="$oldIFS"

    while read line;do
        if echo "$line" | grep -q peer;then
            pubkey=`echo $line | perl -lne 'print $1 if /peer: (.+)$/'`
            printf "name: %s\n" ${pubkey2name[$pubkey]}
            printf "enable: %s\n" ${pubkey2enable[$pubkey]}

            if [[ ${flag} == "--insecure" ]];then
                printf "private key: %s\n" ${privatekey}
            fi
        fi
        echo "$line"
    done<<<$(wg)

    records2=`sqlite3 ${dbFile} "select name,hostnumber,privatekey,publickey,enable from clients where enable=0;"`
    oldIFS="$IFS"
    for r in $records2;do
        IFS=$'|'
        read name hostnumber privatekey publickey enable<<<"$r"
        printf "\nname: %s\n" $name
        printf "enable: %s\n" $enable
        if [[ ${flag} == "--insecure" ]];then
            printf "private key: %s\n" $privatekey
        fi
        printf "peer: %s\n" $publickey
        printf "ip: %s\n" $subnet.$hostnumber
    done
    IFS="$oldIFS"
}


statusf(){
    flag=$1
    watch -n 1 $0 _status ${flag}
}

reload(){
    interface=wg0
    echo "reload config.."
    wg-quick strip ${interface} >/tmp/wireguard.conf
    wg syncconf ${interface} /tmp/wireguard.conf
    rm /tmp/wireguard.conf
}


# write your code above
###############################################################################
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
