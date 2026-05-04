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
# shellcheck source=../bootstrap/lib/runtime.sh
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
###############################################################################
# write your code below (just define function[s])
# function with 'function' is hidden when run help, without 'function' is show
###############################################################################
# TODO
if [ -n "${LOCAL_APP_ROOT}" ];then
    prefix=${LOCAL_APP_ROOT}
else
    prefix=$HOME/.local/apps
fi
install(){
    if ! command -v logrotate >/dev/null 2>&1;then
        echo "Need logrotate installed!"
        exit 1
    fi
    local dest=${prefix}/logrotate
    local confDir=conf.d
    echo "logrotate dest: $dest"
    if [ ! -d "$dest/$confDir" ];then
        echo "mkdir $dest/$confDir..."
        mkdir -p $dest/$confDir
    fi
    cat<<EOF > ${dest}/logrotate.conf
#/tmp/testfile.log {
    #weekly | monthly | yearly
    # Note: size will override weekly | monthly | yearly
    #size 100k # | size 200M | size 1G

    #rotate 3
    #compress

    # Note: copytruncate conflics with create
    # and copytruncate works well with tail -f,create not works well with tail -f
    #create 0640 user group
    #copytruncate

    #su root root
#}
include ${dest}/$confDir
EOF
    cat<<EOF2
Tips:
    add settings to ${dest}/$confDir
    use logrotate -d ${dest}/logrotate.conf to check configuration file syntax
    add "/path/to/logrotate -s ${dest}/status ${dest}/logrotate.conf" to crontab(Linux) or launchd(MacOS)
EOF2

    case $(uname) in
        Darwin)
            cat<<EOF3>$home/Library/LaunchAgents/mylogrotate.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>mylogrotate</string>
    <key>WorkingDirectory</key>
    <string>/tmp</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which logrotate)</string>
        <string>-s</string>
        <string>${dest}/status</string>
        <string>${dest}/logrotate.conf</string>
    </array>
    <key>StandardOutPath</key>
    <string>/tmp/mylogrotate.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/mylogrotate.err</string>
    <key>RunAtLoad</key>
    <true/>

    <!--
        start job every 300 seconds
    -->
    <key>StartInterval</key>
    <integer>300</integer>

    <!--
        crontab like job schedular
    -->
    <!--
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>0</integer>
        <key>Day</key>
        <integer>0</integer>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Month</key>
        <integer>0</integer>
    </dict>

    -->
</dict>
</plist>
EOF3
            ;;
        Linux)
            (crontab -l 2>/dev/null;echo "*/10 * * * * $(which logrotate) -s ${dest}/status ${dest}/logrotate.conf")|crontab -
            ;;
    esac
}



###############################################################################
# write your code above
###############################################################################
function help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v runAsRoot
}

case "$1" in
     ""|-h|--help|help)
        help
        ;;
    *)
        "$@"
esac
