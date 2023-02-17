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
set(){
    # get outgoing interface
    local interface=`ip r get 223.5.5.5 |grep 'dev'|awk '{print $5}'`
    echo "interface is: ${interface}"
    read -p "enter ip address: (format: 10.1.2.3/24) " ip
    read -p "enter gateway: (format: 10.1.1.1) " gateway
    read -p "enter dns: (format: 223.5.5.5,10.1.1.1) " dns

    cat<<EOF
The following is config file content,copy it to /etc/netplan/xxx.yaml file,then run netplan apply
network:
  version: 2
  renderer: networkd
  ethernets:
    ${interface}:
      dhcp4: no
      addresses:
        - ${ip}
      gateway4: ${gateway}
      nameservers:
          addresses: [${dns}]
EOF

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
