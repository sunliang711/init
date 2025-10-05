#!/bin/bash
pppoeUser=""
pppoePassword=""
emailUser=""
emailPassword=""
emailHost="smtp.163.com"
prefix="10.1.2"
wanInterface="ether1"
wanName="wan"
lanInterfaces=("ether2" "ether3" "ether4" "ether5")
#array
lanNames=()
sshPort=20000
wwwPort=8000
winboxPort=8291
adminUser="userxx1"
adminUserPassword=""
adminIP="$prefix.1/24"
gateway="$prefix.1"
dhcpNetwork="$prefix.0/24"
dhcpRange="$prefix.100-$prefix.199"
dnsServer="223.5.5.5,114.114.114.114"
brName="br-lan"
poolName="dhcpPool1"
pppoeName="pppoe-out1"
# generate routeros command line

# check
if [ -z "$pppoeUser" ] || [ -z "$pppoePassword" ]; then
    echo "pppoeUser or pppoePassword is not set"
    exit 1
fi

echo ":global setup do={"

# 设置wan口名称
echo "/interface ethernet set $wanInterface name=$wanName"
# 设置lan口名称
i=1
for lan in ${lanInterfaces[@]}; do
    echo "/interface ethernet set $lan name=lan$i"
    lanNames+=("lan$i")
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
# 增加ip地址池
echo "/ip pool add name=$poolName ranges=$dhcpRange"
# 设置dhcp server
echo "/ip dhcp-server add address-pool=$poolName disabled=no interface=$brName lease-time=1d"
# 设置dhcp server的dns 和网关，用于给内网的dhcp客户端分配ip时使用
echo "/ip dhcp-server network add address=$dhcpNetwork dns-server=$dnsServer gateway=$gateway"
# 设置pppoe拨号
echo "/interface pppoe-client add disabled=no interface=$wanName user=$pppoeUser password=$pppoePassword add-default-route=yes use-peer-dns=no name=$pppoeName"
# 设置snat让内网设备可以上网
echo "/ip firewall nat add chain=srcnat action=masquerade out-interface=$pppoeName"
# 设置dns server
echo "/ip dns set servers=$dnsServer allow-remote-requests=yes"
# 新增用户
echo "/user add name=$adminUser password=$adminUserPassword group=full"
# 禁用admin
echo "/user disable admin"
# 禁用用不到的服务：telnet ftp ap api-ssl
echo "/ip service disable telnet,ftp,api,api-ssl"
# 设置ssh 端口
echo "/ip service set ssh port=$sshPort"
# 设置 web端口
echo "/ip service set www port=$wwwPort"
# 设置email stmp信息
echo "/tool e-mail set from=$emailUser user=$emailUser password=$emailPassword server=$emailHost"
# 设置routerOS内置的ddns
echo "/ip cloud set ddns-enabled=yes ddns-update-interval=2m update-time=yes"
# 设置防火墙 address-list
echo "/ip firewall address-list add address=$prefix.1-$prefix.255 list=local"
# 设置防火墙
echo "/ip firewall filter add action=drop chain=input src-address-list=blacklist"
echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=2828 protocol=tcp reject-with=icmp-network-unreachable src-address-list=!upnplist"
echo "/ip firewall filter add action=reject chain=input comment=\"reject upnp\" dst-port=1900 protocol=udp src-address-list=!upnplist"
echo "/ip firewall filter add action=accept chain=input comment=\"established related\" connection-state=established,related"
echo "/ip firewall filter add action=accept chain=input comment=\"lan traffic\" src-address-list=local"
echo "/ip firewall filter add action=accept chain=input comment=\"icmp\" protocol=icmp"
echo "/ip firewall filter add action=accept chain=input comment=\"aliyun vm ssh\" dst-port=20000 protocol=tcp src-address=47.92.194.5"
echo "/ip firewall filter add action=accept chain=input comment=\"ssh port\" dst-port=20000 protocol=tcp src-address-list=local"
echo "/ip firewall filter add action=accept chain=input comment=\"www port\" dst-port=8000 protocol=tcp"
echo "/ip firewall filter add action=accept chain=input comment=\"winbox port\" dst-port=8291 protocol=tcp"
echo "/ip firewall filter add action=accept chain=input comment=\"ipsec\" dst-port=500,4500,1701 protocol=udp"
echo "/ip firewall filter add action=drop chain=input"

echo "}"











