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

search_dir="${this}"
shelllib_path=""
while [ "${search_dir}" != "/" ]; do
    if [ -r "${search_dir}/config/shell/shared/shelllib.sh" ]; then
        shelllib_path="${search_dir}/config/shell/shared/shelllib.sh"
        break
    fi
    search_dir="$(dirname "${search_dir}")"
done

if [ -r "${shelllib_path}" ]; then
    # shellcheck source=/dev/null
    source "${shelllib_path}"
elif [ -r /tmp/shelllib.sh ]; then
    # shellcheck source=/dev/null
    source /tmp/shelllib.sh
else
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    curl -fsSL -o /tmp/shelllib.sh "${shelllibURL}"
    if [ -r /tmp/shelllib.sh ]; then
        # shellcheck source=/dev/null
        source /tmp/shelllib.sh
    fi
fi


###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
portainerPort=${port:-9000}
portainerPortHttps=${ports:-9443}
name=${pname:-portainer}
volumeName=${vname:-portainer_data}

install(){
    if ! command -v docker >/dev/null 2>&1;then
        echo "need docker!"
        return 1
    fi

    cat<<EOF
Install infos:
    Container name: ${name}   (env: pname)
    Portainer http port: ${portainerPort} (env: port)
    Portainer https port: ${portainerPortHttps} (env: ports)
    Volume name: ${volumeName} (env: vname)
EOF
    read -p "Press Enter to continue or ctrl-c to quit." con

    docker volume create ${volumeName}
    docker run -d -p ${portainerPort}:9000 -p 8000:8000 -p ${portainerPortHttps}:9443 --name ${name} --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
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
