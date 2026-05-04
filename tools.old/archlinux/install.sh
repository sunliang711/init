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

# available VARs: user, home, rootID
# available functions:
#    _err(): print "$*" to stderror
#    _command_exists(): check command "$1" existence
#    _require_command(): exit when command "$1" not exist
#    _runAsRoot():
#                  -x (trace)
#                  -s (run in subshell)
#                  --nostdout (discard stdout)
#                  --nostderr (discard stderr)
#    _insert_path(): insert "$1" to PATH
#    _run():
#                  -x (trace)
#                  -s (run in subshell)
#                  --nostdout (discard stdout)
#                  --nostderr (discard stderr)
#    _ensureDir(): mkdir if $@ not exist
#    _root(): check if it is run as root
#    _require_root(): exit when not run as root
#    _linux(): check if it is on Linux
#    _require_linux(): exit when not on Linux
#    _wait(): wait $i seconds in script
#    _must_ok(): exit when $? not zero
#    _info(): info log
#    _infoln(): info log with \n
#    _error(): error log
#    _errorln(): error log with \n
#    _checkService(): check $1 exist in systemd


###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
install(){
    bash basic.sh install
    bash installNettools.sh install
    bash installYay.sh install
    bash installsnap.sh install
    bash installnode.sh install
    bash installPython.sh install
    bash installRust.sh install

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
