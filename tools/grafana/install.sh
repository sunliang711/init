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
            set -x
            ${bash_c} "${cmd}"
            ret=$?
            set +x
            return ${ret}
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

_must_ok(){
    if [ $? != 0 ];then
        echo "failed,exit.."
        exit $?
    fi
}

_info(){
    echo -n "$(date +%FT%T) ${1}"
}

_infoln(){
    echo "$(date +%FT%T) ${1}"
}

_error(){
    echo -n "$(date +%FT%T) ${RED}${1}${NORMAL}"
}

_errorln(){
    echo "$(date +%FT%T) ${RED}${1}${NORMAL}"
}

_checkService(){
    _info "find service ${1}.."
    if systemctl --all --no-pager | grep -q "${1}";then
        echo "OK"
    else
        echo "Not found"
        return 1
    fi
}

# ref: https://foxi.buduanwang.vip/virtualization/pve/615.html/

# install grafana
igrafana(){
    _root

    if _checkService grafana;then
        _infoln "already exist grafana,exit.."
        exit 0
    fi

    local sourceDest=/etc/apt/sources.list.d
    _infoln "add grafana source file to ${sourceDest}.."
    cat>${sourceDest}/grafana.list<<-EOF
		deb https://packages.grafana.com/oss/deb stable main
	EOF
    _must_ok


    _info "get gpg siqnature.. "
    _run "curl -s https://packages.grafana.com/gpg.key | apt-key add -"
    _must_ok

    _infoln "update source and install grafana"
    _run -x "apt update && apt install -y apt-transport-https grafana"

    _infoln "enable and start grafana"
    _run "systemctl enable --now grafana-server"

}

# install prometheus
iprometheus(){
    _root

    _run -x "groupadd --system prometheus"

    _run -x "useradd -s /sbin/nologin --system -g prometheus prometheus"

    _run -x "mkdir /var/lib/prometheus"

    for i in rules rules.d files_sd; do
        _run -x "mkdir -p /etc/prometheus/${i}"
    done

    rm -rf /tmp/prometheus
    mkdir -p /tmp/prometheus && cd /tmp/prometheus

    _infoln "download prometheus.."
    curl https://api.github.com/repos/prometheus/prometheus/releases/latest \
        | grep browser_download_url \
        | grep linux-amd64 \
        | cut -d '"' -f 4 \
        | xargs -IR curl -LO R
        #| wget -i -
    _infoln "extract prometheus.."
    tar xvf prometheus*.tar.gz
    _infoln "copy prometheus files.."
    cd prometheus*/
    mv prometheus promtool /usr/local/bin/
    mv prometheus.yml  /etc/prometheus/prometheus.yml
    mv consoles/ console_libraries/ /etc/prometheus/
    cd ~/
    rm -rf /tmp/prometheus

    cp ${this}/prometheus.service /etc/systemd/system

    for i in rules rules.d files_sd; do chown -R prometheus:prometheus /etc/prometheus/${i}; done
    for i in rules rules.d files_sd; do chmod -R 775 /etc/prometheus/${i}; done
    chown -R prometheus:prometheus /var/lib/prometheus/

    _infoln "enable prometheus.."
    systemctl daemon-reload
    systemctl enable --now prometheus
}

# config proxmox-pve-exporter
ipveexporter(){
    _root
    _run -x "groupadd --system prometheus"
    _run -x "useradd -s /sbin/nologin --system -g prometheus prometheus"
    mkdir /etc/prometheus

    _infoln "install python3 pip3.."
    apt install -y python3 python3-pip

    _infoln "install prometheus-pve-exporter.."
    pip3 install prometheus-pve-exporter

    echo "enter root password: "
    stty -echo
    read password
    stty echo
    cat>/etc/prometheus/pve.yml<<-EOF
	default:
	    user: root@pam
	    password: $password
	    verify_ssl: false
	EOF

    chown -R prometheus:prometheus /etc/prometheus/
    chmod -R 775 /etc/prometheus/

    _infoln "install prometheus-pve-exporter service"
    cp ${this}/prometheus-pve-exporter.service /etc/systemd/system
    _infoln "enable prometheus-pve-exporter.."
    systemctl daemon-reload
    systemctl enable --now prometheus-pve-exporter

}

# config prometheus pve exporter
cpveexporter(){
    _root

    echo "input pve ip: "
    read ip

    local pveExporterHeader="#proxmox exporter begin"
    local pveExporterTail="#proxmox exporter end"

    if grep "${pveExporterHeader}" /etc/prometheus/prometheus.yml;then
        echo "already configured pve exporter"
        exit
    fi
    cat>>/etc/prometheus/prometheus.yml<<-EOF
	${pveExporterHeader}
	  - job_name: 'proxmox'
	    metrics_path: /pve
	    static_configs:
	      - targets: ['$ip:9221']
	${pveExporterTail}
	EOF

    _infoln "restart prometheus"
    systemctl restart prometheus
    echo "template id: 10347"
}

# config prometheus node exporter
cnodeexporter(){
    _root

    echo "input node exporter host ip: "
    read ip

    local nodeExporterHeader="#node exporter begin"
    local nodeExporterTail="#node exporter end"

    # if grep "${nodeExporterHeader}" /etc/prometheus/prometheus.yml;then
    #     echo "already configured node exporter"
    # fi
    cat>>/etc/prometheus/prometheus.yml<<-EOF
	${nodeExporterHeader}
	  - job_name: 'node_exporter_metrics${ip}'
	    scrape_interval: 5s
	    static_configs:
	      - targets: ['$ip:9100']
	${nodeExporterTail}
	EOF

    _infoln "restart prometheus"
    systemctl restart prometheus
    echo "template id: 8919"

}

# install node exporter
inodeexporter(){
    _root

    _infoln "downlad node exporter.."
    version=${version:-1.3.1}
    nodeExporterLink="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.linux-amd64.tar.gz"
    wget -P /tmp --timeout=20 "${nodeExporterLink}"
    if [ $? -ne 0 ];then
        nodeExporterLink="https://source711.oss-cn-shanghai.aliyuncs.com/nodeExporter/node_exporter-1.0.1.linux-amd64.tar.gz"
        wget -P /tmp --timeout=20 "${nodeExporterLink}" || { echo "download node exporter failed."; exit 1; }
    fi
    tar -xzvf /tmp/node_exporter-${version}.linux-amd64.tar.gz -C /tmp
    mv /tmp/node_exporter-${version}.linux-amd64/node_exporter /usr/local/bin/
    chmod +x /usr/local/bin/node_exporter

    _infoln "add user node_exporter"
    useradd -rs /bin/false node_exporter

    _infoln "install node_exporter service"
    cp ${this}/node_exporter.service /etc/systemd/system

    _infoln "enable node_exporter service"
    systemctl daemon-reload
    systemctl enable --now node_exporter


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
