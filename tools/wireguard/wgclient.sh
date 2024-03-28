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

wireguardRoot=/etc/wireguard

install(){
    set -e
    _root
    apt update && apt install wireguard -y
    [ ! -d "${wireguardRoot}" ] && mkdir -p "${wireguardRoot}"
    systemctl enable systemd-resolved.service
    ln -s /usr/bin/resolvectl /usr/local/bin/resolvconf
}

# add server
add(){
    _root
    cd ${wireguardRoot}
    serverName=${1:?'missing server name'}
    $ed ${serverName}.conf

    systemctl daemon-reload
    systemctl enable --now wg-quick@${serverName}
}

# list server
list(){
    _root
    cd ${wireguardRoot}
    ls *.conf
}

# config server
config(){
    _root
    cd ${wireguardRoot}
    serverName=${1:?'missing server name'}
    file=${serverName}.conf
    before=`stat ${file} | grep Modify`
    $ed ${serverName}.conf
    after=`stat ${file} | grep Modify`
    if ! systemctl status wg-quick@${serverName} | grep -q inactive ;then
        if [ "${before}" != "${after}" ];then
            echo "restart wg-quick@${serverName}"
            systemctl restart wg-quick@${serverName}
        fi
    fi
}

rm(){
    _root
    set -x
    cd ${wireguardRoot}
    serverName=${1:?'missing server name'}
    systemctl stop wg-quick@${serverName}
    rm -rf ${serverName}.conf
    systemctl daemon-reload
}

start(){
    _root
    set -x
    serverName=${1:?'missing server name'}
    systemctl start wg-quick@${serverName}
}

stop(){
    _root
    set -x
    serverName=${1:?'missing server name'}
    systemctl stop wg-quick@${serverName}
}

restart(){
    set -x
    serverName=${1:?'missing server name'}
    systemctl restart wg-quick@${serverName}
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
