#!/bin/bash

set -e
root=0

check(){
    if [ "${EUID}" -ne "$root" ];then
        echo "Need root priviledge."
        exit 0
    fi
}

check

install(){
    apt update
    apt install apt-transport-https ca-certificates curl gnupg2 software-properties-common -y
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
    apt update
    apt install docker-ce -y
}

install
