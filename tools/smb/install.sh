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

search_dir="${this}"
shelllib_path=""
while [ "${search_dir}" != "/" ]; do
    if [ -r "${search_dir}/config/shell/shared/shelllib.sh" ]; then
        shelllib_path="${search_dir}/config/shell/shared/shelllib.sh"
        break
    fi
    search_dir="$(dirname "${search_dir}")"
done

if [ -r "${shelllib_path}" ]; then
    # shellcheck source=/dev/null
    source "${shelllib_path}"
elif [ -r /tmp/shelllib.sh ]; then
    # shellcheck source=/dev/null
    source /tmp/shelllib.sh
else
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    curl -fsSL -o /tmp/shelllib.sh "${shelllibURL}"
    if [ -r /tmp/shelllib.sh ]; then
        # shellcheck source=/dev/null
        source /tmp/shelllib.sh
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
