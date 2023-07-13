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
dbFile=${wireguardRoot}/db

install(){
    set -e
    _root
    cd ${this}
    # install soft
    # echo 'deb http://ftp.debian.org/debian buster-backports main' | tee /etc/apt/sources.list.d/buster-backports.list
    apt update
    apt install wireguard qrencode iptables sqlite3 -y
    # case $(uname -m) in
    #     x86_64)
    #         apt install linux-image-amd64 linux-headers-amd64 -y
    #         ;;
    #     aarch64)
    #         apt install linux-image-arm64 linux-headers-arm64 -y
    #         ;;
    # esac

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
    echo -n "Enter client DNS:"
    read clientDns
    # # install wireguard.sh
    # sed -e "s|<SERVER_PORT>|${serverPort}|g" wireguard.sh >/tmp/wireguard.sh && chmod +x /tmp/wireguard.sh
    # mv /tmp/wireguard.sh /usr/local/bin
    ln -sf ${this}/wireguard.sh /usr/local/bin

    if [ ! -d ${wireguardRoot} ];then
        mkdir -p ${wireguardRoot}
    fi
    cat<<-EOF>${wireguardRoot}/settings
	serverPubkey=server-publickey
	serverPrikey=server-privatekey
	serverConfigName=wg0
	serverConfigFile=\${serverConfigName}.conf
	MTU=1420
	subnet=10.10.10
	serverIp=\${subnet}.1/24
	serverPort=${serverPort}
	tableNo=10
    serverEndpoint=${endpoint}
    clientDns=${clientDns}
	EOF


    echo "-- generate override config file of wg-quick@ service"
    overrideFile=/etc/systemd/system/wg-quick@wg0.service.d/override.conf
    startPre="${this}/wireguard.sh _start_pre"
    sed -e "s|<start_pre>|${startPre}|" override.conf >/tmp/override.conf
    mv /tmp/override.conf ${overrideFile}

    _initDb

    # enable service
    systemctl enable wg-quick@wg0

    cat<<-EOF
	run wireguard.sh configServer to config for first time
	EOF

}

_initDb(){
    if [ -n "$dbFile" ];then
        echo "-- generate db file: ${dbFile}"
        sqlite3 "$dbFile" "create table client(name varchar unique,hostnumber int unique, privatekey varchar,publickey varchar,enable int);"
    fi
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
