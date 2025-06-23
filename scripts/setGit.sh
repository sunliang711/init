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

export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

# export TERM=xterm-256color

# Use colors, but only if connected to a terminal, and that terminal
# supports them.
if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 5)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi

# error code
err_require_root=1
err_require_linux=2
err_require_command=3

_err() {
    echo "$*" >&2
}

_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_require_command() {
    if ! _command_exists "$1"; then
        echo "require command $1" 1>&2
        exit ${err_require_command}
    fi
}

_need_command() {
    if ! _command_exists "$1"; then
        echo "need command $1" 1>&2
        return 1
    fi
}

_need_command() {
    if ! _command_exists "$1"; then
        echo "need command $1" 1>&2
    fi
}

_require_commands() {
    errorNo=0
    for i in "$@";then
        if ! _command_exists "$i"; then
            echo "need command $i" 1>&2
            errorNo=$((errorNo+1))
        fi
    fi

    if ((errorNo > 0 ));then
        exit ${err_require_command}
    fi
}

rootID=0

_runAsRoot() {
    local trace=0
    local subshell=0
    local nostdout=0
    local nostderr=0

    local optNum=0
    for opt in ${@}; do
        case "${opt}" in
        --trace | -x)
            trace=1
            ((optNum++))
            ;;
        --subshell | -s)
            subshell=1
            ((optNum++))
            ;;
        --no-stdout)
            nostdout=1
            ((optNum++))
            ;;
        --no-stderr)
            nostderr=1
            ((optNum++))
            ;;
        *)
            break
            ;;
        esac
    done

    shift $(($optNum))
    local cmd="${*}"
    bash_c='bash -c'
    if [ "${EUID}" -ne "${rootID}" ]; then
        if _command_exists sudo; then
            bash_c='sudo -E bash -c'
        elif _command_exists su; then
            bash_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            return 1
        fi
    fi

    local fullcommand="${bash_c} ${cmd}"
    if [ $nostdout -eq 1 ]; then
        cmd="${cmd} >/dev/null"
    fi
    if [ $nostderr -eq 1 ]; then
        cmd="${cmd} 2>/dev/null"
    fi

    if [ $subshell -eq 1 ]; then
        if [ $trace -eq 1 ]; then
            (
                { set -x; } 2>/dev/null
                ${bash_c} "${cmd}"
            )
        else
            (${bash_c} "${cmd}")
        fi
    else
        if [ $trace -eq 1 ]; then
            { set -x; } 2>/dev/null
            ${bash_c} "${cmd}"
            local ret=$?
            { set +x; } 2>/dev/null
            return $ret
        else
            ${bash_c} "${cmd}"
        fi
    fi
}

function _insert_path() {
    if [ -z "$1" ]; then
        return
    fi
    echo -e ${PATH//:/"\n"} | grep -c "^$1$" >/dev/null 2>&1 || export PATH=$1:$PATH
}

_run() {
    local trace=0
    local subshell=0
    local nostdout=0
    local nostderr=0

    local optNum=0
    for opt in ${@}; do
        case "${opt}" in
        --trace | -x)
            trace=1
            ((optNum++))
            ;;
        --subshell | -s)
            subshell=1
            ((optNum++))
            ;;
        --no-stdout)
            nostdout=1
            ((optNum++))
            ;;
        --no-stderr)
            nostderr=1
            ((optNum++))
            ;;
        *)
            break
            ;;
        esac
    done

    shift $(($optNum))
    local cmd="${*}"
    bash_c='bash -c'

    local fullcommand="${bash_c} ${cmd}"
    if [ $nostdout -eq 1 ]; then
        cmd="${cmd} >/dev/null"
    fi
    if [ $nostderr -eq 1 ]; then
        cmd="${cmd} 2>/dev/null"
    fi

    if [ $subshell -eq 1 ]; then
        if [ $trace -eq 1 ]; then
            (
                { set -x; } 2>/dev/null
                ${bash_c} "${cmd}"
            )
        else
            (${bash_c} "${cmd}")
        fi
    else
        if [ $trace -eq 1 ]; then
            { set -x; } 2>/dev/null
            ${bash_c} "${cmd}"
            { local ret=$?; } 2>/dev/null
            { set +x; } 2>/dev/null
            return ${ret}
        else
            ${bash_c} "${cmd}"
        fi
    fi
}

function _ensureDir() {
    local dirs=$@
    for dir in ${dirs}; do
        if [ ! -d ${dir} ]; then
            mkdir -p ${dir} || {
                echo "create $dir failed!"
                exit 1
            }
        fi
    done
}

function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "Require root privilege." 1>&2
        return $err_require_root
    fi
}

function _require_root() {
    if ! _root; then
        exit $err_require_root
    fi
}

function _linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "Require Linux" 1>&2
        return $err_require_linux
    fi
}

function _require_linux() {
    if ! _linux; then
        exit $err_require_linux
    fi
}

function _wait() {
    # secs=$((5 * 60))
    secs=${1:?'missing seconds'}

    while [ $secs -gt 0 ]; do
        echo -ne "$secs\033[0K\r"
        sleep 1
        : $((secs--))
    done
    echo -ne "\033[0K\r"
}

_must_ok() {
    if [ $? != 0 ]; then
        echo "failed,exit.."
        exit $?
    fi
}

_info() {
    echo -n "$(date +%FT%T) ${1}"
}

_infoln() {
    echo "$(date +%FT%T) ${1}"
}

_error() {
    echo -n "$(date +%FT%T) ${RED}${1}${NORMAL}"
}

_errorln() {
    echo "$(date +%FT%T) ${RED}${1}${NORMAL}"
}

_checkService() {
    _info "find service ${1}.."
    if systemctl --all --no-pager | grep -q "${1}"; then
        echo "OK"
    else
        echo "Not found"
        return 1
    fi
}

ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ]; then
    ed=${editor}
fi

##### begin progress bar #####
# Usage:
# Source this script
# _enable_trapping <- optional to clean up properly if user presses ctrl-c
# _setup_scroll_area <- create empty progress bar
# _draw_progress_bar 10 <- advance progress bar
# _draw_progress_bar 40 <- advance progress bar
# _block_progress_bar 45 <- turns the progress bar yellow to indicate some action is requested from the user
# _draw_progress_bar 90 <- advance progress bar
# _destroy_scroll_area <- remove progress bar

# Constants
CODE_SAVE_CURSOR="\033[s"
CODE_RESTORE_CURSOR="\033[u"
CODE_CURSOR_IN_SCROLL_AREA="\033[1A"
COLOR_FG="\e[30m"
COLOR_BG="\e[42m"
COLOR_BG_BLOCKED="\e[43m"
RESTORE_FG="\e[39m"
RESTORE_BG="\e[49m"

# Variables
PROGRESS_BLOCKED="false"
TRAPPING_ENABLED="false"
TRAP_SET="false"

CURRENT_NR_LINES=0

_setup_scroll_area() {
    # If trapping is enabled, we will want to activate it whenever we setup the scroll area and remove it when we break the scroll area
    if [ "$TRAPPING_ENABLED" = "true" ]; then
        _trap_on_interrupt
    fi

    lines=$(tput lines)
    CURRENT_NR_LINES=$lines
    let lines=$lines-1
    # Scroll down a bit to avoid visual glitch when the screen area shrinks by one row
    echo -en "\n"

    # Save cursor
    echo -en "$CODE_SAVE_CURSOR"
    # Set scroll region (this will place the cursor in the top left)
    echo -en "\033[0;${lines}r"

    # Restore cursor but ensure its inside the scrolling area
    echo -en "$CODE_RESTORE_CURSOR"
    echo -en "$CODE_CURSOR_IN_SCROLL_AREA"

    # Start empty progress bar
    _draw_progress_bar 0
}

_destroy_scroll_area() {
    lines=$(tput lines)
    # Save cursor
    echo -en "$CODE_SAVE_CURSOR"
    # Set scroll region (this will place the cursor in the top left)
    echo -en "\033[0;${lines}r"

    # Restore cursor but ensure its inside the scrolling area
    echo -en "$CODE_RESTORE_CURSOR"
    echo -en "$CODE_CURSOR_IN_SCROLL_AREA"

    # We are done so clear the scroll bar
    _clear_progress_bar

    # Scroll down a bit to avoid visual glitch when the screen area grows by one row
    echo -en "\n\n"

    # Once the scroll area is cleared, we want to remove any trap previously set. Otherwise, ctrl+c will exit our shell
    if [ "$TRAP_SET" = "true" ]; then
        trap - INT
    fi
}

_draw_progress_bar() {
    sleep .1
    percentage=$1
    lines=$(tput lines)
    let lines=$lines

    # Check if the window has been resized. If so, reset the scroll area
    if [ "$lines" -ne "$CURRENT_NR_LINES" ]; then
        _setup_scroll_area
    fi

    # Save cursor
    echo -en "$CODE_SAVE_CURSOR"

    # Move cursor position to last row
    echo -en "\033[${lines};0f"

    # Clear progress bar
    tput el

    # Draw progress bar
    PROGRESS_BLOCKED="false"
    _print_bar_text $percentage

    # Restore cursor position
    echo -en "$CODE_RESTORE_CURSOR"
}

_block_progress_bar() {
    percentage=$1
    lines=$(tput lines)
    let lines=$lines
    # Save cursor
    echo -en "$CODE_SAVE_CURSOR"

    # Move cursor position to last row
    echo -en "\033[${lines};0f"

    # Clear progress bar
    tput el

    # Draw progress bar
    PROGRESS_BLOCKED="true"
    _print_bar_text $percentage

    # Restore cursor position
    echo -en "$CODE_RESTORE_CURSOR"
}

_clear_progress_bar() {
    lines=$(tput lines)
    let lines=$lines
    # Save cursor
    echo -en "$CODE_SAVE_CURSOR"

    # Move cursor position to last row
    echo -en "\033[${lines};0f"

    # clear progress bar
    tput el

    # Restore cursor position
    echo -en "$CODE_RESTORE_CURSOR"
}

_print_bar_text() {
    local percentage=$1
    local cols=$(tput cols)
    let bar_size=$cols-17

    local color="${COLOR_FG}${COLOR_BG}"
    if [ "$PROGRESS_BLOCKED" = "true" ]; then
        color="${COLOR_FG}${COLOR_BG_BLOCKED}"
    fi

    # Prepare progress bar
    let complete_size=($bar_size * $percentage)/100
    let remainder_size=$bar_size-$complete_size
    progress_bar=$(
        echo -ne "["
        echo -en "${color}"
        _printf_new "#" $complete_size
        echo -en "${RESTORE_FG}${RESTORE_BG}"
        _printf_new "." $remainder_size
        echo -ne "]"
    )

    # Print progress bar
    echo -ne " Progress ${percentage}% ${progress_bar}"
}

_enable_trapping() {
    TRAPPING_ENABLED="true"
}

_trap_on_interrupt() {
    # If this function is called, we setup an interrupt handler to cleanup the progress bar
    TRAP_SET="true"
    trap _cleanup_on_interrupt INT
}

_cleanup_on_interrupt() {
    _destroy_scroll_area
    exit
}

_printf_new() {
    str=$1
    num=$2
    v=$(printf "%-${num}s" "$str")
    echo -ne "${v// /$str}"
}

##### end progress bar #####

# vim: set ft=sh:

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
#                  --no-stdout (discard stdout)
#                  --no-stderr (discard stderr)
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
check() {
    _require_commands git
}

set() {
    check

    defaultEmail="sunliang711@163.com"
    defaultUser="sunliang711"
    if command -v whiptail >/dev/null 2>&1; then
        email="$(whiptail --title 'set git email' --inputbox 'enter email address' 5 40 ${defaultEmail} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
        name="$(whiptail --title 'set git name' --inputbox 'enter name ' 5 40 ${defaultUser} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
    else
        read -p "git user.email: (default: ${defaultEmail}) " email
        if [[ -z "$email" ]]; then
            email="${defaultEmail}"
            echo
        fi
        read -p "git user.name: (default: ${defaultUser}) " name
        if [[ -z "$name" ]]; then
            name="${defaultUser}"
            echo
        fi
    fi

    git config --global user.email "${email}"
    git config --global user.name "${name}"
    git config --global http.postBuffer 524288000
    git config --global push.default simple
    git config --global pull.rebase false
    #save password for several minutes
    git config --global credential.helper cache
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global merge.tool vimdiff
    else
        echo "No vimdiff, so merge.tool is empty"
    fi
    # git config --global alias.tree "log --oneline --graph --decorate --all"
    git config --global alias.tree "log --pretty=format:\"%Cgreen%h %Cred%d %Cblue%s %x09%Creset[%cn %cd]\" --graph --date=iso"
    git config --global alias.list "config --global --list"
    if command -v nvim >/dev/null 2>&1; then
        git config --global core.editor nvim
    elif command -v vim >/dev/null 2>&1; then
        git config --global core.editor vim
    elif command -v vi >/dev/null 2>&1; then
        git config --global core.editor vi
    fi
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global diff.tool vimdiff
    fi
}

unset() {
    /bin/rm -rf ~/.gitconfig
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
