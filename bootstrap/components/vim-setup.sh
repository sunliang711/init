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
VIM_PACK_START="${INIT_TARGET_HOME}/.vim/pack/vendor/start"
NERDTREE_PATH="${VIM_PACK_START}/nerdtree"
FZF_PATH="${VIM_PACK_START}/fzf"
FZF_VIM_PATH="${VIM_PACK_START}/fzf.vim"
VIM_WHICH_KEY_PATH="${VIM_PACK_START}/vim-which-key"
VIM_GITGUTTER_PATH="${VIM_PACK_START}/vim-gitgutter"
VIM_FUGITIVE_PATH="${VIM_PACK_START}/vim-fugitive"
VIM_SURROUND_PATH="${VIM_PACK_START}/vim-surround"
VIM_COMMENTARY_PATH="${VIM_PACK_START}/vim-commentary"
AUTO_PAIRS_PATH="${VIM_PACK_START}/auto-pairs"
VIM_EASYMOTION_PATH="${VIM_PACK_START}/vim-easymotion"
LIGHTLINE_PATH="${VIM_PACK_START}/lightline.vim"
VIM_PLUGIN_LABELS=(
    nerdtree
    fzf
    fzf.vim
    vim-which-key
    vim-gitgutter
    vim-fugitive
    vim-surround
    vim-commentary
    auto-pairs
    vim-easymotion
    lightline.vim
)
VIM_PLUGIN_STATE_KEYS=(
    MANAGED_NERDTREE_DIR
    MANAGED_FZF_DIR
    MANAGED_FZF_VIM_DIR
    MANAGED_VIM_WHICH_KEY_DIR
    MANAGED_VIM_GITGUTTER_DIR
    MANAGED_VIM_FUGITIVE_DIR
    MANAGED_VIM_SURROUND_DIR
    MANAGED_VIM_COMMENTARY_DIR
    MANAGED_AUTO_PAIRS_DIR
    MANAGED_VIM_EASYMOTION_DIR
    MANAGED_LIGHTLINE_DIR
)
VIM_PLUGIN_PATHS=(
    "${NERDTREE_PATH}"
    "${FZF_PATH}"
    "${FZF_VIM_PATH}"
    "${VIM_WHICH_KEY_PATH}"
    "${VIM_GITGUTTER_PATH}"
    "${VIM_FUGITIVE_PATH}"
    "${VIM_SURROUND_PATH}"
    "${VIM_COMMENTARY_PATH}"
    "${AUTO_PAIRS_PATH}"
    "${VIM_EASYMOTION_PATH}"
    "${LIGHTLINE_PATH}"
)
VIM_PLUGIN_REPOS=(
    "https://github.com/preservim/nerdtree.git"
    "https://github.com/junegunn/fzf.git"
    "https://github.com/junegunn/fzf.vim.git"
    "https://github.com/liuchengxu/vim-which-key.git"
    "https://github.com/airblade/vim-gitgutter.git"
    "https://github.com/tpope/vim-fugitive.git"
    "https://github.com/tpope/vim-surround.git"
    "https://github.com/tpope/vim-commentary.git"
    "https://github.com/jiangmiao/auto-pairs.git"
    "https://github.com/easymotion/vim-easymotion.git"
    "https://github.com/itchyny/lightline.vim.git"
)
MANAGED_PLUGIN_DIRS=()

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

write_state() {
    local managed_user_vimrc="${1:-0}"
    local index
    local value
    local -a kv_pairs

    kv_pairs=(MANAGED_USER_VIMRC "${managed_user_vimrc}")
    for index in "${!VIM_PLUGIN_STATE_KEYS[@]}"; do
        value="${MANAGED_PLUGIN_DIRS[$index]:-0}"
        kv_pairs+=("${VIM_PLUGIN_STATE_KEYS[$index]}" "${value}")
    done

    kv_file_write "${STATE_FILE}" \
        "${kv_pairs[@]}"
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

# 读取插件托管状态，适用于安装前继承旧 state 以及卸载时判断删除范围。
read_managed_plugin_state() {
    local index

    MANAGED_PLUGIN_DIRS=()
    for index in "${!VIM_PLUGIN_STATE_KEYS[@]}"; do
        if [ "$(read_state "${VIM_PLUGIN_STATE_KEYS[$index]}")" = "1" ]; then
            MANAGED_PLUGIN_DIRS+=("1")
        else
            MANAGED_PLUGIN_DIRS+=("0")
        fi
    done
}

# 安装单个 Vim package 插件，已有同源仓库时跳过，非同源目录则保留用户内容。
install_vim_plugin() {
    local index="${1:?missing plugin index}"
    local label="${VIM_PLUGIN_LABELS[$index]}"
    local path="${VIM_PLUGIN_PATHS[$index]}"
    local repo="${VIM_PLUGIN_REPOS[$index]}"

    log INFO "Install ${label} plugin..."
    if [ ! -d "${path}" ]; then
        ensure_parent_dir "${path}"
        git clone "${repo}" "${path}"
        MANAGED_PLUGIN_DIRS[index]=1
    elif git_remote_matches "${path}" "${repo}"; then
        log INFO "${label} already exists at ${path}, skip clone"
    else
        log WARNING "${path} exists and is not the expected ${label} repo, skip clone"
    fi

    if [ -d "${path}/doc" ]; then
        vim -Nu NONE -n -es -c "helptags ${path}/doc" -c q
    fi
}

# 安装 Vim 插件清单，适用于用户级 Vim 配置初始化。
install_vim_plugins() {
    local index

    for index in "${!VIM_PLUGIN_LABELS[@]}"; do
        install_vim_plugin "${index}"
    done
}

# 删除由 init 管理的单个 Vim 插件目录，删除前必须确认 git remote 匹配。
remove_managed_vim_plugin() {
    local index="${1:?missing plugin index}"
    local key="${VIM_PLUGIN_STATE_KEYS[$index]}"
    local label="${VIM_PLUGIN_LABELS[$index]}"
    local path="${VIM_PLUGIN_PATHS[$index]}"
    local repo="${VIM_PLUGIN_REPOS[$index]}"

    if [ "$(read_state "${key}")" != "1" ] || [ ! -d "${path}" ]; then
        return 0
    fi

    if command_exists git && git_remote_matches "${path}" "${repo}"; then
        log INFO "Remove ${path}"
        /bin/rm -rf "${path}"
    elif ! command_exists git; then
        log WARNING "git not found, skip ${label} cleanup at ${path}"
    else
        log WARNING "${path} is not the expected ${label} repo, skip remove"
    fi
}

# 删除所有由 init 托管的 Vim 插件，并保留用户自行放置的插件目录。
remove_managed_vim_plugins() {
    local index

    for index in "${!VIM_PLUGIN_LABELS[@]}"; do
        remove_managed_vim_plugin "${index}"
    done
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
    local vimrc_needs_update=0

    [ "$(read_state MANAGED_USER_VIMRC)" = "1" ] && managed_user_vimrc=1
    read_managed_plugin_state

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

    install_vim_plugins

    write_state "${managed_user_vimrc}"
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

    remove_managed_vim_plugins

    remove_empty_dir "${VIM_PACK_START}"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim/pack/vendor"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim/pack"
    remove_empty_dir "${INIT_TARGET_HOME}/.vim"
    cleanup_state_file

    log SUCCESS "Done"
}

dispatch_cli show_help resolve_cli_handler "$@"
