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
dest=/usr/local/bin

install(){
    if ! command -v mount.cifs >/dev/null 2>&1;then
        echo "need cifs package (eg: apt install cifs-utils)"
        return 1
    fi

    [ ! -d ${dest} ] || mkdir -p ${dest}

    sudo cp ${this}/mount-smb.sh ${dest}
    local start="${dest}/mount-smb.sh mount"
    local stop="${dest}/mount-smb.sh umount"
    local user=root

    sed -e "s|<START>|${start}|" \
        -e "s|<STOP>|${stop}|" \
        -e "s|<USER>|${user}|" \
        mount-smb.service > /tmp/mount-smb.service
    sudo mv /tmp/mount-smb.service /etc/systemd/system
    sudo systemctl daemon-reload
    sudo vi ${dest}/mount-smb.sh
    echo "run: sudo systemctl enable mount-smb to auto start"
}

uninstall(){
    sudo systemctl stop mount-smb
    sudo rm /etc/systemd/system/mount-smb.service
    sudo rm ${dest}/mount-smb.sh
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
