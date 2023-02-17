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
_createDirWhenNeed(){
    local dir=${1}
    if [ ! -d "${dir}" ];then
        echo -n "mkdir ${dir} .. "
        mkdir -p "${dir}"
        if [ $? -eq 0 ];then
            echo "ok"
            return 0
        else
            echo "failed"
            return 1
        fi
    fi
}

_fullpath(){
    local path="${1}"
    if [ -z "${path}" ];then
        _err "missing path"
        return 1
    fi

    if [ ! -d "${path}" ];then
        _err "cannot find direcotry: ${path}"
        return 1
    fi

    cd "${path}" && pwd
}

PUID=0
PGID=0

install(){
    local usage="install <username> <password> <install destination>"
    local username=${1}
    local password=${2}
    local dest=${3}
    if [ -z "${username}" ] || [ -z "${password}" ] || [ -z "${dest}" ];then
        echo "${usage}"
        exit 1
    fi

    if [ ! -d "${dest}" ];then
        echo -n "mkdir ${dest} .. "
        mkdir -p ${dest}
        if [ "$?" -eq 0 ];then
            echo "ok"
        else
            echo "failed"
            exit 1
        fi
    fi
    if ! _createDirWhenNeed "${dest}";then
        exit 1
    fi

    local configDir="${dest}/config"
    local downloadDir="${dest}/download"
    local watchDir="${dest}/download/watch"

    _createDirWhenNeed ${configDir}
    _createDirWhenNeed ${downloadDir}
    _createDirWhenNeed ${watchDir}

    local composeFile="${dest}/docker-compose.yml"
    echo -n "write docker compose file to ${composeFile} .. "
    cat<<-EOF>${composeFile}
version: "2.1"
services:
  transmission:
    image: ghcr.io/linuxserver/transmission
    container_name: transmission
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=Asia/Shanghai
      - TRANSMISSION_WEB_HOME=/combustion-release/ #optional
      - USER=${username} #optional
      - PASS=${password} #optional
    volumes:
      - ${configDir}:/config
      - ${downloadDir}:/downloads
      - ${watchDir}:/watch
    ports:
      - 9091:9091
      - 51413:51413
      - 51413:51413/udp
    restart: unless-stopped
EOF
    if [ $? -eq 0 ];then
        echo "ok"
        echo "transmission uid: ${PUID} gid: ${PGID}"
        echo "run 'docker-compose up -d' in ${dest} to start transmission."
        echo "You can mount smb on ${downloadDir} to let it be download destination"
        echo "for example: mount --bind <dsm-mount-dir> ${downloadDir}, after bind then run transmission service!!"
    else
        echo "failed"
    fi

    if ! command -v docker >/dev/null 2>&1;then
        echo "Warning: need docker command"
    fi
    if ! command -v docker-compose >/dev/null 2>&1;then
        echo "Warning: need docker-compose command"
    fi

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
