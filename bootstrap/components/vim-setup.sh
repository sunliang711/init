#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_LIB="${SCRIPT_DIR}/../lib/runtime.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/runtime.sh
source "${RUNTIME_LIB}"
unset RUNTIME_LIB INIT_CALLER_SOURCE

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "check" "global" "user")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

GLOBAL_VIMRC_PATH=/etc/vim/vimrc.local
MACOS_GLOBAL_VIMRC_PATH=/usr/share/vim/vimrc
USER_VIMRC_PATH="${INIT_TARGET_HOME}/.vimrc"
REPO_VIMRC_PATH="${INIT_REPO_ROOT}/config/editors/vim/vimrc"
NERDTREE_PATH="${INIT_TARGET_HOME}/.vim/pack/vendor/start/nerdtree"
NERDTREE_REPO="https://github.com/preservim/nerdtree.git"

check() {
    require_commands git vim
}

global() {
    case "$(uname)" in
    Darwin)
        if [ ! -e "${MACOS_GLOBAL_VIMRC_PATH}.orig" ]; then
            _runAsRoot cp "${MACOS_GLOBAL_VIMRC_PATH}" "${MACOS_GLOBAL_VIMRC_PATH}.orig"
        fi
        log INFO "Copy vimrc to ${MACOS_GLOBAL_VIMRC_PATH}"
        _runAsRoot cp "${REPO_VIMRC_PATH}" "${MACOS_GLOBAL_VIMRC_PATH}"
        ;;
    Linux)
        log INFO "Copy vimrc to ${GLOBAL_VIMRC_PATH}"
        _runAsRoot cp "${REPO_VIMRC_PATH}" "${GLOBAL_VIMRC_PATH}"
        ;;
    esac
}

user() {
    log INFO "Copy vimrc to ${USER_VIMRC_PATH}"
    if [ -f "${USER_VIMRC_PATH}" ] && ! files_are_identical "${USER_VIMRC_PATH}" "${REPO_VIMRC_PATH}"; then
        backup_path_if_needed "${USER_VIMRC_PATH}"
    fi
    if [ ! -f "${USER_VIMRC_PATH}" ] || ! files_are_identical "${USER_VIMRC_PATH}" "${REPO_VIMRC_PATH}"; then
        cp "${REPO_VIMRC_PATH}" "${USER_VIMRC_PATH}"
    fi

    log INFO "install nerdtree plugin.."
    if [ ! -d "${NERDTREE_PATH}" ]; then
        ensure_parent_dir "${NERDTREE_PATH}"
        git clone "${NERDTREE_REPO}" "${NERDTREE_PATH}"
    elif git_remote_matches "${NERDTREE_PATH}" "${NERDTREE_REPO}"; then
        log INFO "nerdtree already exists at ${NERDTREE_PATH}, skip clone"
    else
        log WARNING "${NERDTREE_PATH} exists and is not the expected nerdtree repo, skip clone"
    fi

    if [ -d "${NERDTREE_PATH}/doc" ]; then
        vim -Nu NONE -n -es -c "helptags ${NERDTREE_PATH}/doc" -c q
    fi

    log SUCCESS "Done"
}


dispatch_cli show_help resolve_cli_handler "$@"
