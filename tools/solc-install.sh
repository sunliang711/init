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
# all version
if [ -n "${SOLC_DEST}" ];then
    dest="${SOLC_DEST}"
else
    dest=$HOME/.local/apps/solc
fi

install(){
    echo "solc will be installed in $dest or env SOLC_DEST"
    _linux
    version=${1:?'missing version'}
    solcURL=https://github.com/ethereum/solidity/releases/download/v${version}/solc-static-linux
    versionDest="${dest}/${version}"
    binDir="${dest}/bin"
    if [ ! -d "${binDir}" ];then
        mkdir -p "${binDir}"
    fi
    if [ ! -d "${versionDest}" ];then
        mkdir -p "${versionDest}"
    fi
    cd "${versionDest}"
    binaryName="${solcURL##*/}"
    curl -LO "${solcURL}" && mv "${binaryName}" "solc-${version}" && chmod +x "solc-${version}"
    echo "solc-${version} has been installed in ${versionDest}"
    ln -sf "${versionDest}/solc-${version}" "${binDir}"
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
