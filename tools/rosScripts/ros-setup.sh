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
    local subnet="$1"
    hostMin=$(ipcalc -n $subnet | grep -i HostMin | awk '{print $2}')
    hostMax=$(ipcalc -n $subnet | grep -i HostMax | awk '{print $2}')
    netmask=$(ipcalc -n $subnet | grep -i Netmask | awk '{print $4}')
    dhcpNetwork=$(ipcalc -n $subnet | grep -i Network | awk '{print $2}')
    dhcpRange="$hostMin-$hostMax"
    adminIP="$hostMin/$netmask"
    gateway="$hostMin"

    export hostMin="$hostMin"
    export hostMax="$hostMax"
    export netmask="$netmask"
    export adminIP="$adminIP"
    export gateway="$gateway"
    export dhcpNetwork="$dhcpNetwork"
}

function setupInterface(){
  # 设置wan口名称
  echo "/interface ethernet set $wanInterface name=$wanName"
  # 设置lan口名称
  i=1
  for lan in ${lanInterfaces[@]}; do
      lanName="${lan}.lan"
      echo "/interface ethernet set $lan name=$lanName"
      lanNames+=("$lanName")
      i=$((i+1))
  done
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
  # 设置routerOS内置的ddns
  echo "/ip cloud set ddns-enabled=yes ddns-update-interval=2m update-time=yes"
  # 设置防火墙 address-list
  echo "/ip firewall address-list add address=${hostMin}-${hostMax} list=local"
  # 设置防火墙
  echo "/ip firewall filter add action=drop chain=input src-address-list=blacklist"
  echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=2828 protocol=tcp reject-with=icmp-network-unreachable src-address-list=!upnplist"
  echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=1900 protocol=udp src-address-list=!upnplist"
  echo "/ip firewall filter add action=accept chain=input comment=\"established related\" connection-state=established,related"
  echo "/ip firewall filter add action=accept chain=input comment=\"lan traffic\" src-address-list=local"
  echo "/ip firewall filter add action=accept chain=input comment=\"icmp\" protocol=icmp"
#   echo "/ip firewall filter add action=accept chain=input comment=\"aliyun vm ssh\" dst-port=${sshPort} protocol=tcp src-address=47.92.194.5"
  echo "/ip firewall filter add action=accept chain=input comment=\"ssh port\" dst-port=${sshPort} protocol=tcp src-address-list=local"
  echo "/ip firewall filter add action=accept chain=input comment=\"www port\" dst-port=${wwwPort} protocol=tcp"
  echo "/ip firewall filter add action=accept chain=input comment=\"winbox port\" dst-port=${winboxPort} protocol=tcp"
  echo "/ip firewall filter add action=drop chain=input"
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
  
  # adminIP="$prefix.1/24"
  # gateway="$prefix.1"
  # dhcpNetwork="$prefix.0/24"
  # dhcpRange="$prefix.100-$prefix.199"
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
  
  
  echo
  echo ":global setup do={"
  setupInterface
  setupDHCP
  setupPPPoE
  setupService
  setupEmail
  setupFirewall
  setupUser
  echo "}"

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












