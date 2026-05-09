#!/bin/bash

set -euo pipefail

function log(){
    printf '%s\n' "$*" >&2
}

# 输出 RouterOS 双引号字符串，避免特殊字符破坏命令结构
function rosQuote(){
    local value="${1:-}"
    if [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
        log "RouterOS value contains unsupported newline"
        exit 1
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    printf '"%s"' "$value"
}

function ipv4ToInt(){
    local ip="$1"
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    if ! [[ "${o1:-}" =~ ^[0-9]+$ && "${o2:-}" =~ ^[0-9]+$ && "${o3:-}" =~ ^[0-9]+$ && "${o4:-}" =~ ^[0-9]+$ ]]; then
        log "Invalid IPv4 address: $ip"
        exit 1
    fi
    local n1=$((10#$o1))
    local n2=$((10#$o2))
    local n3=$((10#$o3))
    local n4=$((10#$o4))
    if (( n1 > 255 || n2 > 255 || n3 > 255 || n4 > 255 )); then
        log "Invalid IPv4 address: $ip"
        exit 1
    fi
    printf '%u\n' "$(( (n1 << 24) + (n2 << 16) + (n3 << 8) + n4 ))"
}

function intToIPv4(){
    local value="$1"
    printf '%u.%u.%u.%u\n' \
        "$(( (value >> 24) & 255 ))" \
        "$(( (value >> 16) & 255 ))" \
        "$(( (value >> 8) & 255 ))" \
        "$(( value & 255 ))"
}

# 读取用户输入
# arg1: 提示信息
# arg2: 是否是敏感信息
# arg3: 是否是必填
# 结果通过环境变量input返回
# 如果输入为空则在循环中重新读取
function readInput(){
    if (($# < 3)); then
        log "Usage: readInput <prompt> <sensitive:yes|no> <required:yes|no>"
        exit 1
    fi
    local prompt="$1"
    local sensitive="$2"
    local required="$3"
    while true; do
        if [ "$sensitive" = "yes" ]; then
            read -r -s -p "$prompt" input
            printf '\n' >&2
        else
            read -r -p "$prompt" input
        fi
        if [ -n "$input" ] || [ "$required" = "no" ]; then
            export input="$input"
            break
        fi
    done
}

function trim(){
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

function setConfigValue(){
    local key="$1"
    local value="$2"
    case "$key" in
        subnet|pppoeUser|pppoePassword|emailUser|emailPassword|emailHost|sshPort|wwwPort|winboxPort|adminUser|adminUserPassword|dnsServer|brName|poolName|pppoeName)
            printf -v "$key" '%s' "$value"
            ;;
        *)
            log "Unsupported config key: $key"
            exit 1
            ;;
    esac
}

function setupOptionKey(){
    case "$1" in
        --subnet) printf '%s' "subnet" ;;
        --pppoe-user) printf '%s' "pppoeUser" ;;
        --pppoe-password) printf '%s' "pppoePassword" ;;
        --email-user) printf '%s' "emailUser" ;;
        --email-password) printf '%s' "emailPassword" ;;
        --email-host) printf '%s' "emailHost" ;;
        --ssh-port) printf '%s' "sshPort" ;;
        --www-port) printf '%s' "wwwPort" ;;
        --winbox-port) printf '%s' "winboxPort" ;;
        --admin-user) printf '%s' "adminUser" ;;
        --admin-user-password) printf '%s' "adminUserPassword" ;;
        --dns-server) printf '%s' "dnsServer" ;;
        --br-name) printf '%s' "brName" ;;
        --pool-name) printf '%s' "poolName" ;;
        --pppoe-name) printf '%s' "pppoeName" ;;
        *)
            log "Unknown setup option: $1"
            log "Usage: $0 setup [-c|--config FILE] [options]"
            exit 1
            ;;
    esac
}

function addSetupArg(){
    local key="$1"
    local value="$2"
    setupArgKeys+=("$key")
    setupArgValues+=("$value")
}

function applySetupArgs(){
    local i
    for i in "${!setupArgKeys[@]}"; do
        setConfigValue "${setupArgKeys[$i]}" "${setupArgValues[$i]}"
    done
}

# 读取白名单 key=value 配置，避免直接 source 执行任意 Shell 代码
function loadConfig(){
    local configFile="$1"
    local line key value lineNo
    lineNo=0

    if [ ! -f "$configFile" ]; then
        log "Config file does not exist: $configFile"
        exit 1
    fi
    if [ ! -r "$configFile" ]; then
        log "Config file is not readable: $configFile"
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        lineNo=$((lineNo + 1))
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            log "Invalid config line $lineNo: missing '='"
            exit 1
        fi

        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log "Invalid config key at line $lineNo: $key"
            exit 1
        fi
        setConfigValue "$key" "$value"
    done < "$configFile"
}

function parseSetupArgs(){
    local key option value
    while (($# > 0)); do
        case "$1" in
            -c|--config)
                if (($# < 2)); then
                    log "Missing config file after $1"
                    exit 1
                fi
                configFile="$2"
                shift 2
                ;;
            --config=*)
                configFile="${1#--config=}"
                if [ -z "$configFile" ]; then
                    log "Missing config file after --config="
                    exit 1
                fi
                shift
                ;;
            --*=*)
                option="${1%%=*}"
                value="${1#*=}"
                key="$(setupOptionKey "$option")"
                addSetupArg "$key" "$value"
                shift
                ;;
            --subnet|--pppoe-user|--pppoe-password|--email-user|--email-password|--email-host|--ssh-port|--www-port|--winbox-port|--admin-user|--admin-user-password|--dns-server|--br-name|--pool-name|--pppoe-name)
                if (($# < 2)); then
                    log "Missing value after $1"
                    exit 1
                fi
                key="$(setupOptionKey "$1")"
                addSetupArg "$key" "$2"
                shift 2
                ;;
            -h|--help)
                help
                exit 0
                ;;
            *)
                log "Unknown setup option: $1"
                log "Usage: $0 setup [-c|--config FILE] [options]"
                exit 1
                ;;
        esac
    done
}

# 使用ipcalc计算出HostMin和HostMax
function calculateHostMinAndHostMax(){
    local subnet="$1"

    # 检查ipcalc是否安装
    if ! command -v ipcalc &> /dev/null; then
        log "ipcalc could not be found, please install it"
        exit 1
    fi

    # 验证子网格式
    if ! [[ "$subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log "Invalid subnet format: $subnet, please use format: a.b.c.d/e"
        exit 1
    fi

    local ipcalcOutput
    ipcalcOutput=$(ipcalc -n "$subnet")
    hostMin=$(printf '%s\n' "$ipcalcOutput" | awk 'tolower($1)=="hostmin:" {print $2; exit}')
    hostMax=$(printf '%s\n' "$ipcalcOutput" | awk 'tolower($1)=="hostmax:" {print $2; exit}')
    netmask=$(printf '%s\n' "$ipcalcOutput" | awk 'tolower($1)=="netmask:" {print $4; exit}')
    dhcpNetwork=$(printf '%s\n' "$ipcalcOutput" | awk 'tolower($1)=="network:" {print $2; exit}')
    adminIP="$hostMin/$netmask"
    gateway="$hostMin"

    # 验证结果
    if [ -z "$hostMin" ] || [ -z "$hostMax" ]; then
        log "Failed to calculate network parameters"
        exit 1
    fi

    # DHCP 地址池避开网关地址
    local hostMinInt hostMaxInt dhcpStartInt
    hostMinInt=$(ipv4ToInt "$hostMin")
    hostMaxInt=$(ipv4ToInt "$hostMax")
    dhcpStartInt=$((hostMinInt + 1))
    if (( dhcpStartInt > hostMaxInt )); then
        log "Subnet does not have enough usable hosts for DHCP range after gateway"
        exit 1
    fi
    dhcpRange="$(intToIPv4 "$dhcpStartInt")-$hostMax"

    export hostMin="$hostMin"
    export hostMax="$hostMax"
    export netmask="$netmask"
    export adminIP="$adminIP"
    export gateway="$gateway"
    export dhcpNetwork="$dhcpNetwork"
    export dhcpRange="$dhcpRange"
}

function setupInterface(){
cat<<EOF
  :global renameEthernetPort do={

    # 设置wan口使用几号口
    :local wanPort 1
    :local portNum 0

    :foreach i in=[/interface ethernet find] do={
      :local oldName [/interface ethernet get \$i name]
      :set portNum (\$portNum + 1)

      # 提取端口号（假设格式为 etherX）
      :if (\$portNum = \$wanPort) do={
        /interface ethernet set \$i name="\$oldName.wan"
        :log info "Set \$oldName to WAN"
      } else={
        /interface ethernet set \$i name="\$oldName.lan"
        :log info "Set \$oldName to LAN"
      }
    }
  }
  \$renameEthernetPort
EOF

  # 创建网桥
  echo "/interface bridge add name=$(rosQuote "$brName")"

  # 将所有重命名后的lan口加入网桥
cat<<EOF
  :foreach i in=[/interface ethernet find where name~".*[.]lan\\$"] do={
    :local lanName [/interface ethernet get \$i name]
    /interface bridge port add bridge=$(rosQuote "$brName") interface=\$lanName
  }
EOF
  # 给网桥设置ip地址
  echo "/ip address add address=$adminIP interface=$(rosQuote "$brName")"
}

function setupDHCP(){
  # 增加ip地址池
  echo "/ip pool add name=$(rosQuote "$poolName") ranges=$dhcpRange"
  # 设置dhcp server
  echo "/ip dhcp-server add address-pool=$(rosQuote "$poolName") disabled=no interface=$(rosQuote "$brName") lease-time=7d"
  # 设置dhcp server的dns 和网关，用于给内网的dhcp客户端分配ip时使用
  echo "/ip dhcp-server network add address=$dhcpNetwork dns-server=$dnsServer gateway=$gateway"
}

function setupPPPoE(){
  # 设置pppoe拨号
  echo "/interface pppoe-client add disabled=no interface=$(rosQuote "$wanName") user=$(rosQuote "$pppoeUser") password=$(rosQuote "$pppoePassword") add-default-route=yes use-peer-dns=no name=$(rosQuote "$pppoeName")"
  # 设置snat让内网设备可以上网
  echo "/ip firewall nat add chain=srcnat action=masquerade out-interface=$(rosQuote "$pppoeName")"
  # 设置dns server
  echo "/ip dns set servers=$dnsServer allow-remote-requests=yes"
}

function setupFirewall(){
  lanAddressList="lan"
  # 设置routerOS内置的ddns
  echo "/ip cloud set ddns-enabled=yes ddns-update-interval=2m update-time=yes"
  # 设置防火墙 address-list
  echo "/ip firewall address-list add address=${hostMin}-${hostMax} list=${lanAddressList}"
  # 设置established related
  echo "/ip firewall filter add action=accept chain=input comment=\"established related\" connection-state=established,related"
  # 设置防火墙
  echo "/ip firewall filter add action=drop chain=input comment=\"drop blacklist\" src-address-list=blacklist"
  # upnp非白名单的ip拒绝
  echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=2828 protocol=tcp reject-with=icmp-network-unreachable src-address-list=!upnplist"
  echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=1900 protocol=udp src-address-list=!upnplist"

  # 允许lan口流量
  echo "/ip firewall filter add action=accept chain=input comment=\"allow lan traffic\" src-address-list=${lanAddressList}"
  # 允许icmp
  echo "/ip firewall filter add action=accept chain=input comment=\"allow icmp\" protocol=icmp"
  # 允许ssh端口(并且是内网地址)
  echo "/ip firewall filter add action=accept chain=input comment=\"allow ssh port from lan\" dst-port=${sshPort} protocol=tcp src-address-list=${lanAddressList}"
  # 允许www端口
  echo "/ip firewall filter add action=accept chain=input comment=\"allow www port\" dst-port=${wwwPort} protocol=tcp"
  # 允许winbox端口(并且是内网地址)
  echo "/ip firewall filter add action=accept chain=input comment=\"allow winbox port from lan\" dst-port=${winboxPort} protocol=tcp src-address-list=${lanAddressList}"
  # 拒绝其他流量
  echo "/ip firewall filter add action=drop chain=input comment=\"drop other traffic\""
}

function setupUser(){
  # 新增用户
  echo "/user add name=$(rosQuote "$adminUser") password=$(rosQuote "$adminUserPassword") group=full"
  # 禁用admin
  echo "/user disable admin"
}

function setupService(){
  # 禁用用不到的服务：telnet ftp ap api-ssl
  echo "/ip service disable telnet,ftp,api,api-ssl"
  # 设置ssh 端口
  echo "/ip service set ssh port=$sshPort"
  # 设置 web端口
  echo "/ip service set www port=$wwwPort"
}

function setupEmail(){
  # 设置email stmp信息
  if [ -n "$emailUser" ] && [ -n "$emailPassword" ] && [ -n "$emailHost" ]; then
    echo "/tool e-mail set from=$(rosQuote "$emailUser") user=$(rosQuote "$emailUser") password=$(rosQuote "$emailPassword") server=$(rosQuote "$emailHost")"
  else
    echo "# emailUser, emailPassword, emailHost is not set, skip email setup"
  fi
}

function setup(){
  pppoeUser="${pppoeUser:-}"
  pppoePassword="${pppoePassword:-}"

  emailUser="${emailUser:-}"
  emailPassword="${emailPassword:-}"
  emailHost="${emailHost:-smtp.163.com}"

  wanInterface="ether1"
  wanName="${wanInterface}.wan"

  sshPort="${sshPort:-20000}"
  wwwPort="${wwwPort:-8000}"
  winboxPort="${winboxPort:-8291}"

  adminUser="${adminUser:-userxx1}"
  adminUserPassword="${adminUserPassword:-}"
  if [ -z "$adminUserPassword" ]; then
      readInput "adminUserPassword: " "yes" "yes"
      adminUserPassword="$input"
  fi

  subnet="${subnet:-10.1.0.0/24}"
  calculateHostMinAndHostMax "$subnet"
  log "hostMin: $hostMin"
  log "hostMax: $hostMax"
  log "netmask: $netmask"
  log "adminIP: $adminIP"
  log "gateway: $gateway"
  log "dhcpNetwork: $dhcpNetwork"
  log "dhcpRange: $dhcpRange"

  dnsServer="${dnsServer:-223.5.5.5,114.114.114.114}"

  brName="${brName:-br-lan}"
  poolName="${poolName:-dhcpPool1}"
  pppoeName="${pppoeName:-pppoe-out1}"
  # generate routeros command line

  # check
  if [ -z "$pppoeUser" ]; then
      readInput "pppoeUser: " "no" "yes"
      pppoeUser="$input"
  fi
  if [ -z "$pppoePassword" ]; then
      readInput "pppoePassword: " "yes" "yes"
      pppoePassword="$input"
  fi


  log "run '/system/reset-configuration no-defaults=yes skip-backup=yes' to reset routerOS"
  echo ":global setup do={"
  setupInterface
  setupDHCP
  setupPPPoE
  setupService
  setupEmail
  setupFirewall
  setupUser
  echo "}"
  echo "\$setup"
  log "setup will run after RouterOS reset imports it"

}

function printConfigTemplate(){
cat<<'EOF'
# ros-setup config file
# Lines beginning with # are ignored.

subnet=10.1.0.0/24
dnsServer=223.5.5.5,114.114.114.114

sshPort=20000
wwwPort=8000
winboxPort=8291

adminUser=userxx1
# adminUserPassword=

pppoeUser=
# pppoePassword=

emailHost=smtp.163.com
# emailUser=
# emailPassword=

brName=br-lan
poolName=dhcpPool1
pppoeName=pppoe-out1
EOF
}

function configTemplate(){
    if (($# > 1)); then
        log "Usage: $0 config-template [FILE]"
        exit 1
    fi

    local outputFile="${1:-}"
    if [ -z "$outputFile" ]; then
        printConfigTemplate
        return
    fi
    if [ -e "$outputFile" ]; then
        log "Config template target already exists: $outputFile"
        exit 1
    fi

    # 模板可能后续填写敏感信息，创建文件时默认限制权限
    ( umask 077; printConfigTemplate > "$outputFile" )
    log "Config template written to: $outputFile"
}

function help(){
    echo "Usage: <key1=val1> <key2=val2> ... $0 setup [-c|--config FILE] [options]"
    echo "       $0 config-template [FILE]"
    echo "       $0 <help|-h|--help>"
    echo "setup options:"
    echo "  -c, --config FILE: load setup config file"
    echo "  --subnet CIDR"
    echo "  --pppoe-user USER"
    echo "  --pppoe-password PASSWORD"
    echo "  --email-user USER"
    echo "  --email-password PASSWORD"
    echo "  --email-host HOST"
    echo "  --ssh-port PORT"
    echo "  --www-port PORT"
    echo "  --winbox-port PORT"
    echo "  --admin-user USER"
    echo "  --admin-user-password PASSWORD"
    echo "  --dns-server SERVERS"
    echo "  --br-name NAME"
    echo "  --pool-name NAME"
    echo "  --pppoe-name NAME"
    echo "setup config/env vars:"
    echo "  subnet: subnet, default: 10.1.0.0/24"
    echo "  pppoeUser: pppoe user"
    echo "  pppoePassword: pppoe password"
    echo "  emailUser: email user, default: user@163.com"
    echo "  emailPassword: email password, default: user@163.com"
    echo "  emailHost: email host, default: smtp.163.com"
    echo "  sshPort: ssh port, default: 20000"
    echo "  wwwPort: www port, default: 8000"
    echo "  winboxPort: winbox port, default: 8291"
    echo "  adminUser: admin user, default: userxx1"
    echo "  adminUserPassword: admin user password"
    echo "  dnsServer: dns server, default: 223.5.5.5,114.114.114.114"
    echo "  brName: bridge name, default: br-lan"
    echo "  poolName: pool name, default: dhcpPool1"
    echo "  pppoeName: pppoe name, default: pppoe-out1"
    echo "rsc workflow:"
    echo "  1. Generate rsc file:"
    echo "     $0 setup -c config/home.conf > setup.rsc"
    echo "  2. Serve rsc file from this directory:"
    echo "     python3 -m http.server 18080"
    echo "  3. Download setup.rsc on RouterOS:"
    echo "     /tool fetch url=\"http://HOST_IP:18080/setup.rsc\" mode=http dst-path=setup.rsc"
    echo "  4. Reset RouterOS and run setup.rsc after reset:"
    echo "     /system/reset-configuration no-defaults=yes skip-backup=yes run-after-reset=setup.rsc"
    echo "GNS3 test workflow:"
    echo "  1. Add a Cloud node and bind it to a host-only/VMnet/TAP interface."
    echo "  2. Connect RouterOS to the Cloud node with a temporary management interface."
    echo "  3. Configure a temporary RouterOS IP, for example:"
    echo "     /ip address add address=192.168.56.10/24 interface=ether1"
    echo "  4. Ping the host IP before fetch:"
    echo "     /ping 192.168.56.1"
    echo "  5. Replace HOST_IP in the fetch command with the reachable host IP."
    echo "  Note: if ether1 is also the WAN port, reset setup may rename it and disconnect the temporary link."
}

cmd=${1:-}
configFile=""
setupArgKeys=()
setupArgValues=()
case $cmd in
    setup)
        shift
        parseSetupArgs "$@"
        if [ -n "$configFile" ]; then
            loadConfig "$configFile"
        fi
        applySetupArgs
        setup
        ;;
    config-template)
        shift
        configTemplate "$@"
        ;;
    help|-h|--help)
        help
        ;;
    *)
        echo "Usage: $0 <setup|config-template|help|-h|--help>"
        exit 1
        ;;
esac
