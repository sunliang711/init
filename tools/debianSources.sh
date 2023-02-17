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
# function with 'function' is hidden when run help, without 'function' is show
###############################################################################
# TODO
install(){
    dest=/etc/apt/sources.list
    rootid=0
    if [ $EUID -ne $rootid ];then
        echo "need root privilege!"
        exit 1
    fi
    cp ${dest} ${dest}.bak-$(date +%FT%T)

    url=http://mirrors.163.com
    codename=$(grep -i 'version_codename' /etc/os-release | awk -F= '{print $2}')
    if [ -z $codename ];then
        echo "Not find codename"
        exit 1
    fi

    cat<<EOF>${dest}
deb ${url}/debian/ ${codename} main non-free contrib
deb ${url}/debian/ ${codename}-updates main non-free contrib
deb ${url}/debian/ ${codename}-backports main non-free contrib
deb-src ${url}/debian/ ${codename} main non-free contrib
deb-src ${url}/debian/ ${codename}-updates main non-free contrib
deb-src ${url}/debian/ ${codename}-backports main non-free contrib
deb ${url}/debian-security/ ${codename}/updates main non-free contrib
deb-src ${url}/debian-security/ ${codename}/updates main non-free contrib
EOF
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
function loadENV(){
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

function unloadENV(){
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
        help
        ;;
    *)
        "$@"
esac
