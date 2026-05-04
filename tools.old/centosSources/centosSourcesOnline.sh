#!/bin/bash

usage(){
    cat<<-EOF
		Usage: $(basename $0) Options
		Options:
		         -h  print this message
EOF
    exit 1
}

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]];then
    usage
fi

make(){
    ##check /etc/os-release
    releaseFile=/etc/redhat-release
    if [[ ! -e "$releaseFile" ]];then
        echo "Not found $releaseFile" 1>&2
        exit 1
    fi

    ##get VERSION_ID
    vid=$(grep -oP '(?<=release )[\d]' "$releaseFile")
    repoFile="https://raw.githubusercontent.com/sunliang711/init/master/tools/centosSources/CentOS${vid}-Base-163.repo"
    #download repoFile
    curl -LO $repoFile
    repoFile=CentOS${vid}-Base-163.repo
    if [[ ! -e "$repoFile" ]];then
        echo "Not found $repoFile" 1>&2
        exit 1
    fi
    destFile=/etc/yum.repos.d/CentOS-Base.repo
    ##backup
    if [[ -e "$destFile" ]];then
        mv "$destFile" "${destFile}.bak"
    fi
    ##new file
    mv "$repoFile" "$destFile"

    echo "Run 'yum clean all && yum makecache' manaually!"
}
make
