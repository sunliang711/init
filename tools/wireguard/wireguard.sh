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

if [ -r ${SHELLRC_ROOT}/shellrc.d/shelllib ];then
    source ${SHELLRC_ROOT}/shellrc.d/shelllib
elif [ -r /tmp/shelllib ];then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ];then
        source /tmp/shelllib
    fi
fi


###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
wireguardRoot=/etc/wireguard
# clientDir=${wireguardRoot}/clients
dbFile=${wireguardRoot}/db
interfaceName=wg0

serverPubkey=server-publickey
serverPrikey=server-privatekey

source ${wireguardRoot}/settings


install(){
    set -e
    _root
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


    echo "-- generate override config file of wg-quick@ service"
    overrideFile=/etc/systemd/system/wg-quick@wg0.service.d/override.conf
    startPre="${this}/wireguard.sh _start_pre"
    startPost="${this}/wireguard.sh _start_post"
    sed -e "s|<start_pre>|${startPre}|" \
        -e "s|<start_post>|${startPost}|" \
            override.conf >/tmp/override.conf

    if [ ! -d /etc/systemd/system/wg-quick@wg0.service.d ];then
        mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
    fi
    mv /tmp/override.conf ${overrideFile}


    # enable service
    systemctl enable wg-quick@wg0

    _configServer

}

_initDb(){
    if [ -n "$dbFile" ];then
        echo "-- generate db file: ${dbFile}"
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
    if ! _root;then
        exit 1
    fi
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
    # 服务端 [Interface]
    gwInterface=$(ip -o -4 route show to default | awk '{print $5}')
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
}

addClient(){
    set -e
    _root

    if (($# < 2));then
        cat<<-EOF0
			usage: addClient <client_name> <host_number>
			
			<host_number>:          x of ${subnet}.x valid range: 2-254
		EOF0
        exit 1
    fi

    clientName=${1:?'missing client name'}
    hostNumber=${2:?'missing host number(x of ${subnet}.x)'}
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

    exportClient "${clientName}"
}

removeClient(){
    clientName=${1:?'missing client name'}
    _root
    set -e

    publickey=`sqlite3 ${dbFile} "select publickey from clients where name = '${clientName}';"`
    if [ -z "$publickey" ];then
        echo "no such client"
        exit 1
    fi

    sqlite3 "${dbFile}" "delete from clients where name = '${clientName}';"

    if _isRunning;then
        echo "-- wireguard is running, remove client from it"
        _liveRm "$publickey"
    fi

}

listClient(){
    records=`sqlite3 ${dbFile} "select name,hostnumber,publickey,enable from clients;"`
    if [ -z "${records}" ];then
        echo "no clients"
        exit 0
    fi

    local name hostnumber publickey enable

    printf "%-15s %-15s %-50s %-18s\n" "name" "ip" "publickey" "enable"
    for r in $records;do
        IFS=$'|'
        read name hostnumber publickey enable<<<"$r"

        printf "%-15s %-15s %-50s %-18s\n" "$name" "${subnet}.${hostnumber}" "${publickey}" "${enable}"
    done

}

start(){
    set -e
    _root
    echo "Note: when start or restart, Must close clash gateway service!!"
    systemctl start wg-quick@wg0
}

stop(){
    set -e
    _root
    systemctl stop wg-quick@wg0
}

exportClient(){
    clientName=${1:?'missing client name'}
    set -e
    _root

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
    wg
    echo
    echo "---- Client Info ----"
    listClient
}


statusf(){
    watch -n 1 $0 _status
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

em(){
    $ed $0
}

function _help(){
    cd "${this}"
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
