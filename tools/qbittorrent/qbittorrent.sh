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
_start_pre(){
    local smb_share="//<smb_ip>/<smb_name>"
    local mount_dir="<mount_dir>"
    local smb_user="<smb_user>"
    local smb_pass="<smb_pass>"
    local smb_as_user="<smb_as_user>"

    echo "enter _start_pre .."
    if ! dpkg -L cifs-utils >/dev/null 2>&1;then
        echo "install cifs-utils.."
        sudo apt install -y cifs-utils || { echo "install cifs-utils failed"; exit 1; }
    fi

    if ! mount | grep -q "${smb_share#//} on";then
        sudo mount -t cifs "${smb_share}" "${mount_dir}" -o "user=${smb_user},pass=${smb_pass},uid=$(id -u "${smb_as_user}"),gid=$(id -g "${smb_as_user}")" || { echo "mount smb failed"; exit 1; }
    fi

    echo "leave _start_pre .."
}

start(){
    echo "enter start.."
    : # TODO: add the qbittorrent start command for this host

}

stop(){
    local smb_share="//<smb_ip>/<smb_name>"
    local mount_dir="<mount_dir>"

    if mount | grep -q "${smb_share#//} on";then
        echo "umount ${mount_dir}"
        sudo umount "${mount_dir}"
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
