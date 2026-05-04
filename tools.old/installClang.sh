#!/bin/bash

if [ $EUID -ne 0 ];then
    echo "Need root privilege!"
    exit 1;
fi

cd /tmp
dest=/usr/local

# for ubuntu 16 or debian 9
url="http://releases.llvm.org/9.0.0/clang+llvm-9.0.0-x86_64-linux-gnu-ubuntu-16.04.tar.xz"
curl -LO "${url}" || { echo "download clang failed!"; exit 1; }

tarFile=$(echo ${url##*/})
directoryName=$(echo ${tarFile%.tar.xz})
tar xvf $tarFile && cd ${directoryName}

for d in *;do
    rsync -av $d $dest
done
