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
# shellcheck source=../../bootstrap/lib/runtime.sh
source "${_runtime_path}"
unset INIT_CALLER_SOURCE _runtime_path _search_dir
###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'

# write your code above
###############################################################################
install(){
    _require_root

    if ! systemctl list-unit-files --no-pager | grep -q transmission ;then
        echo "update source.."
        _run apt update
        echo "install transmission-daemon.."
        _run apt install transmission-daemon -y
        _run apt install cifs-utils -y

    fi


    echo "stop transmission-daemon for config.."
    _run systemctl disable transmission-daemon
    _run systemctl stop transmission-daemon

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
    _require_root
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
