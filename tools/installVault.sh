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

# run command with trace in subshell
# support interactive mode and script mode
# Usage:
# 1. 单条命令
# _run ls -l /root
# 2. 多行命令
# script=$(cat<<'EOF'
# ...
# EOF)
# _run <<< "${script}"
# 3. 多行命令
# _run<<'EOF'
# ...
# EOF
_run(){
  if [ -t 0 ]; then
    # interactive mode
    if [ $# -eq 0 ]; then
      echo "Usage: _run <command> [args...]" >&2
      return 1
    fi
    (
      set -x
      "$@"
    )
  else
    # script mode
    (
      set -x
      bash -s
    )
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

detect_os(){
  osRE=
  machineRE=
  case $(uname -s) in
    Linux)
      osRE='linux'
      ;;
    Darwin)
      osRE='darwin|mac'
      ;;
    *)
      log FATAL "unsupported os: $(uname -s)"
      ;;
  esac
  log INFO "osRE: ${osRE}"
  case $(uname -m) in
  x86_64 | amd64)
    machineRE='amd64|x86_64'
    ;;
  i686 | 386)
    machineRE='386|i686'
    ;;
  arm64 | aarch64)
    machineRE='arm64|aarch64'
    ;;
  esac
  log INFO "machineRE: ${machineRE}"
  export osRE
  export machineRE
}

get_release_link(){
  local repo=$1
  local version=$2
  # 如果version为latest，则获取latest
  if [ "$version" == "latest" ]; then
    resultLink="https://api.github.com/repos/${repo}/releases/latest"
  else
    # check version with regex(1.2 1.2.3)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      resultLink="https://api.github.com/repos/${repo}/releases/tags/v${version}"
    else
      log FATAL "invalid version: $version"
    fi
  fi
  log INFO "resultLink: ${resultLink}"

  detect_os

  # 移除参数
  shift 2
  # 剩下的所有参数为过滤参数:形式为各种shell命令,比如: grep gz, grep aa, head -1
  local filters=("$@")

  # get unique link
  # 1. grep browser_download_url
  # 2. grep -i ${osRE}
  # 3. grep -i ${machineRE}
  # 4. apply filters to ensure get unique link
  # 5. cut -d '"' -f 4
  link0=$(curl -s ${resultLink} | grep browser_download_url | grep -iE "${osRE}" | grep -iE "${machineRE}")
  log INFO "link0: ${link0}"
  for filter in "${filters[@]}"; do
    log INFO "apply filter: ${filter}"
    link0=$(echo $link0 | $filter)
    log INFO "filtered link0: ${link0}"
  done
  link=$(echo $link0 | cut -d '"' -f 4)
  log INFO "link: ${link}"

  export link
}

em(){
	$ed $0
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "install")
version=1.21.0
vaultLink=https://releases.hashicorp.com/vault/${version}/vault_${version}_linux_amd64.zip
zipFile=${vaultLink##*/}
vaultDir=/opt/vault
vaultBinDir=${vaultDir}/bin
vault=${vaultBinDir}/vault
defaultDownloadDir=/tmp/vaultDownload
initDir=${vaultDir}/init

download(){
  downloadDir=${1:-${defaultDownloadDir}}

  # if already downloaded, skip
  if [ -f ${downloadDir}/${zipFile} ]; then
    log INFO "already downloaded, skip"
    return
  fi

  set -e
  _require_commands curl
  _ensureDir ${downloadDir}

  cd ${downloadDir}
  log INFO "downloading vault to ${downloadDir}"
  curl -L -O ${vaultLink}
}

install() {
  # _require_linux
  set -e
  _require_root
  _require_commands unzip
  _ensureDir ${vaultBinDir}
  download

  # vaultDir owner: root mod: 700
  chmod -R 700 ${vaultDir}

  # install vault to ${binDir}
  log INFO "installing vault to ${vaultBinDir}"
  cd ${defaultDownloadDir}
   _runAsRoot unzip -d ${vaultBinDir} ${zipFile}

   # create conf data logs ssl init dir inside ${vaultDir}
   _ensureDir ${vaultDir}/conf
   _ensureDir ${vaultDir}/data
   _ensureDir ${vaultDir}/logs
   _ensureDir ${vaultDir}/ssl
   _ensureDir ${vaultDir}/init

   # config.hcl to ${vaultDir}/conf/config.hcl
   cat<<EOF1 > ${vaultDir}/conf/config.hcl
   storage "file" {
     path = "${vaultDir}/data/"
   }
   listener "tcp" {
     address = "0.0.0.0:8200"
     tls_disable = "false"
     tls_cert_file = "${vaultDir}/ssl/server.crt"
     tls_key_file = "${vaultDir}/ssl/server.key"
   }
   ui = true
   api_addr = "http://127.0.0.1:8200"
   cluster_addr = "http://127.0.0.1:8201"
   # log_level = "info"
   # log_format = "json"
EOF1

log INFO "install systemd service"
# install systemd service
cat<<EOF2 > /etc/systemd/system/vault.service
[Unit]
Description=Vault
After=network.target

[Service]
ExecStart=${vaultBinDir}/vault server -config=${vaultDir}/conf/config.hcl

[Install]
WantedBy=multi-user.target
EOF2

  generate_ssl_cert


  systemctl daemon-reload
  log INFO "enable and start vault service"
  systemctl enable --now vault
}

generate_ssl_cert(){
	set -e
  #generate ssl cert
  cd ${vaultDir}/ssl

  # 1. 生成CA私钥
  openssl genrsa -out ca.key 4096

  # 2. 生成CA自签名证书
  cat >ca.conf<<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
C = CN
ST = HongKong
L = HongKong
O =Vault
OU = Vault CA
CN = vault-root-ca

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
EOF
  openssl req -x509 -new -nodes -key ca.key \
    -days 3650 \
    -out ca.crt \
    -config ca.conf \
    -extensions v3_ca

# 3. 生成服务器私钥和证书签名请求(CSR)

  cat<<EOF2 > server.conf
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
C = CN
ST = HongKong
L = HongKong
O = Vault
OU = Vault
CN = vault-server

[v3_req]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = vault.local
DNS.3 = vault-server
IP.1 = 127.0.0.1
IP.2 = 0.0.0.0
EOF2
  openssl genrsa -out server.key 4096
  openssl req -new -key server.key -out server.csr -config server.conf

  cat >server_ext.conf<<EOF3
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = vault.local
DNS.3 = vault-server
IP.1 = 127.0.0.1
EOF3

  log INFO "generating ssl cert to ${vaultDir}/ssl"
  openssl x509 -req \
    -in server.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
	-out server.crt \
	-days 3650 \
	-extfile server_ext.conf

  chmod 600 server.key ca.key
  chmod 644 server.crt ca.crt

  echo "run init subcommand to initialize vault"
}

exportVars(){
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=${vaultDir}/ssl/ca.crt
}
exportVaultToken(){
  export VAULT_TOKEN=$(cat ${initDir}/root_token.output)
}

init(){
  set -e
  _ensureDir ${initDir}
  _require_root
  keyShares=${1:-5}
  keyThreshold=${2:-3}

  exportVars

  cd ${initDir}
  log INFO "initializing vault, key-shares=${keyShares}, key-threshold=${keyThreshold} dest=${initDir}"
  ${vault} operator init -key-shares=${keyShares} -key-threshold=${keyThreshold} > init.output

  # 把init.output中的unseal keys和root token拆分到多个文件中
  # 每个文件包含一个unseal key和一个root token
  # 文件名格式为unseal_key_${i}.txt和root_token_${i}.txt
  # 其中i从1到keyShares
  for i in $(seq 1 ${keyShares}); do
    grep "Unseal Key ${i}:" init.output | awk -F ": " '{print $2}' > unseal_key_${i}.output
  done
  grep "Initial Root Token:" init.output | awk -F ": " '{print $2}' > root_token.output

  echo "run unseal subcommand to unseal or by webui"
  echo "run enableKv subcommand to enable kv or by webui"
  echo "run enableAuth subcommand to enable auth or by webui"
}
#TODO
# 日志输出放到一个normal用户可以读的地方

# init后执行unseal,根据shamir算法的配置，需要多次unseal才能完全解密
# 或者https://<IP>:8200/ui/vault/unseal中操作，多次unseal
unseal(){
  echo "may be unseal multiple times"
  exportVars
  ${vault} operator unseal
}

enableKv(){
  exportVars
  exportVaultToken
  ${vault} secrets enable -version=2 kv
}

enableAuth(){
  exportVars
  exportVaultToken
  ${vault} auth enable userpass
}

uninstall(){
	_require_root
	set -e
	# stop service
	systemctl disable --now vault
	# rm vault files
	rm -rf ${vaultDir}
	rm -rf /etc/systemd/system/vault.service
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
