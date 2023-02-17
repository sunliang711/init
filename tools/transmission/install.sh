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

_err(){
    echo "$*" >&2
}

_command_exists(){
    command -v "$@" > /dev/null 2>&1
}

rootID=0

_runAsRoot(){
    local trace=0
    local subshell=0
    local nostdout=0
    local nostderr=0

    local optNum=0
    for opt in ${@};do
        case "${opt}" in
            --trace|-x)
                trace=1
                ((optNum++))
                ;;
            --subshell|-s)
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
    if [ "${EUID}" -ne "${rootID}" ];then
        if _command_exists sudo; then
            bash_c='sudo -E bash -c'
        elif _command_exists su; then
            bash_c='su -c'
        else
            cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
            exit 1
        fi
    fi

    local fullcommand="${bash_c} ${cmd}"
    if [ $nostdout -eq 1 ];then
        cmd="${cmd} >/dev/null"
    fi
    if [ $nostderr -eq 1 ];then
        cmd="${cmd} 2>/dev/null"
    fi

    if [ $subshell -eq 1 ];then
        if [ $trace -eq 1 ];then
            (set -x; ${bash_c} "${cmd}")
        else
            (${bash_c} "${cmd}")
        fi
    else
        if [ $trace -eq 1 ];then
            set -x; ${bash_c} "${cmd}";set +x;
        else
            ${bash_c} "${cmd}"
        fi
    fi
}

function _insert_path(){
    if [ -z "$1" ];then
        return
    fi
    echo -e ${PATH//:/"\n"} | grep -c "^$1$" >/dev/null 2>&1 || export PATH=$1:$PATH
}

_run(){
    local trace=0
    local subshell=0
    local nostdout=0
    local nostderr=0

    local optNum=0
    for opt in ${@};do
        case "${opt}" in
            --trace|-x)
                trace=1
                ((optNum++))
                ;;
            --subshell|-s)
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
    if [ $nostdout -eq 1 ];then
        cmd="${cmd} >/dev/null"
    fi
    if [ $nostderr -eq 1 ];then
        cmd="${cmd} 2>/dev/null"
    fi

    if [ $subshell -eq 1 ];then
        if [ $trace -eq 1 ];then
            (set -x; ${bash_c} "${cmd}")
        else
            (${bash_c} "${cmd}")
        fi
    else
        if [ $trace -eq 1 ];then
            set -x; ${bash_c} "${cmd}";set +x;
        else
            ${bash_c} "${cmd}"
        fi
    fi
}

function _root(){
    if [ ${EUID} -ne ${rootID} ];then
        echo "Requires root privilege." 1>&2
        exit 1
    fi
}

function _linux(){
    if [ "$(uname)" != "Linux" ];then
        echo "Requires Linux" 1>&2
        exit 1
    fi
}

function _wait(){
    # secs=$((5 * 60))
    secs=${1:?'missing seconds'}

    while [ $secs -gt 0 ]; do
       echo -ne "$secs\033[0K\r"
       sleep 1
       : $((secs--))
    done
    echo -ne "\033[0K\r"
}

ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ];then
    ed=${editor}
fi
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'

# write your code above
###############################################################################
install(){
    _root

    if ! systemctl list-unit-files --no-pager | grep -q transmission ;then
        echo "update source.."
        _run -x "apt update"
        echo "install transmission-daemon.."
        _run -x "apt install transmission-daemon -y"
        _run -x "apt install cifs-utils -y"

    fi


    echo "stop transmission-daemon for config.."
    _run -x "systemctl disable transmission-daemon"
    _run -x "systemctl stop transmission-daemon"

    # # run transmission daemon as root
    # local transmissionDeamonServiceFile="$(systemctl status transmission-daemon | perl -ne 'print if /Loaded/' | awk -F'(' '{print $2}' | awk -F';' '{print $1}')"
    # echo "transmissionDeamonServiceFile: ${transmissionDeamonServiceFile}"
    # perl -i -p -e "s|User=.+|User=root|" ${transmissionDeamonServiceFile}

    local configFile='/etc/transmission-daemon/settings.json'
    echo "backup old config file.."
    if [ ! -e ${configFile}.orig ];then
        cp ${configFile} ${configFile}.orig
    fi

    echo -n "enter download-dir: "
    read downloadDir
    export completeDir=${downloadDir}/complete
    export incompleteDir=${downloadDir}/incomplete
    # downloadDir="$(cd ${downloadDir} && pwd)"
    if [ ! -d "${downloadDir}" ];then
        echo "downlad dir not exist,create it.."
        mkdir -p "${completeDir}"
        mkdir -p "${incompleteDir}"
    fi
    chown -R debian-transmission ${downloadDir}

    echo -n "enter rpc username: "
    read rpcUsername
    if [ -z "${rpcUsername}" ];then
        echo "rpc username empty"
        exit 1
    fi

    echo -n "enter rpc password: "
    read rpcPassword
    if [ -z "${rpcPassword}" ];then
        echo "rpc password empty"
        exit 1
    fi

    export rpcUsername
    export rpcPassword

    echo "configure settings.json.."

    # configFile=settings.json
    perl -i -p -e 's/("download-dir": )".+",/$1"$ENV{completeDir}",/' ${configFile}
    perl -i -p -e 's/("incomplete-dir-enabled": )[^,]+,/$1true,/' ${configFile}
    perl -i -p -e 's/("incomplete-dir": )".+",/$1"$ENV{incompleteDir}",/' ${configFile}


    perl -i -p -e 's/("rpc-username": )".+",/$1"$ENV{rpcUsername}",/' ${configFile}
    perl -i -p -e 's/("rpc-password": )".+",/$1"$ENV{rpcPassword}",/' ${configFile}

    perl -i -p -e 's/("rpc-whitelist-enabled": )[^,]+,/$1false,/' ${configFile}
    perl -i -p -e 's/("port-forwarding-enabled": )[^,]+,/$1true,/' ${configFile}


    rootDir=/usr/local/transmission
    if [ ! -d ${rootDir} ];then
        mkdir -p ${rootDir}
    fi
    # cp ${this}/transmission.sh ${rootDir}
    sed -e "s|<TransmissionDownloadDir>|${downloadDir}|g" ${this}/transmission.sh >${rootDir}/transmission.sh
    chmod +x ${rootDir}/transmission.sh

    sed -e "s|<ROOT>|${rootDir}|g" ${this}/transmission.service >/etc/systemd/system/transmission.service
    systemctl daemon-reload
    # systemctl enable --now transmission.service
}

uninstall(){
    _root
    echo "stop service.."
    systemctl stop transmission

    echo "remove service file.."
    rm -rf /etc/systemd/system/transmission.service
    rm -rf ${rootDir}

}

em(){
    $ed $0
}

function _help(){
    cd "${this}"
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
