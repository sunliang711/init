#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_LIB="${SCRIPT_DIR}/../lib/runtime.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/runtime.sh
source "${RUNTIME_LIB}"
unset RUNTIME_LIB INIT_CALLER_SOURCE SCRIPT_DIR

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "check" "install" "uninstall" "reinstall")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

STATE_DIR="${INIT_TARGET_HOME}/.local/state/init"
STATE_FILE="${STATE_DIR}/tmux.state"
TMUX_CONF="${INIT_TARGET_HOME}/.tmux.conf"
TMUX_CONF_MARKER="# managed-by: init/tmux"
TPM_DIR="${INIT_TARGET_HOME}/.tmux/plugins/tpm"
TPM_REPO="https://github.com/tmux-plugins/tpm"

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

write_state() {
    kv_file_write "${STATE_FILE}" MANAGED_TPM_DIR "${1:-0}"
}

read_state() {
    local key="${1:?missing state key}"
    kv_file_get "${STATE_FILE}" "${key}"
}

cleanup_state_file() {
    [ -f "${STATE_FILE}" ] && /bin/rm -f "${STATE_FILE}"
}

remove_empty_dir() {
    local dir="${1:?missing dir}"
    [ -d "${dir}" ] || return 0
    [ -z "$(ls -A "${dir}" 2>/dev/null)" ] || return 0
    rmdir "${dir}"
}

_write_tmux_conf() {
    local tmp_conf

    tmp_conf="$(mktemp "${TMPDIR:-/tmp}/init-tmux.XXXXXX")" || return 1
    cat >"${tmp_conf}" <<EOF
${TMUX_CONF_MARKER}
##################################################
# enable vi mode
set-window-option -g mode-keys vi
set -g display-panes-time 10000 #10s

##################################################
# set croll history limit
set -g history-limit 8000

##################################################
# secape time: fix vim esc delay in tmux problem
set -s escape-time 0

##################################################
# split window
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

##################################################
# enable mouse
set -g mouse on

##################################################
# vi mode copy
# version 2.4+
 bind-key -T copy-mode-vi 'v' send -X begin-selection
 bind-key -T copy-mode-vi 'y' send -X copy-selection

# old version
# bind-key -t vi-copy v begin-selection;
# bind-key -t vi-copy y copy-selection;

# not work
# bind-key -T vi-copy 'v' begin-selection
# bind-key -T vi-copy 'y' copy-selection

##################################################
# select pane
bind k select-pane -U
bind j select-pane -D
bind h select-pane -L
bind l select-pane -R

##################################################
# resize pane
bind H resize-pane -L 4
bind L resize-pane -R 4
bind J resize-pane -D 4
bind K resize-pane -U 4

##################################################
# edit .tmux.conf
bind e new-window -n '~/.tmux.conf' "sh -c 'vim ~/.tmux.conf && tmux source ~/.tmux.conf'"

##################################################
# search text in current pane
bind-key / copy-mode \; send-key ?

##################################################
# reload config file
bind r source-file ~/.tmux.conf \; display "Reloaded tmux config!"

##################################################
# show options
bind o show-options -g


#### TMP Section
# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

#set -g @plugin 'wfxr/tmux-power'
set -g @plugin 'egel/tmux-gruvbox'
set -g @tmux-gruvbox 'light' # or 'dark'

# Other examples:
# set -g @plugin 'github_username/plugin_name'
# set -g @plugin 'github_username/plugin_name#branch'
# set -g @plugin 'git@github.com:user/plugin'
# set -g @plugin 'git@bitbucket.com:user/plugin'

# popup lazygit
bind-key g popup -E -w 95% -h 95% -d '#{pane_current_path}' lazygit

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
EOF

    if [ -f "${TMUX_CONF}" ] && ! grep -Fqx "${TMUX_CONF_MARKER}" "${TMUX_CONF}" && ! files_are_identical "${TMUX_CONF}" "${tmp_conf}"; then
        backup_path_if_needed "${TMUX_CONF}"
    fi

    if [ ! -f "${TMUX_CONF}" ] || ! files_are_identical "${TMUX_CONF}" "${tmp_conf}"; then
        ensure_parent_dir "${TMUX_CONF}"
        mv "${tmp_conf}" "${TMUX_CONF}"
    else
        /bin/rm -f "${tmp_conf}"
    fi
}


check() {
    require_commands git tmux
}

# 示例子命令函数
install() {
    check
    set -e
    local managed_tpm_dir=0

    [ "$(read_state MANAGED_TPM_DIR)" = "1" ] && managed_tpm_dir=1

    log INFO "Install tmux plugins..."
    if [ ! -d "${TPM_DIR}" ]; then
        ensure_parent_dir "${TPM_DIR}"
        git clone "${TPM_REPO}" "${TPM_DIR}"
        managed_tpm_dir=1
    elif git_remote_matches "${TPM_DIR}" "${TPM_REPO}"; then
        log INFO "TPM already exists at ${TPM_DIR}, skip clone"
    else
        log WARNING "${TPM_DIR} exists and is not the expected TPM repo, skip clone"
    fi

    _write_tmux_conf

    write_state "${managed_tpm_dir}"
    log SUCCESS "start tmux,then press <prefix> + I to install plugins"
}

uninstall() {
    log INFO "Uninstall tmux plugins..."

    if [ -f "${TMUX_CONF}" ] && grep -Fqx "${TMUX_CONF_MARKER}" "${TMUX_CONF}"; then
        log INFO "Remove ${TMUX_CONF}"
        /bin/rm -f "${TMUX_CONF}"
    fi

    if [ "$(read_state MANAGED_TPM_DIR)" = "1" ] && [ -d "${TPM_DIR}" ] && git_remote_matches "${TPM_DIR}" "${TPM_REPO}"; then
        log INFO "Remove ${TPM_DIR}"
        /bin/rm -rf "${TPM_DIR}"
    fi

    remove_empty_dir "${INIT_TARGET_HOME}/.tmux/plugins"
    remove_empty_dir "${INIT_TARGET_HOME}/.tmux"
    cleanup_state_file

    log SUCCESS "Uninstall tmux plugins success!"
}

reinstall() {
    uninstall
    install
}

dispatch_cli show_help resolve_cli_handler "$@"
