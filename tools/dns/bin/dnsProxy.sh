#!/bin/bash
_init_resolve_script_dir() {
    local source_path="${1:-${BASH_SOURCE[0]:-$0}}"
    local resolved_path=""

    if [ -n "${source_path}" ] && [ -e "${source_path}" ]; then
        resolved_path="$(readlink "${source_path}" 2>/dev/null || true)"
    fi

    if [ -z "${resolved_path}" ]; then
        resolved_path="${source_path}"
    elif printf '%s' "${resolved_path}" | grep -q '^/'; then
        :
    else
        resolved_path="$(dirname "${source_path}")/${resolved_path}"
    fi

    (
        cd "$(dirname "${resolved_path}")" && pwd
    )
}

_search_dir="$(_init_resolve_script_dir "${BASH_SOURCE[0]:-$0}")"
_runtime_path=""
while [ "${_search_dir}" != "/" ]; do
    if [ -r "${_search_dir}/bootstrap/lib/runtime.sh" ]; then
        _runtime_path="${_search_dir}/bootstrap/lib/runtime.sh"
        break
    fi
    _search_dir="$(dirname "${_search_dir}")"
done

if [ -z "${_runtime_path}" ]; then
    echo "failed to find bootstrap/lib/runtime.sh" >&2
    exit 1
fi

# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]:-$0}"
# shellcheck source=../../../bootstrap/lib/runtime.sh
source "${_runtime_path}"
unset INIT_CALLER_SOURCE _runtime_path _search_dir


# available VARs: user, home, rootID
# available color vars: RED GREEN YELLOW BLUE CYAN BOLD NORMAL
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

###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
function _parseOptions() {
    if [ $(uname) != "Linux" ]; then
        echo "getopt only on Linux"
        exit 1
    fi

    options=$(getopt -o dv --long debug --long name: -- "$@")
    [ $? -eq 0 ] || {
        echo "Incorrect option provided"
        exit 1
    }
    eval set -- "$options"
    while true; do
        case "$1" in
        -v)
            VERBOSE=1
            ;;
        -d)
            DEBUG=1
            ;;
        --debug)
            DEBUG=1
            ;;
        --name)
            shift # The arg is next in position args
            NAME=$1
            ;;
        --)
            shift
            break
            ;;
        esac
        shift
    done
}

_example() {
    _parseOptions "$0" "$@"
    # TODO
}
# env var read from env file
_start() {
    set -x
    otherFlags="${verbose}"
    if [ -n "${proxy}" ]; then
        otherFlags="${otherFlags} -t ${proxy}"
    fi

    runAsUser=${runAsUser:-"nobody"}
    runAsGroup=${runAsGroup:-"nogroup"}

    /usr/local/bin/https_dns_proxy -a "${listenAddr}" -p "${listenPort}" -u "${runAsUser}" -g "${runAsGroup}" -r "${resolver}" -b "${bootstrapDns}" ${otherFlags}
}

start() {
    startf
    startb
}

stop() {
    stopf
    stopb
}

restart() {
    stop
    start
}

logf() {
    sudo journalctl -u dnsmasq -f

}

logb() {
    sudo journalctl -u https_dns_proxy -f
}

startf() {
    { set -x; } >/dev/null
    # load env to get proxyPort
    source ${this}/../env
    if [ -z "proxyPort" ]; then
        echo "no proxyPort found from env file,exit!"
        exit 1
    fi
    sudo sed -i -e "s|server=127.0.0.1.*|server=127.0.0.1#${listenPort}|" /etc/dnsmasq.conf

    sudo systemctl start dnsmasq
}

startb() {
    { set -x; } >/dev/null
    sudo systemctl start https_dns_proxy
}

stopf() {
    { set -x; } >/dev/null
    sudo systemctl stop dnsmasq
}

stopb() {
    { set -x; } >/dev/null
    sudo systemctl stop https_dns_proxy
}

restartf() {
    stopf
    startf
}

restartb() {
    stopb
    startb
}

configf() {
    sudo vi /etc/dnsmasq.conf
}

configb() {
    vi ${this}/../env
}

updateConf() {
    upstreamDns="${1}"
    set -ex
    cd /tmp && curl -s -LO https://anti-ad.net/anti-ad-for-dnsmasq.conf && curl -s -LO https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf
    sudo cp anti-ad-for-dnsmasq.conf /etc/dnsmasq.d >/dev/null
    if [ -n "${upstreamDns}" ]; then
        sed -i "s|114.114.114.114|${upstreamDns}|" accelerated-domains.china.conf
    fi
    sudo cp accelerated-domains.china.conf /etc/dnsmasq.d >/dev/null

}

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
