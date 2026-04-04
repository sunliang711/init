#!/bin/bash

COMMON_LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/init-common.sh"
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE

# 显示帮助信息
show_help() {
  echo "Usage: $0 [-l LOG_LEVEL] <command>"
  echo ""
  echo "Commands:"
  for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
  done
  echo ""
  echo "Options:"
  echo "  -l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)"
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "check" "install" "uninstall" "reinstall")
STATE_DIR="${home}/.local/state/init"
STATE_FILE="${STATE_DIR}/tmux.state"
TMUX_CONF="${home}/.tmux.conf"
TMUX_CONF_MARKER="# managed-by: init/tmux"
TPM_DIR="${home}/.tmux/plugins/tpm"
TPM_REPO="https://github.com/tmux-plugins/tpm"

_ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

_write_state() {
    _ensure_state_dir
    cat >"${STATE_FILE}" <<EOF
MANAGED_TPM_DIR=${1:-0}
EOF
}

_state_get() {
    local key="${1:?missing state key}"
    [ -f "${STATE_FILE}" ] || return 1
    awk -F= -v key="${key}" '$1 == key { print $2 }' "${STATE_FILE}"
}

_cleanup_state_file() {
    [ -f "${STATE_FILE}" ] && /bin/rm -f "${STATE_FILE}"
}

_git_remote_matches() {
    local repo_dir="${1:?missing repo dir}"
    local expected_remote="${2:?missing expected remote}"
    local current_remote

    [ -d "${repo_dir}/.git" ] || return 1
    current_remote="$(git -C "${repo_dir}" config --get remote.origin.url 2>/dev/null)"
    [ "${current_remote}" = "${expected_remote}" ]
}

_remove_empty_dir() {
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

    if [ -f "${TMUX_CONF}" ] && ! grep -Fqx "${TMUX_CONF_MARKER}" "${TMUX_CONF}" && ! _files_match "${TMUX_CONF}" "${tmp_conf}"; then
        _backup_existing_path "${TMUX_CONF}"
    fi

    if [ ! -f "${TMUX_CONF}" ] || ! _files_match "${TMUX_CONF}" "${tmp_conf}"; then
        _ensure_parent_dir "${TMUX_CONF}"
        mv "${tmp_conf}" "${TMUX_CONF}"
    else
        /bin/rm -f "${tmp_conf}"
    fi
}


check() {
    errorCount=0

    _require_commands tmux
}

# 示例子命令函数
install() {
    check
    set -e
    local managed_tpm_dir=0

    [ "$(_state_get MANAGED_TPM_DIR)" = "1" ] && managed_tpm_dir=1

    log INFO "Install tmux plugins..."
    if [ ! -d "${TPM_DIR}" ]; then
        _ensure_parent_dir "${TPM_DIR}"
        git clone "${TPM_REPO}" "${TPM_DIR}"
        managed_tpm_dir=1
    elif _git_remote_matches "${TPM_DIR}" "${TPM_REPO}"; then
        log INFO "TPM already exists at ${TPM_DIR}, skip clone"
    else
        log WARNING "${TPM_DIR} exists and is not the expected TPM repo, skip clone"
    fi

    _write_tmux_conf

    _write_state "${managed_tpm_dir}"
    log SUCCESS "start tmux,then press <prefix> + I to install plugins"
}

uninstall() {
    log INFO "Uninstall tmux plugins..."

    if [ -f "${TMUX_CONF}" ] && grep -Fqx "${TMUX_CONF_MARKER}" "${TMUX_CONF}"; then
        log INFO "Remove ${TMUX_CONF}"
        /bin/rm -f "${TMUX_CONF}"
    fi

    if [ "$(_state_get MANAGED_TPM_DIR)" = "1" ] && [ -d "${TPM_DIR}" ] && _git_remote_matches "${TPM_DIR}" "${TPM_REPO}"; then
        log INFO "Remove ${TPM_DIR}"
        /bin/rm -rf "${TPM_DIR}"
    fi

    _remove_empty_dir "${home}/.tmux/plugins"
    _remove_empty_dir "${home}/.tmux"
    _cleanup_state_file

    log SUCCESS "Uninstall tmux plugins success!"
}

reinstall() {
    uninstall
    install
}

# ------------------------------------------------------------

# 解析命令行参数
while getopts ":l:" opt; do
  case ${opt} in
    l )
      set_log_level "$OPTARG"
      ;;
    \? )
      show_help
      exit 1
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      show_help
      exit 1
      ;;
  esac
done
# NOTE: 这里全局使用了OPTIND，如果在某个函数中也使用了getopts，那么在函数的开头需要重置OPTIND (OPTIND=1)
shift $((OPTIND -1))

# 解析子命令
command=$1
shift

if [[ -z "$command" ]]; then
  show_help
  exit 0
fi

case "$command" in
  help)
    show_help
    ;;
  *)
    ${command} "$@"
    ;;
esac
