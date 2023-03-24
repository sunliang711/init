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

if [ -r ${SHELLRC_ROOT}/shelllib ]; then
    source ${SHELLRC_ROOT}/shelllib
elif [ -r /tmp/shelllib ]; then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ]; then
        source /tmp/shelllib
    fi
fi

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

repo="https://github.com/sunliang711/init"
dest="$HOME/.local/apps/init"

install() {
    if [ "$this" != "$dest" ]; then
        echo "Please clone this to $dest"
        echo "Run git clone $repo $dest"
        exit 1
    fi

    # git
    (cd scripts && bash setGit.sh set)

    # tmux
    (cd scripts && bash tmux.sh install)

    # # nvim
    # (cd scripts && bash nvim.sh install)

    #shell
    (cd scripts && bash zsh.sh install)

    # fzf
    (cd scripts && bash installFzf.sh install)

}

uninstall() {
    (cd shell && bash installZsh.sh uninstall)

    (./tools/installFzf.sh uninstall)

    (cd tmux && bash tmux.sh uninstall)
}

# write your code above
###############################################################################

em() {
    $ed $0
}

function _help() {
    cd "${this}"
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    _help
    ;;
*)
    "$@"
    ;;
esac
