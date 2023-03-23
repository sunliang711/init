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
set() {
    ## check command
    _require_command git

    defaultEmail="sunliang711@163.com"
    defaultUser="sunliang711"
    if command -v whiptail >/dev/null 2>&1; then
        email="$(whiptail --title 'set git email' --inputbox 'enter email address' 5 40 ${defaultEmail} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
        name="$(whiptail --title 'set git name' --inputbox 'enter name ' 5 40 ${defaultUser} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
    else
        read -p "git user.email: (default: ${defaultEmail}) " email
        if [[ -z "$email" ]]; then
            email="${defaultEmail}"
            echo
        fi
        read -p "git user.name: (default: ${defaultUser}) " name
        if [[ -z "$name" ]]; then
            name="${defaultUser}"
            echo
        fi
    fi

    git config --global user.email "${email}"
    git config --global user.name "${name}"
    git config --global http.postBuffer 524288000
    git config --global push.default simple
    #save password for several minutes
    git config --global credential.helper cache
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global merge.tool vimdiff
    else
        echo "No vimdiff, so merge.tool is empty"
    fi
    # git config --global alias.tree "log --oneline --graph --decorate --all"
    git config --global alias.tree "log --pretty=format:\"%Cgreen%h %Cred%d %Cblue%s %x09%Creset[%cn %cd]\" --graph --date=iso"
    git config --global alias.list "config --global --list"
    if command -v nvim >/dev/null 2>&1; then
        git config --global core.editor nvim
    elif command -v vim >/dev/null 2>&1; then
        git config --global core.editor vim
    elif command -v vi >/dev/null 2>&1; then
        git config --global core.editor vi
    fi
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global diff.tool vimdiff
    fi
}

unset() {
    /bin/rm -rf ~/.gitconfig
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
