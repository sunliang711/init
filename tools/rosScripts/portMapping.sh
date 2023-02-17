#!/bin/bash
source ./config

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
    IFS=$'|'
    read protocol dstPort toAddresses toPorts comment <<< "$mapping"
    protocol="$(trim $protocol)"
    dstPort="$(trim $dstPort)"
    toAddresses="$(trim $toAddresses)"
    toPorts="$(trim $toPorts)"
    comment="$(trim $comment)"

    if [ -z "$toPorts" ];then
        toPorts="$dstPort"
    fi

# dnat
# 如果toPort是多个端口(零散的多个端口用逗号分隔，连续端口用减号连接),则to-ports参数不能要，这时候端口只能一一映射，也就是20-21到内网的20-21，不能是20-21到80-81
# comment后面多加一个dyn-wan，是因为每当重新拨号后，wan口ip地址会变，因此给这条规则打个标记，然后在ros的定时脚本里根据comment找到所有dyn-wan的规则，然后给它们修改新的wan口
# 地址,也就是dst-address的值
echo "#$comment"
if echo "$toPorts" | grep -qE '(,|-)';then
cat<<EOF
/ip firewall nat add chain=dstnat action=dst-nat protocol=$protocol dst-address=[/ip address get [/ip address find interface=${wan}] address] dst-port=$dstPort to-addresses=$toAddresses comment="$comment $dynWanTag"

EOF
else
cat<<EOF
/ip firewall nat add chain=dstnat action=dst-nat protocol=$protocol dst-address=[/ip address get [/ip address find interface=${wan}] address] dst-port=$dstPort to-addresses=$toAddresses to-ports=$toPorts comment="$comment $dynWanTag"

EOF
fi

# 回流
cat<<EOF
/ip firewall nat add chain=srcnat action=masquerade protocol=$protocol out-interface=$bridge src-address=$subnet dst-address=$toAddresses dst-port=$toPorts comment="$comment $hairpinTag "

EOF
done
