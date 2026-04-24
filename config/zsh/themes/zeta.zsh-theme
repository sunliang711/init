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
local grey=$fg_bold[black]

local black_bold=$fg_bold[black]
local red_bold=$fg_bold[red]
local blue_bold=$fg_bold[blue]
local green_bold=$fg_bold[green]
local yellow_bold=$fg_bold[yellow]
local magenta_bold=$fg_bold[magenta]
local cyan_bold=$fg_bold[cyan]
local white_bold=$fg_bold[white]

local highlight_bg=$bg[red]
local zeta_command_start=""
local zeta_last_took=""
local zeta_took_threshold=3

zmodload zsh/datetime 2>/dev/null

#{{vi indicator
vim_ins_mode="%{$fg[cyan]%}[I]%{$reset_color%}"
vim_cmd_mode="%{$fg[green]%}(N)%{$reset_color%}"
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

function get_git_short_sha_prompt {
    local git_sha="$(git_prompt_short_sha)"
    if [[ -n $git_sha ]]; then
        echo "$git_sha "
    fi
}

function get_git_summary_prompt {
    local git_status_output
    if [[ "${DISABLE_UNTRACKED_FILES_DIRTY:-}" == "true" ]]; then
        git_status_output="$(git status --porcelain=v2 --branch --untracked-files=no --ignore-submodules=all 2>/dev/null)"
    else
        git_status_output="$(git status --porcelain=v2 --branch --ignore-submodules=all 2>/dev/null)"
    fi

    if [[ -n $git_status_output ]]; then
        local branch=""
        local git_sha=""
        local git_status="%{$green_bold%}[✔]%{$reset_color%}"
        local has_changed=0
        local has_untracked=0
        local line

        for line in ${(f)git_status_output}; do
            case "$line" in
                \#\ branch.oid\ *)
                    git_sha="${line#"# branch.oid "}"
                    if [[ $git_sha == "(initial)" ]]; then
                        git_sha=""
                    else
                        git_sha="${git_sha[1,7]}"
                    fi
                    ;;
                \#\ branch.head\ *)
                    branch="${line#"# branch.head "}"
                    ;;
                \?*)
                    if [[ "${DISABLE_UNTRACKED_FILES_DIRTY:-}" != "true" ]]; then
                        has_untracked=1
                    fi
                    ;;
                [12u]*)
                    has_changed=1
                    ;;
            esac
        done

        if [[ $branch == "(detached)" ]]; then
            branch=$git_sha
        fi

        if [[ $has_changed -eq 1 && $has_untracked -eq 1 ]]; then
            git_status="%{$red_bold%}[✘%{$yellow_bold%}?%{$red_bold%}]%{$reset_color%}"
        elif [[ $has_changed -eq 1 ]]; then
            git_status="%{$red_bold%}[✘]%{$reset_color%}"
        elif [[ $has_untracked -eq 1 ]]; then
            git_status="%{$yellow_bold%}[?]%{$reset_color%}"
        fi

        if [[ -n $branch && -n $git_sha ]]; then
            echo "%{$green_bold%}⎇ $branch%{$reset_color%}  %{$yellow%}@$git_sha%{$reset_color%}  $git_status"
        fi
    fi
}

function get_time_stamp {
    echo "%*"
}

function zeta_record_command_start {
    zeta_command_start=$EPOCHSECONDS
}

function zeta_record_command_took {
    zeta_last_took=""

    if [[ -n $zeta_command_start && -n $EPOCHSECONDS ]]; then
        local elapsed=$(( EPOCHSECONDS - zeta_command_start ))
        zeta_command_start=""

        if [[ $elapsed -ge $zeta_took_threshold ]]; then
            if [[ $elapsed -ge 3600 ]]; then
                zeta_last_took="$(( elapsed / 3600 ))h $(( elapsed % 3600 / 60 ))m $(( elapsed % 60 ))s"
            elif [[ $elapsed -ge 60 ]]; then
                zeta_last_took="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
            else
                zeta_last_took="${elapsed}s"
            fi
        fi
    fi
}

function get_took_prompt {
    echo "$zeta_last_took"
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
        echo -n "%{$green%}[http]=>$http_proxy%{$reset_color%}"
    fi

    # git proxy
    local gp=$(git config --global http.proxy 2>/dev/null)
    if [ -n "$gp" ];then
        if [ -n "$http_proxy" ];then
            echo -n " "
        fi
        echo -n "%{$green%}[git]=>$gp%{$reset_color%}"
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

function get_prompt_body_prefix {
    echo "%{$blue_bold%}❯ %{$reset_color%}"
}

# Prompt: # GIT_BRANCH GIT_SHA GIT_STATUS
# # USER@MACHINE: DIRECTORY --- (TIME_STAMP)
# > command
function print_prompt_head {
    zeta_record_command_took
    local took_summary="$(get_took_prompt)"

    # 存在 proxy 时显示状态
    local proxy_summary="$(proxy_status)"
    if [[ -n $proxy_summary ]]; then
        proxy_prompt="$(get_prompt_body_prefix)$proxy_summary"
        print -rP "$proxy_prompt"
    fi

    # 单独一行显示 git branch、commit hash 和 dirty status
    local git_summary="$(get_git_summary_prompt)"
    if [[ -n $git_summary ]]; then
        git_sha_prompt="$(get_prompt_body_prefix)$git_summary"
        print -rP "$git_sha_prompt"
    fi

    # registry status too slow, disable it
    # registry_prompt="|-%{$green_bold%}# registry:%{$reset_color%}$(registry_status)"
    # print -rP "$registry_prompt"

    local left_prompt="$(get_prompt_body_prefix)\
%{$green_bold%}$(get_usr_name)\
%{$blue%}@\
%{$magenta_bold%}$(get_box_name): \
%{$magenta_bold%}$(get_current_dir)%{$reset_color%}"
    local right_prompt=""
    if [[ -n $took_summary ]]; then
        right_prompt+="%{$yellow%}⏱ $took_summary%{$reset_color%}  "
    fi
    right_prompt+="%{$blue%}($(get_time_stamp))%{$reset_color%} "
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
add-zsh-hook preexec zeta_record_command_start
add-zsh-hook precmd print_prompt_head
setopt prompt_subst

PROMPT='${vim_mode} $(get_prompt_indicator)'
RPROMPT=''
