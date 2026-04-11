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
