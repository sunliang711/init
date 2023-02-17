#!/bin/sh
id=$(grep '^ID=' /etc/os-release |awk -F'=' '{print $2}')
if [ "$id" != "alpine" ];then
    echo "Not alpine"
    exit 1
fi
sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories
echo "Run \"apk update\" to update source list"
