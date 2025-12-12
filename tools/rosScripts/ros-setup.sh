#!/bin/bash

# 读取用户输入
# arg1: 提示信息
# arg2: 是否是敏感信息
# arg3: 是否是必填
# 结果通过环境变量input返回
# 如果输入为空则在循环中重新读取
function readInput(){
    if (($# < 3)); then
        echo "Usage: readInput <prompt> <sensitive:yes|no> <required:yes|no>"
        exit 1
    fi
    local prompt="$1"
    local sensitive="$2"
    local required="$3"
    while true; do
        if [ "$sensitive" = "yes" ]; then
            read -s -p "$prompt" input
            echo
        else
            read -p "$prompt" input
        fi
        if [ -n "$input" ] || [ "$required" = "no" ]; then
            export input="$input"
            break
        fi
    done
}

# 使用ipcalc计算出HostMin和HostMax
function calculateHostMinAndHostMax(){
    set -e

    # 检查ipcalc是否安装
    if ! command -v ipcalc &> /dev/null; then
        echo "ipcalc could not be found, please install it"
        exit 1
    fi

    # 验证子网格式
    if ! [[ "$subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Invalid subnet format: $subnet, please use format: a.b.c.d/e"
        exit 1
    fi

    local subnet="$1"
    hostMin=$(ipcalc -n $subnet | grep -i HostMin | awk '{print $2}')
    hostMax=$(ipcalc -n $subnet | grep -i HostMax | awk '{print $2}')
    netmask=$(ipcalc -n $subnet | grep -i Netmask | awk '{print $4}')
    dhcpNetwork=$(ipcalc -n $subnet | grep -i Network | awk '{print $2}')
    dhcpRange="$hostMin-$hostMax"
    adminIP="$hostMin/$netmask"
    gateway="$hostMin"

    # 验证结果
    if [ -z "$hostMin" ] || [ -z "$hostMax" ]; then
        echo "Failed to calculate network parameters"
        exit 1
    fi

    export hostMin="$hostMin"
    export hostMax="$hostMax"
    export netmask="$netmask"
    export adminIP="$adminIP"
    export gateway="$gateway"
    export dhcpNetwork="$dhcpNetwork"
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
  echo "/interface bridge add name=$brName"

  # 将lan口加入网桥
  for lan in ${lanNames[@]}; do
      echo "/interface bridge port add bridge=$brName interface=$lan"
  done
  # 给网桥设置ip地址
  echo "/ip address add address=$adminIP interface=$brName"
}

function setupDHCP(){
  # 增加ip地址池
  echo "/ip pool add name=$poolName ranges=$dhcpRange"
  # 设置dhcp server
  echo "/ip dhcp-server add address-pool=$poolName disabled=no interface=$brName lease-time=1d"
  # 设置dhcp server的dns 和网关，用于给内网的dhcp客户端分配ip时使用
  echo "/ip dhcp-server network add address=$dhcpNetwork dns-server=$dnsServer gateway=$gateway"
}

function setupPPPoE(){
  # 设置pppoe拨号
  echo "/interface pppoe-client add disabled=no interface=$wanName user=$pppoeUser password=$pppoePassword add-default-route=yes use-peer-dns=no name=$pppoeName"
  # 设置snat让内网设备可以上网
  echo "/ip firewall nat add chain=srcnat action=masquerade out-interface=$pppoeName"
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
  # 允许winbox端口
  echo "/ip firewall filter add action=accept chain=input comment=\"allow winbox port\" dst-port=${winboxPort} protocol=tcp"
  # 拒绝其他流量
  echo "/ip firewall filter add action=drop chain=input comment=\"drop other traffic\""
}

function setupUser(){
  # 新增用户
  echo "/user add name=$adminUser password=$adminUserPassword group=full"
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
    echo "/tool e-mail set from=$emailUser user=$emailUser password=$emailPassword server=$emailHost"
  else
    echo "# emailUser, emailPassword, emailHost is not set, skip email setup"
  fi
}

function setup(){
  pppoeUser="${pppoeUser}"
  pppoePassword="${pppoePassword}"
  
  emailUser="${emailUser}"
  emailPassword="${emailPassword}"
  emailHost="${emailHost:-smtp.163.com}"
  
  wanInterface="ether1"
  wanName="${wanInterface}.wan"
  # TODO: 根据实际的lan口数量设置
  lanInterfaces=("ether2" "ether3" "ether4" "ether5")
  #array
  lanNames=()
  
  sshPort="${sshPort:-20000}"
  wwwPort="${wwwPort:-8000}"
  winboxPort="${winboxPort:-8291}"
  
  adminUser="${adminUser:-userxx1}"
  adminUserPassword="${adminUserPassword}"
  if [ -z "$adminUserPassword" ]; then
      readInput "adminUserPassword: " "yes" "yes"
      adminUserPassword="$input"
  fi

  subnet="${subnet:-10.1.0.0/24}"
  calculateHostMinAndHostMax "$subnet"
  echo "hostMin: $hostMin"
  echo "hostMax: $hostMax"
  echo "netmask: $netmask"
  echo "adminIP: $adminIP"
  echo "gateway: $gateway"
  echo "dhcpNetwork: $dhcpNetwork"
  echo "dhcpRange: $dhcpRange"
  
  dnsServer="${dnsServer:-223.5.5.5,114.114.114.114}"
  
  brName="br-lan"
  poolName="dhcpPool1"
  pppoeName="pppoe-out1"
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
  
  
  echo "run '/system/reset-configuration no-defaults=yes skip-backup=yes' to reset routerOS"
  echo ":global setup do={"
  setupInterface
  setupDHCP
  setupPPPoE
  setupService
  setupEmail
  setupFirewall
  setupUser
  echo "}"
  echo "run \$setup in routerOS to apply" 

}

function help(){
    echo "Usage: <key1=val1> <key2=val2> ... $0 <setup|help>"
    echo "setup env vars:"
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
}

cmd=${1}
case $cmd in
    setup)
        setup
        ;;
    help)
        help
        ;;
    *)
        echo "Usage: $0 <setup|help>"
        exit 1
        ;;
esac












