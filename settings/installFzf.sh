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

if [ -r ${SHELLRC_ROOT}/shelllib ]; then
    source ${SHELLRC_ROOT}/shelllib
elif [ -r /tmp/shelllib ]; then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ]; then
        source /tmp/shelllib
    fi
fi

###############################################################################
# write your code below (just define function[s])
###############################################################################
# TODO
install() {
    cd "${this}"
    echo "Install fzf ..."

    if [ ! -d ~/.fzf ]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
        ~/.fzf/install --all
    else
        echo "~/.fzf exists, skip ..."
    fi

    #     if ! grep -q '#BEGIN FZF function' ~/.zshrc; then
    #         echo "add source $(pwd)/fzffunction.sh in .zshrc"
    #         cat <<EOF >>~/.zshrc
    # #BEGIN FZF function
    # source $(pwd)/fzffunctions.sh
    # #END FZF function
    # EOF
    #     fi
    #
    #     if ! grep -q '#BEGIN FZF function' ~/.bashrc; then
    #         echo "add source $(pwd)/fzffunction.sh in .bashrc"
    #         cat <<EOF2 >>~/.bashrc
    # #BEGIN FZF function
    # source $(pwd)/fzffunctions.sh
    # #END FZF function
    # EOF2
    #     fi

    if ! command -v fd >/dev/null 2>&1; then
        echo "${red}Warning: install fd or fd-find for fzf${reset}"
    fi

    if ! command -v bat >/dev/null 2>&1; then
        echo "${cyan}Recommend: install bat for fzf preview${reset}"
    fi
}

uninstall() {
    ~/.fzf/uninstall
    /bin/rm -rf ~/.fzf
    local output=/tmp/$$.fzf
    sed -e '/#BEGIN FZF function/,/#END FZF function/d' $home/.zshrc >"${output}"
    mv "${output}" $home/.zshrc
}

###############################################################################
# write your code above
###############################################################################
help() {
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    help
    ;;
*)
    "$@"
    ;;
esac
