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
install(){
    if [ $EUID -ne 0 ];then
        echo "Need root privilege"
        exit 1
    fi

    cat<<EOF
Press <C-c> to set apt proxy (apt source)first
Press <Enter> to continue
EOF
    read cnt

    apt-get remove docker docker-engine docker.io containerd runc
    apt-get update

    apt-get install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg-agent \
        software-properties-common -y

    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -

    apt-key fingerprint 0EBFCD88

    add-apt-repository \
        "deb [arch=amd64] https://download.docker.com/linux/debian \
        $(lsb_release -cs) \
        stable"

    apt-get update
    apt-get install docker-ce docker-ce-cli containerd.io -y

    echo "add $user to group docker"
    usermod -aG docker $user
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
