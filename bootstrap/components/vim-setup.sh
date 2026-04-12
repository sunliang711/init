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
COMMANDS=("help" "check" "global" "user" "uninstall")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

STATE_DIR="${INIT_TARGET_HOME}/.local/state/init"
STATE_FILE="${STATE_DIR}/vim.state"
GLOBAL_VIMRC_PATH=/etc/vim/vimrc.local
MACOS_GLOBAL_VIMRC_PATH=/usr/share/vim/vimrc
USER_VIMRC_PATH="${INIT_TARGET_HOME}/.vimrc"
REPO_VIMRC_PATH="${INIT_REPO_ROOT}/config/editors/vim/vimrc"
NERDTREE_PATH="${INIT_TARGET_HOME}/.vim/pack/vendor/start/nerdtree"
NERDTREE_REPO="https://github.com/preservim/nerdtree.git"

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

write_state() {
    kv_file_write "${STATE_FILE}" \
        MANAGED_USER_VIMRC "${1:-0}" \
        MANAGED_NERDTREE_DIR "${2:-0}"
}

read_state() {
    local key="${1:?missing state key}"
    kv_file_get "${STATE_FILE}" "${key}"
}

cleanup_state_file() {
    [ -f "${STATE_FILE}" ] || return 0
    /bin/rm -f "${STATE_FILE}"
}

remove_empty_dir() {
    local dir="${1:?missing dir}"
    [ -d "${dir}" ] || return 0
    [ -z "$(ls -A "${dir}" 2>/dev/null)" ] || return 0
    rmdir "${dir}"
}

check() {
    require_commands git vim
}

global() {
    set -euo pipefail
    require_command vim

    case "$(uname)" in
    Darwin)
        if [ ! -e "${MACOS_GLOBAL_VIMRC_PATH}.orig" ]; then
            _runAsRoot cp "${MACOS_GLOBAL_VIMRC_PATH}" "${MACOS_GLOBAL_VIMRC_PATH}.orig"
        fi
        log INFO "Copy vimrc to ${MACOS_GLOBAL_VIMRC_PATH}"
        _runAsRoot cp "${REPO_VIMRC_PATH}" "${MACOS_GLOBAL_VIMRC_PATH}"
        ;;
    Linux)
        if [ ! -e "${GLOBAL_VIMRC_PATH}.orig" ] && [ -e "${GLOBAL_VIMRC_PATH}" ]; then
            _runAsRoot cp "${GLOBAL_VIMRC_PATH}" "${GLOBAL_VIMRC_PATH}.orig"
        fi
        log INFO "Copy vimrc to ${GLOBAL_VIMRC_PATH}"
        _runAsRoot cp "${REPO_VIMRC_PATH}" "${GLOBAL_VIMRC_PATH}"
        ;;
    *)
        log FATAL "unsupported os: $(uname)"
        ;;
    esac
}

user() {
    set -euo pipefail
    check
    local managed_user_vimrc=0
    local managed_nerdtree_dir=0
    local vimrc_needs_update=0

    [ "$(read_state MANAGED_USER_VIMRC)" = "1" ] && managed_user_vimrc=1
    [ "$(read_state MANAGED_NERDTREE_DIR)" = "1" ] && managed_nerdtree_dir=1

    log INFO "Copy vimrc to ${USER_VIMRC_PATH}"
    if [ ! -f "${USER_VIMRC_PATH}" ] || ! files_are_identical "${USER_VIMRC_PATH}" "${REPO_VIMRC_PATH}"; then
        vimrc_needs_update=1
    fi
    if [ "${vimrc_needs_update}" -eq 1 ] && [ -f "${USER_VIMRC_PATH}" ]; then
        backup_path_if_needed "${USER_VIMRC_PATH}"
    fi
    if [ "${vimrc_needs_update}" -eq 1 ]; then
        cp "${REPO_VIMRC_PATH}" "${USER_VIMRC_PATH}"
        managed_user_vimrc=1
    fi

    log INFO "install nerdtree plugin.."
    if [ ! -d "${NERDTREE_PATH}" ]; then
        ensure_parent_dir "${NERDTREE_PATH}"
        git clone "${NERDTREE_REPO}" "${NERDTREE_PATH}"
        managed_nerdtree_dir=1
    elif git_remote_matches "${NERDTREE_PATH}" "${NERDTREE_REPO}"; then
        log INFO "nerdtree already exists at ${NERDTREE_PATH}, skip clone"
    else
        log WARNING "${NERDTREE_PATH} exists and is not the expected nerdtree repo, skip clone"
    fi

    if [ -d "${NERDTREE_PATH}/doc" ]; then
        vim -Nu NONE -n -es -c "helptags ${NERDTREE_PATH}/doc" -c q
    fi

    write_state "${managed_user_vimrc}" "${managed_nerdtree_dir}"
    log SUCCESS "Done"
}

uninstall() {
    set -euo pipefail

    log INFO "Uninstall vim config..."

    if [ "$(read_state MANAGED_USER_VIMRC)" = "1" ] && [ -f "${USER_VIMRC_PATH}" ]; then
        if files_are_identical "${USER_VIMRC_PATH}" "${REPO_VIMRC_PATH}"; then
            log INFO "Remove ${USER_VIMRC_PATH}"
            /bin/rm -f "${USER_VIMRC_PATH}"
        else
            log WARNING "${USER_VIMRC_PATH} has local changes, skip remove"
        fi
    fi

    if [ "$(read_state MANAGED_NERDTREE_DIR)" = "1" ] && [ -d "${NERDTREE_PATH}" ]; then
        if command_exists git && git_remote_matches "${NERDTREE_PATH}" "${NERDTREE_REPO}"; then
            log INFO "Remove ${NERDTREE_PATH}"
            /bin/rm -rf "${NERDTREE_PATH}"
        elif ! command_exists git; then
            log WARNING "git not found, skip nerdtree cleanup at ${NERDTREE_PATH}"
        else
            log WARNING "${NERDTREE_PATH} is not the expected nerdtree repo, skip remove"
        fi
    fi

    remove_empty_dir "${INIT_TARGET_HOME}/.vim/pack/vendor/start"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim/pack/vendor"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim/pack"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim"
    cleanup_state_file

    log SUCCESS "Done"
}


dispatch_cli show_help resolve_cli_handler "$@"
