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
version=${version:-'0.39.1'}
link="https://raw.githubusercontent.com/nvm-sh/nvm/v${version}/install.sh"
configFile=$HOME/.local/apps/init/config/shell/local.sh
install() {
    _require_command curl
    echo "nvm link: $link"

    if [ ! -e "$configFile" ]; then
        touch "$configFile"
    fi
    echo "add config to: $configFile"

    curl -o- "$link" | PROFILE="$configFile" bash

    echo "use 'nvm install --lts' to install lts node"

}

# write your code above
###############################################################################

em() {
    $ed $0
}

function _help() {
    cd "${this}"
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    _help
    ;;
*)
    "$@"
    ;;
esac
