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
_start_pre(){
    echo "enter _start_pre .."
    if ! dpkg -L cifs-utils >/dev/null 2>&1;then
        echo "install cifs-utils.."
        sudo apt install -y cifs-utils || { echo "install cifs-utils failed"; exit 1; }
    fi

    if ! mount | grep -q '<smb_ip>/<smb_name> on';then
        sudo mount -t cifs //<smb_ip>/<smb_name> "<mount_dir>" -o user=<smb_user>,pass=<smb_pass>,uid=$(id -u <smb_as_user>),gid=$(id -g <smb_as_user>) || { echo "mount smb failed"; exit 1; }
    fi

    echo "leave _start_pre .."
}

start(){
    echo "enter start.."
    <start>

}

stop(){
    if mount | grep -q '<smb_ip>/<smb_name> on';then
        echo "umount <mount_dir>"
        sudo umount <mount_dir>
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
