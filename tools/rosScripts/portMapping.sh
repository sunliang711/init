#!/bin/bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config
source "$script_dir/config"

trim(){
    if [ -n "${1}" ];then
        echo "${1}" | perl -lne 'print $1 if /^\s*(.+)\s*$/'
    fi
}

cat<<EOF
use the forllowing to remove all rules(numbers: from index len-1 to 1 ) except masquerade srcnat(number 0)

-------------------------------------------------------------------------------------------------------------------------------------------
:local len [:len [/ip firewall nat find]];:put \$len;for counter from=(\$len-1) to=1 step=-1 do={/ip firewall nat remove numbers=\$counter}
-------------------------------------------------------------------------------------------------------------------------------------------

EOF

for mapping in "${mappings[@]}";do
    IFS=$'|' read -r protocol dstPort toAddresses toPorts comment <<< "$mapping"
    protocol="$(trim "$protocol")"
    dstPort="$(trim "$dstPort")"
    toAddresses="$(trim "$toAddresses")"
    toPorts="$(trim "$toPorts")"
    comment="$(trim "$comment")"

    if [ -z "$toPorts" ];then
        toPorts="$dstPort"
    fi

# dnat
# 如果toPort是多个端口(零散的多个端口用逗号分隔，连续端口用减号连接),则to-ports参数不能要，这时候端口只能一一映射，也就是20-21到内网的20-21，不能是20-21到80-81
# DNAT 使用 address-list 匹配公网地址，公网 IP 变化时只需要维护 pub_ip 地址列表
echo "#$comment"
# 如果是多端口
if echo "$toPorts" | grep -qE '(,|-)';then
cat<<EOF
/ip firewall nat add chain=dstnat action=dst-nat protocol=$protocol dst-address-list=${addressList} dst-port=$dstPort to-addresses=$toAddresses comment="$comment"
/ip firewall nat add chain=srcnat action=masquerade protocol=$protocol src-address=$subnet out-interface=$bridge dst-address=$toAddresses dst-port=$dstPort comment="$comment $hairpinTag"

EOF
else
cat<<EOF
/ip firewall nat add chain=dstnat action=dst-nat protocol=$protocol dst-address-list=${addressList} dst-port=$dstPort to-addresses=$toAddresses to-ports=$toPorts comment="$comment"
/ip firewall nat add chain=srcnat action=masquerade protocol=$protocol src-address=$subnet out-interface=$bridge dst-address=$toAddresses dst-port=$toPorts comment="$comment $hairpinTag"

EOF
fi
done
