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

# eg: 10.1.1.10/download
src=
# eg: /path/to/download
dest=
# eg: smb suer
user=
# eg: smb password
password=
# eg: 1001 or $(id -u <USER>)
uid=
# eg: 1001 or $(id -g <GROUP>)
gid=

mount(){
    [ -z "${src}" ] && { echo "need src"; return 1; }
    [ -z "${dest}" ] && { echo "need dest"; return 1; }
    [ -z "${user}" ] && { echo "need smb user"; return 1; }
    [ -z "${password}" ] && { echo "need smb password"; return 1; }
    [ -z "${uid}" ] && { echo "need uid"; return 1; }
    [ -z "${gid}" ] && { echo "need gid"; return 1; }
    echo "mount $src -> ${dest}.."

    /usr/bin/mount -t cifs "//${src}" "${dest}" -o user=${user},pass=${password},uid=${uid},gid=${gid}
}

umount(){
    /usr/bin/umount "${dest}"
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
