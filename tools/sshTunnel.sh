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

# -N: not open shell
# -f: run in background
commonOption="-Nf"

remoteTunnel(){
    if (( $# !=6 ));then
        echo "Usage: $0 <sshPort> <sshUser> <sshHost> <remotePort> <localHost> <localPort>"
        exit 1
    fi

    echo "open remotePort on sshHost to accept network traffic into localHost:localPort"

    sshPort=${1}
    sshUser=${2}
    sshHost=${3}
    remotePort=${4}
    localHost=${5}
    localPort=${6}

    command="ssh -p ${sshPort} -Nf -R ${remotePort}:${localHost}:${localPort} ${sshUser}@${sshHost}"
    echo "run ${command} .."
    eval "${command}"
}

localTunnel(){
    echo TODO
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
