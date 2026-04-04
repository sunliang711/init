#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/init-common.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE SCRIPT_DIR

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "check" "install" "uninstall")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    _show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

STATE_DIR="${INIT_TARGET_HOME}/.local/state/init"
STATE_FILE="${STATE_DIR}/fzf.state"
FZF_DIR="${INIT_TARGET_HOME}/.fzf"
FZF_REPO="https://github.com/junegunn/fzf.git"
FZF_ZSH_FILE="${INIT_TARGET_HOME}/.fzf.zsh"
FZF_BASH_FILE="${INIT_TARGET_HOME}/.fzf.bash"

_ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

_write_state() {
    _write_kv_file "${STATE_FILE}" \
        MANAGED_FZF_DIR "${1:-0}" \
        MANAGED_FZF_ZSH "${2:-0}" \
        MANAGED_FZF_BASH "${3:-0}"
}

_state_get() {
    local key="${1:?missing state key}"
    _kv_file_get "${STATE_FILE}" "${key}"
}

_cleanup_state_file() {
    [ -f "${STATE_FILE}" ] && /bin/rm -f "${STATE_FILE}"
}

check() {
    _require_commands git
}

install() {
    echo "Install fzf ..."
    local managed_fzf_dir=0
    local managed_fzf_zsh=0
    local managed_fzf_bash=0
    local fzf_zsh_existed=0
    local fzf_bash_existed=0
    local should_run_installer=0

    [ -e "${FZF_ZSH_FILE}" ] && fzf_zsh_existed=1
    [ -e "${FZF_BASH_FILE}" ] && fzf_bash_existed=1

    if [ ! -d "${FZF_DIR}" ]; then
        git clone --depth 1 "${FZF_REPO}" "${FZF_DIR}"
        managed_fzf_dir=1
        should_run_installer=1
    elif _git_remote_matches "${FZF_DIR}" "${FZF_REPO}"; then
        echo "${FZF_DIR} already exists, skip clone ..."
        if [ ! -e "${FZF_ZSH_FILE}" ] || [ ! -e "${FZF_BASH_FILE}" ]; then
            should_run_installer=1
        fi
    else
        echo "Warning: ${FZF_DIR} exists and is not the expected fzf repo, skip ..."
    fi

    if [ "${should_run_installer}" -eq 1 ] && [ -x "${FZF_DIR}/install" ]; then
        "${FZF_DIR}/install" --all
    fi

    if [ "${fzf_zsh_existed}" -eq 0 ] && [ -e "${FZF_ZSH_FILE}" ]; then
        managed_fzf_zsh=1
    fi
    if [ "${fzf_bash_existed}" -eq 0 ] && [ -e "${FZF_BASH_FILE}" ]; then
        managed_fzf_bash=1
    fi

    if [ "${managed_fzf_dir}" -eq 1 ] || [ "${managed_fzf_zsh}" -eq 1 ] || [ "${managed_fzf_bash}" -eq 1 ] || [ -f "${STATE_FILE}" ]; then
        [ "$(_state_get MANAGED_FZF_DIR)" = "1" ] && managed_fzf_dir=1
        [ "$(_state_get MANAGED_FZF_ZSH)" = "1" ] && managed_fzf_zsh=1
        [ "$(_state_get MANAGED_FZF_BASH)" = "1" ] && managed_fzf_bash=1
        _write_state "${managed_fzf_dir}" "${managed_fzf_zsh}" "${managed_fzf_bash}"
    fi

    #     if ! grep -q '#BEGIN FZF function' ~/.zshrc; then
    #         echo "add source $(pwd)/fzffunction.sh in .zshrc"
    #         cat <<EOF >>~/.zshrc
    # #BEGIN FZF function
    # source $(pwd)/fzffunctions.sh
    # #END FZF function
    # EOF
    #     fi
    #
    #     if ! grep -q '#BEGIN FZF function' ~/.bashrc; then
    #         echo "add source $(pwd)/fzffunction.sh in .bashrc"
    #         cat <<EOF2 >>~/.bashrc
    # #BEGIN FZF function
    # source $(pwd)/fzffunctions.sh
    # #END FZF function
    # EOF2
    #     fi

    if ! command -v fd >/dev/null 2>&1; then
        echo "Warning: install fd or fd-find for fzf"
    fi

    if ! command -v bat >/dev/null 2>&1; then
        echo "Recommend: install bat for fzf preview"
    fi
}

uninstall() {
    if [ "$(_state_get MANAGED_FZF_DIR)" = "1" ] && [ -d "${FZF_DIR}" ] && _git_remote_matches "${FZF_DIR}" "${FZF_REPO}"; then
        if [ -x "${FZF_DIR}/uninstall" ]; then
            "${FZF_DIR}/uninstall" >/dev/null 2>&1 || echo "Warning: ${FZF_DIR}/uninstall failed, continuing cleanup."
        fi
        /bin/rm -rf "${FZF_DIR}"
    fi

    if [ "$(_state_get MANAGED_FZF_ZSH)" = "1" ] && [ -e "${FZF_ZSH_FILE}" ]; then
        /bin/rm -f "${FZF_ZSH_FILE}"
    fi

    if [ "$(_state_get MANAGED_FZF_BASH)" = "1" ] && [ -e "${FZF_BASH_FILE}" ]; then
        /bin/rm -f "${FZF_BASH_FILE}"
    fi

    _cleanup_state_file
}

_dispatch_cli show_help _resolve_cli_handler "$@"
