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

ZSH=${ZSH:-${HOME}/.oh-my-zsh}
ZSH_CUSTOM=${ZSH_CUSTOM:-${ZSH}/custom}
install() {
    export SHELLRC_ROOT=${HOME}/.local/apps/init/shellConfigs
    _require_command git curl zsh

    if [ ! -e "$HOME/.editrc" ] || ! grep -q 'bind -v' "$HOME/.editrc"; then
        echo 'bind -v' >>"$HOME/.editrc"
    fi
    if [ ! -e "$HOME"/.inputrc ] || ! grep -q 'set editing-mode vi' "$HOME/.inputrc"; then
        echo 'set editing-mode vi' >>"$HOME/.inputrc"
    fi

    # install omz
    (
        cd /tmp
        local installer="omzInstaller-$(date +%s).sh"
        curl -fsSL -o ${installer} https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh
        RUNZSH=no bash ${installer}
    )

    ln -sf ${this}/zshrc ~/.zshrc || {
        echo "Please fork the repo first"
        exit 1
    }

    # omz plugins
    # zsh-autosuggestions
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions
    # zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting

    # custom theme
    ln -svf ${this}/*.zsh-theme "${ZSH_CUSTOM}/themes"

    # soft link sshconfig
    [ ! -d ~/.ssh ] && mkdir ~/.ssh
    ln -svf ${this}/sshconfig $HOME/.ssh/config
}

uninstall() {
    cp ~/.zshrc{,.old}
    _rm ~/.zshrc
    _rm ${ZSH}
    _rm ${ZSH_CUSTOM}
    _rm ~/.zsh-syntax-highlighting
    _rm ~/.fzf
    _rm ~/.fzf.zsh
    _rm ~/.fzf.bash
    _rm ~/.ssh/config
    _rm ~/.editrc
    _rm ~/.inputrc
}

_rm() {
    local target=${1}
    [ -e ${target} ] && /bin/rm -rf ${target}
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
