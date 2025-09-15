# Zeta theme for oh-my-zsh
# Tested on Linux, Unix and Windows under ANSI colors.
# Copyright: Radmon, 2015

# Colors: black|red|blue|green|yellow|magenta|cyan|white
local black=$fg[black]
local red=$fg[red]
local blue=$fg[blue]
local green=$fg[green]
local yellow=$fg[yellow]
local magenta=$fg[magenta]
local cyan=$fg[cyan]
local white=$fg[white]

local black_bold=$fg_bold[black]
local red_bold=$fg_bold[red]
local blue_bold=$fg_bold[blue]
local green_bold=$fg_bold[green]
local yellow_bold=$fg_bold[yellow]
local magenta_bold=$fg_bold[magenta]
local cyan_bold=$fg_bold[cyan]
local white_bold=$fg_bold[white]

local highlight_bg=$bg[red]

#{{vi indicator
vim_ins_mode="%{$fg[cyan]%}[INS]%{$reset_color%}"
vim_cmd_mode="%{$fg[green]%}(CMD)%{$reset_color%}"
vim_mode=$vim_ins_mode

function zle-keymap-select {
  vim_mode="${${KEYMAP/vicmd/${vim_cmd_mode}}/(main|viins)/${vim_ins_mode}}"
  zle reset-prompt
}
zle -N zle-keymap-select

function zle-line-finish {
  vim_mode=$vim_ins_mode
}
zle -N zle-line-finish
function TRAPINT() {
  vim_mode=$vim_ins_mode
  return $(( 128 + $1 ))
}
#}}

local zeta='ζ'

# Machine name.
function get_box_name {
    if [ -f ~/.box-name ]; then
        cat ~/.box-name
    else
        echo $HOST
    fi
}

# User name.
function get_usr_name {
    local name="%n"
    if [[ "$USER" == 'root' ]]; then
        name="%{$highlight_bg%}%{$white_bold%}$name%{$reset_color%}"
    fi
    echo $name
}

# Directory info.
function get_current_dir {
    echo "${PWD/#$HOME/~}"
}

# Git info.
ZSH_THEME_GIT_PROMPT_PREFIX="%{$blue_bold%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$green_bold%} ✔ "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$red_bold%} ✘ "

# Git status.
ZSH_THEME_GIT_PROMPT_ADDED="%{$green_bold%}+"
ZSH_THEME_GIT_PROMPT_DELETED="%{$red_bold%}-"
ZSH_THEME_GIT_PROMPT_MODIFIED="%{$magenta_bold%}*"
ZSH_THEME_GIT_PROMPT_RENAMED="%{$blue_bold%}>"
ZSH_THEME_GIT_PROMPT_UNMERGED="%{$cyan_bold%}="
ZSH_THEME_GIT_PROMPT_UNTRACKED="%{$yellow_bold%}?"

# Git sha.
ZSH_THEME_GIT_PROMPT_SHA_BEFORE="[%{$yellow%}"
ZSH_THEME_GIT_PROMPT_SHA_AFTER="%{$reset_color%}]"

function get_git_prompt {
    if [[ -n $(git rev-parse --is-inside-work-tree 2>/dev/null) ]]; then
        local git_status="$(git_prompt_status)"
        if [[ -n $git_status ]]; then
            git_status="[$git_status%{$reset_color%}]"
        fi
        local git_prompt=" <$(git_prompt_info)$git_status>"
        echo $git_prompt
    fi
}

function get_time_stamp {
    echo "%*"
}

function get_space {
    local str=$1$2
    local zero='%([BSUbfksu]|([FB]|){*})'
    local len=${#${(S%%)str//$~zero/}}
    local size=$(( $COLUMNS - $len - 1 ))
    local space=""
    while [[ $size -gt 0 ]]; do
        space="$space "
        let size=$size-1
    done
    echo $space
}

function proxy_status(){
    # http proxy
    if [ -n "$http_proxy" ];then
        echo -n "%{$green%}[http]=>$http_proxy %{$reset_color%}"
    else
        echo -n "%{$grey%}[http]=>off %{$reset_color%}"
    fi

    # git proxy
    local gp=$(git config --global http.proxy 2>/dev/null)
    if [ -n "$gp" ];then
        echo -n "%{$green%} [git]=>$gp %{$reset_color%}"
    else
        echo -n "%{$grey%} [git]=>off %{$reset_color%}"
    fi
}

function registry_status(){
    # npm registry
    local defaultRegistry="registry.npmjs.org"
    local np=$(npm config get registry 2>/dev/null)
    if echo ${np} | grep -q "${defaultRegistry}";then
        echo -n "%{$grey%}[npm]=>off %{$reset_color%}"
    else
        echo -n "%{$green%}[npm]=>$np %{$reset_color%}"
    fi

    # pip registry
    local pipProxy="$(perl -lne 'print $1 if /^trusted-host\s*=\s*(.+)$/' ~/.pip/pip.conf 2>/dev/null)"
    if [ -n "${pipProxy}" ];then
        echo -n "%{$green%}[pip]=>${pipProxy} %{$reset_color%}"
    else
        echo -n "%{$grey%}[pip]=>off %{$reset_color%}"
    fi
}

# Prompt: # USER@MACHINE: DIRECTORY <BRANCH [STATUS]> --- (TIME_STAMP)
# > command
function print_prompt_head {
    # 再加一行，显示proxy状态
    proxy_prompt="╭─\
%{$green_bold%}# proxy:%{$reset_color%}$(proxy_status)\
"
    print -rP "$proxy_prompt"

    # registry status too slow, disable it
    # registry_prompt="|-%{$green_bold%}# registry:%{$reset_color%}$(registry_status)"
    # print -rP "$registry_prompt"

    local left_prompt="╰─\
%{$blue%}# \
%{$green_bold%}$(get_usr_name)\
%{$blue%}@\
%{$magenta_bold%}$(get_box_name): \
%{$magenta_bold%}$(get_current_dir)%{$reset_color%}\
$(get_git_prompt)"
    local right_prompt="%{$blue%}($(get_time_stamp))%{$reset_color%} "
    print -rP "$left_prompt$(get_space $left_prompt $right_prompt)$right_prompt"

}

function get_prompt_indicator {
    if [[ $? -eq 0 ]]; then
        echo "%{$green_bold%}$zeta %{$reset_color%}"
    else
        echo "%{$red_bold%}$zeta %{$reset_color%}"
    fi
}

autoload -U add-zsh-hook
add-zsh-hook precmd print_prompt_head
setopt prompt_subst

PROMPT='${vim_mode} $(get_prompt_indicator)'
RPROMPT='$(git_prompt_short_sha) '
