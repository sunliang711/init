#!/bin/sh
releaseFile=/etc/os-release
if [ ! -e "$releaseFile" ];then
    echo "Not found $releaseFile"
    exit 1
fi
if grep '^ID' "$releaseFile" | grep -q alpine;then
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories
    echo "Run 'apk update' manaually!"
fi
