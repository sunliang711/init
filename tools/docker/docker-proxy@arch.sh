#!/bin/bash
if (($EUID!=0));then
    echo "Need $(tput setaf 1)Root$(tput sgr0) privilege!"
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1;then
    echo "Only support $(tput setaf 1)archlinux!"
    exit 1
fi

dir=/etc/systemd/system/docker.service.d
if [ ! -d $dir  ];then
    mkdir $dir
fi

cfg=/etc/systemd/system/docker.service.d/proxy.conf
if [ -e $cfg ];then
    read -p "$cfg already exist,reinstall ? [Y/n] "  re
    if [[ "$re" != [nN] ]];then
        cp proxy.conf $cfg

        systemctl daemon-reload
        systemctl restart docker
        systemctl show --property Environment docker
    fi
else
    cp proxy.conf $cfg

    systemctl daemon-reload
    systemctl restart docker
    systemctl show --property Environment docker
fi

