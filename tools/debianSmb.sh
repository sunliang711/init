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

if [ -r ${SHELLRC_ROOT}/shellrc.d/shelllib ];then
    source ${SHELLRC_ROOT}/shellrc.d/shelllib
elif [ -r /tmp/shelllib ];then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ];then
        source /tmp/shelllib
    fi
fi

###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
###############################################################################
# TODO
rootid=0
_root(){
    if [ $EUID -ne $rootid ];then
        echo "need run as root"
        return 1
    fi
}

begin="#BEGIN smb"
end="#END smb"

dest=/etc/network/if-up.d
install(){
    local usage="usage: install <smb_ip> <smb_name> <mount_dir> <smb_user> <smb_password>"
    if ! _root;then
        exit 1
    fi
    if [ $# -lt 5 ];then
        echo "${usage}"
        exit 1
    fi
    if ! dpkg -L cifs-utils >/dev/null 2>&1;then
        echo "install cifs-utils"
        apt install -y cifs-utils || { echo "install cifs-utils failed"; exit 1; }
    fi
    smbip=${1:?'missing smb ip'}
    smbname=${2:?'missing smb name'}
    mountdir=${3:?'missing mount dir'}
    if [ ! -d ${mountdir} ];then
        echo "Not find mount dir: ${mountdir}"
        exit 1
    fi
    mountdir="$(cd ${mountdir} && pwd)"
    smbuser=${4:?'missing smb user'}
    smbpassword=${5:?'missing smb password'}

    local credentialFile="${home}/.${smbip}-${smbname}-credential"
    cat<<-EOF>${credentialFile}
	username=${smbuser}
	password=${smbpassword}
	EOF

    _backup

    cat<<-EOF>>/etc/fstab
	${begin}
	#//${smbip}/${smbname} ${mountdir} cifs credentials=${credentialFile},users,rw,iocharset=utf8,sec=ntlm 0 0
	//${smbip}/${smbname} ${mountdir} cifs credentials=${credentialFile} 0 0
	${end}
	EOF

    cat>${dest}/fstab<<-EOF
	#!/bin/sh
	mount -a
	EOF
}

_backup(){
    if [ ! -e /etc/fstab.orig ];then
        cp /etc/fstab /etc/fstab.orig
    fi

}

uninstall(){
    if ! _root;then
        exit 1
    fi
    if [ -e $home/.smbcredentials ];then
        /bin/rm -rf $home/.smbcredentials
    fi

    _backup

    sed -i "/${begin}/,/${end}/d" /etc/fstab
    rm ${dest}/fstab
}

em(){
    $editor $0
}

###############################################################################
# write your code above
###############################################################################
function _help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    # perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
    # perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v '^\t_'
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

function _loadENV(){
    if [ -z "$INIT_HTTP_PROXY" ];then
        echo "INIT_HTTP_PROXY is empty"
        echo -n "Enter http proxy: (if you need) "
        read INIT_HTTP_PROXY
    fi
    if [ -n "$INIT_HTTP_PROXY" ];then
        echo "set http proxy to $INIT_HTTP_PROXY"
        export http_proxy=$INIT_HTTP_PROXY
        export https_proxy=$INIT_HTTP_PROXY
        export HTTP_PROXY=$INIT_HTTP_PROXY
        export HTTPS_PROXY=$INIT_HTTP_PROXY
        git config --global http.proxy $INIT_HTTP_PROXY
        git config --global https.proxy $INIT_HTTP_PROXY
    else
        echo "No use http proxy"
    fi
}

function _unloadENV(){
    if [ -n "$https_proxy" ];then
        unset http_proxy
        unset https_proxy
        unset HTTP_PROXY
        unset HTTPS_PROXY
        git config --global --unset-all http.proxy
        git config --global --unset-all https.proxy
    fi
}


case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
