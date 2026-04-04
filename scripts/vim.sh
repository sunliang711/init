#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/init-common.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "check" "global" "user")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    _show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

globalPath=/etc/vim/vimrc.local
macOSGlobalPath=/usr/share/vim/vimrc
userPath="${INIT_TARGET_HOME}/.vimrc"
sourceVimrc="${SCRIPT_DIR}/vimrc"
nerdtreePath="${INIT_TARGET_HOME}/.vim/pack/vendor/start/nerdtree"
nerdtreeRepo="https://github.com/preservim/nerdtree.git"

check() {
    _require_commands vim
}

global() {
    case "$(uname)" in
    Darwin)
        if [ ! -e "${macOSGlobalPath}.orig" ]; then
            _runAsRoot cp "${macOSGlobalPath}" "${macOSGlobalPath}.orig"
        fi
        log INFO "Copy vimrc to ${macOSGlobalPath}"
        _runAsRoot cp "${sourceVimrc}" "${macOSGlobalPath}"
        ;;
    Linux)
        log INFO "Copy vimrc to ${globalPath}"
        _runAsRoot cp "${sourceVimrc}" "${globalPath}"
        ;;
    esac
}

user() {
    log INFO "Copy vimrc to $userPath"
    if [ -f "${userPath}" ] && ! _files_match "${userPath}" "${sourceVimrc}" ; then
        _backup_existing_path "${userPath}"
    fi
    if [ ! -f "${userPath}" ] || ! _files_match "${userPath}" "${sourceVimrc}" ; then
        cp "${sourceVimrc}" "${userPath}"
    fi

    log INFO "install nerdtree plugin.."
    # requrie vim 8+
    if [ ! -d "${nerdtreePath}" ]; then
        _ensure_parent_dir "${nerdtreePath}"
        git clone "${nerdtreeRepo}" "${nerdtreePath}"
    elif _git_remote_matches "${nerdtreePath}" "${nerdtreeRepo}"; then
        log INFO "nerdtree already exists at ${nerdtreePath}, skip clone"
    else
        log WARNING "${nerdtreePath} exists and is not the expected nerdtree repo, skip clone"
    fi

    if [ -d "${nerdtreePath}/doc" ]; then
        vim -Nu NONE -n -es -c "helptags ${nerdtreePath}/doc" -c q
    fi

    log SUCCESS "Done"
}


_dispatch_cli show_help _resolve_cli_handler "$@"
