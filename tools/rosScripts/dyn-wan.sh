#!/bin/bash
source ./config

#用法：把本脚本输出的内容保存到ros里成为一个script，然后新建scheduler来调度它
cat<<EOF
:global newIP [/ip address get [find interface=pppoe-out1] address]
:set newIP [:pick \$newIP 0 ([:len \$newIP]-3)]

:foreach item in=[/ip firewall nat find comment~"dynWanDNAT"] do={ \\
:local oldIP [/ip firewall nat get \$item dst-address]
:if (\$newIP!=\$oldIP) do={\\
:log warning message="dyn-wan: update DNAT's dst-address to \$newIP"
/ip firewall nat set \$item dst-address \$newIP
/tool e-mail send subject="[routerOS]ip of wan interface changed" to="vimisbug001@163.com" body="ip address of wan has changed from \$oldIP to \$newIP"
} else={\\
#:log info message="dyn-wan: ip not change"
}
}
EOF

//  新版本:


:local newIP [/ip address get [find interface=pppoe-out1] address]
:set newIP [:pick $newIP 0 ([:len $newIP]-3)]
:local changed false

:foreach item in=[/ip firewall nat find comment~"dynWanDNAT"] do={ \
    :local oldIP [/ip firewall nat get $item dst-address]
    :if ($newIP!=$oldIP) do={\
        :log warning message="dyn-wan: update DNAT's dst-address to $newIP"
        /ip firewall nat set $item dst-address $newIP
        :set changed true
    }
}

:if ($changed) do={\
    /tool e-mail send subject="[routerOS]ip of wan interface changed" to="vimisbug001@163.com" body="ip address of wan has changed from $oldIP to $newIP"
    /tool fetch http-method=post http-header-field="content-type:application/json" url="https://aliyun.eagle711.win:8080/updateRecord" http-data="{\"new_ip\":\"$newIP\",\"rr\":\"sh\",\"domain\":\"eagle711.win\",\"type\":\"A\",\"ttl\":\"600\",\"access_key\":\"LTAI4FuYbdoMiVSyeGEtkfFn\",\"access_secret\":\"7zaiVHqmKiYPovnsn1X2PUdQgN8PMg\"}"
} else={\
    #:log info message="dyn-wan: ip not change"
}
