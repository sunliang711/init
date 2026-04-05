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
