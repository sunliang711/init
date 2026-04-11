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
cmd='qbittorrent-nox'
user='qbittorrent'
group='qbittorrent'
port=8083
dest=/usr/local/qbittorrent

install(){
    _require_root
    set -e
    if ! command -v "${cmd}" >/dev/null 2>&1;then
        echo "install ${cmd} .."
        apt update
        apt install -y "${cmd}" || { echo "install ${cmd} failed"; exit 1; }
        # link="https://source711.oss-cn-shanghai.aliyuncs.com/qbittorrent-nox/linux/x64/4.3.8/qbittorrent-nox"
        # (
        # cd /tmp
        # curl -LO "${link}" && mv qbittorrent-nox /usr/local/bin || { echo "download qbittorrent-nox failed"; exit 1; }
        # chmod +x /usr/local/bin/qbittorrent-nox
        # )
    fi

    if ! id -u ${user} >/dev/null 2>&1;then
        echo "create user: ${user} "
        useradd -m ${user} || { echo "create user failed"; exit 1; }
        # add ${user} to sudoer
        _addsudo ${user}
    fi

    if [ ! -d ${dest} ];then
        echo "create directory ${dest} .."
        mkdir -p ${dest}
    fi


    echo "webui port: ${port} "
    cmdStart="$(which ${cmd}) --webui-port=${port}"

    start_pre="${dest}/qbittorrent.sh _start_pre"
    start="${dest}/qbittorrent.sh start"
    stop="${dest}/qbittorrent.sh stop"

    echo -n "config smb mount? [y/n] "
    read -n 1 configSmb
    echo
    if [ "${configSmb}" == y ];then
        read -p "enter smb ip: " smbIp
        read -p "enter smb name: " smbName
        mountDir=/home/${user}/Downloads
        read -p "enter smb user: " smbUser
        stty -echo
        read -p "enter smb password: " smbPass
        stty echo
        echo
        asUser=${user}

    fi
    sed -e "s|<smb_ip>|${smbIp}|g" \
        -e "s|<smb_name>|${smbName}|g" \
        -e "s|<mount_dir>|${mountDir}|g" \
        -e "s|<smb_user>|${smbUser}|g" \
        -e "s|<smb_pass>|${smbPass}|g" \
        -e "s|<smb_as_user>|${user}|g" \
        -e "s|<start>|${cmdStart}|g" \
        ${this}/qbittorrent.sh >${dest}/qbittorrent.sh && chmod +x ${dest}/qbittorrent.sh


    sed -e "s|<START>|${start}|g" \
        -e "s|<START_PRE>|${start_pre}|g" \
        -e "s|<STOP>|${stop}|g" \
        -e "s|<USER>|${user}|g" ${this}/qbittorrent.service >/etc/systemd/system/qbittorrent.service

    systemctl daemon-reload

    # read -n 1 -p "start qbittorrent service [y/n] " startQbittorrent
    # echo
    # if [ ${startQbittorrent} = "y" ];then
    #     echo "start qbittorrent service .."
    #     systemctl start qbittorrent.service
    # fi

    echo "qtibtorrent config file at: $HOME/.config/qBittorrent/qBittorrent.conf"
    echo "qbittorrent script installed at: ${dest}"
    echo "issue command '${cmdStart}' manaually to accept notice"
    echo "default webui credentials: user: admin password: adminadmin"

}

_addsudo(){
    user=${1:?'missing user'}
    echo "add ${user} to sudoers"
    if ! command -v sudo >/dev/null 2>&1;then
        apt install sudo || { echo "install sudo failed."; exit 1; }
    fi
    cat>>/etc/sudoers.d/nopass<<-EOF
${user} ALL=(ALL:ALL) NOPASSWD:ALL
EOF

}

uninstall(){
    _require_root
    systemctl stop qbittorrent
    rm -rf ${dest}
    rm -rf /etc/systemd/system/qbittorrent.service
}

# write your code above
###############################################################################

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
