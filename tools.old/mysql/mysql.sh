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
runAsRoot(){
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
source config 2>/dev/null || { echo "Config file: 'config' not found"; exit 1; }

dumpFile=
importFile=

option="-h ${dbHost} -P ${dbPort} -u ${dbUser}"
dropdb(){
    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    echo "drop database: $dbName..."
    mysqladmin $option drop ${dbName}

}

createdb(){
    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    echo "create database: $dbName"
    mysqladmin $option create ${dbName}
}

dump(){
    dumpFile="${1}"
    if [ -z "${dumpFile}" ];then
        echo "Missing parameter as dump file"
        return 1
    fi
    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    mysqldump $option ${dbName} > ${dumpFile}
}

import(){
    importFile="${1}"
    if [ -z "${importFile}" ];then
        echo "Missing parameter as import file"
        return 1
    fi

    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    mysql $option ${dbName} < ${importFile}
}

login(){
    echo "Enter password to login mysql"
    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    mysql $option
}

rmAllTables(){
    if [ -n $dbPass ];then
        option="$option -p$dbPass"
    else
        option="$option -p"
    fi
    TABLES=$(mysql $option $dbName -e 'show tables' | awk '{ print $1 }' | grep -v '^Tables' )
    for t in $TABLES;do
        echo "Delete $t table from $dbName database..."
        mysql $option $dbName -e "drop table $t"
    done
}


###############################################################################
# write your code above
###############################################################################
help(){
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^(function)?\s*?(\w+)\(\)\{$/' $(basename ${BASH_SOURCE}) | grep -v runAsRoot
}

case "$1" in
     ""|-h|--help|help)
        help
        ;;
    *)
        "$@"
esac
