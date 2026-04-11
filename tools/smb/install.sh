#!/bin/bash
_init_resolve_script_dir() {
    local source_path="${1:-${BASH_SOURCE[0]:-$0}}"
    local resolved_path=""

    if [ -n "${source_path}" ] && [ -e "${source_path}" ]; then
        resolved_path="$(readlink "${source_path}" 2>/dev/null || true)"
    fi

    if [ -z "${resolved_path}" ]; then
        resolved_path="${source_path}"
    elif printf '%s' "${resolved_path}" | grep -q '^/'; then
        :
    else
        resolved_path="$(dirname "${source_path}")/${resolved_path}"
    fi

    (
        cd "$(dirname "${resolved_path}")" && pwd
    )
}

_search_dir="$(_init_resolve_script_dir "${BASH_SOURCE[0]:-$0}")"
_runtime_path=""
while [ "${_search_dir}" != "/" ]; do
    if [ -r "${_search_dir}/bootstrap/lib/runtime.sh" ]; then
        _runtime_path="${_search_dir}/bootstrap/lib/runtime.sh"
        break
    fi
    _search_dir="$(dirname "${_search_dir}")"
done

if [ -z "${_runtime_path}" ]; then
    echo "failed to find bootstrap/lib/runtime.sh" >&2
    exit 1
fi

# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]:-$0}"
# shellcheck source=../../bootstrap/lib/runtime.sh
source "${_runtime_path}"
unset INIT_CALLER_SOURCE _runtime_path _search_dir


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
