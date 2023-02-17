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
function need(){
    if ! command -v $1 >/dev/null 2>&1;then
        echo "need $1"
        exit 1
    fi
}

version=${version:-"0.6.0"}
if [ -n "${local_app_root}" ];then
    prefix=${local_app_root}
else
    prefix=$HOME/.local/apps
fi

dest=${prefix}/nvim/$version

install(){
    need curl
    need tar
    cat<<EOF
supported env vars:
version, local_app_root(install location)
EOF
    if [ ! -d $dest ];then
        mkdir -p $dest
    fi
    case $(uname) in
        Linux)
            case $(uname -m) in
                x86_64)
                    local nvimURL="https://source711.oss-cn-shanghai.aliyuncs.com/neovim/$version/nvim-linux64.tar.gz"
                    ;;
                aarch64)
                    local nvimURL="https://source711.oss-cn-shanghai.aliyuncs.com/neovim/$version/nvim-linuxarm64.tar.bz2"
                    ;;
                aarch64)
                    local nvimURL="https://source711.oss-cn-shanghai.aliyuncs.com/neovim/0.5.0/nvim-linuxarm64.tar.bz2"
                    ;;
            esac
            ;;
        Darwin)
            local nvimURL="https://source711.oss-cn-shanghai.aliyuncs.com/neovim/$version/nvim-macos.tar.gz"
            ;;
    esac
    local tarFile="${nvimURL##*/}"
    local name="${tarFile%.tar.*}"
    cd /tmp
    if [ ! -e ${tarFile} ];then
        curl -LO "$nvimURL"
    fi

    cmd="tar -C $dest -xvf ${tarFile}"
    echo "$cmd ..."
    bash -c "$cmd >/dev/null"  || { echo "extract ${tarFile} failed."; exit 1; }

    echo "nvim $version has been installed to $dest/$name/bin"
    # linkDest="${home}/.local/bin"
    # if [ -d "${linkDest}" ]; then
    #     # find all executable
    #     for f in $(find ${dest}/$name/bin ! -type d);do
    #         ln -sf ${f} "${linkDest}"
    #     done
    # fi

    # DELETE later
    # local localFile="${SHELLRC_ROOT}/shellrc.d/local"
    # local binPath="${dest}/$name/bin"
    # if [ -e "${localFile}" ];then
    #     if ! grep -q "${binPath}" "${localFile}";then
    #         echo "append_path ${binPath}" >> "${localFile}"
    #     fi
    # else
    #     echo "nvim $version has been installed to $dest, add ${binPath} to PATH manually"
    # fi
}

uninstall(){
    if [ -d $dest ];then
        echo "remove $dest..."
        /bin/rm -rf $dest && { echo "Done."; }
    fi
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
