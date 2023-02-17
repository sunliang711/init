#!/bin/bash
rpath="$(readlink ${BASH_SOURCE})"
if [ -z "$rpath" ];then
    rpath=${BASH_SOURCE}
fi
thisDir="$(cd $(dirname $rpath) && pwd)"
cd "$thisDir"

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
blue=$(tput setaf 4)
cyan=$(tput setaf 5)
        bold=$(tput bold)
reset=$(tput sgr0)
function runAsRoot(){
    verbose=0
    while getopts ":v" opt;do
        case "$opt" in
            v)
                verbose=1
                ;;
            \?)
                echo "Unknown option: \"$OPTARG\""
                exit 1
                ;;
        esac
    done
    shift $((OPTIND-1))
    cmd="$@"
    if [ -z "$cmd" ];then
        echo "${red}Need cmd${reset}"
        exit 1
    fi

    if [ "$verbose" -eq 1 ];then
        echo "run cmd:\"${red}$cmd${reset}\" as root."
    fi

    if (($EUID==0));then
        sh -c "$cmd"
    else
        if ! command -v sudo >/dev/null 2>&1;then
            echo "Need sudo cmd"
            exit 1
        fi
        sudo sh -c "$cmd"
    fi
}
###############################################################################
        # write your code below (just define function[s])
###############################################################################
# TODO
function need(){
    for cmd in "$@";do
        if ! command -v $cmd >/dev/null 2>&1;then
            echo "Need '$cmd'"
            exit 1
        fi
    done
}

build(){
    need cmake automake unzip pkg-config git libtoolize gettext g++
    cd /tmp
    git clone --depth 1 https://github.com/neovim/neovim
    cd neovim
    make CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$HOME/.neovim"
    make install && echo "nvim is installed in $HOME/.neovim"
}



###############################################################################
# write your code above
###############################################################################
function help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$1" if /^\s*(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
}

case "$1" in
     ""|-h|--help|help)
        help
        ;;
    *)
        "$@"
esac
