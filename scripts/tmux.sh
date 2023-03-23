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
install() {
    _require_command tmux
    set -xe
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm >/dev/null
    cat <<EOF >$home/.tmux.conf
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

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
EOF

    echo "start tmux,then press <prefix> + I to install plugins"

}

uninstall() {
    /bin/rm -rf $home/.tmux.conf
    /bin/rm -rf $home/.tmux
}

reinstall() {
    uninstall
    install
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
