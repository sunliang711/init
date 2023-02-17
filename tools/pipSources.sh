#!/bin/sh
if ! command -v pip >/dev/null 2>&1;then
    echo "Warning: Not find pip"
fi
if ! command -v pip3 > /dev/null 2>&1;then
    echo "Warning: Not find pip3"
fi

if [ ! -d ~/.pip ];then
      mkdir ~/.pip
fi
cat>~/.pip/pip.conf<<EOF
[global]
trusted-host = pypi.tuna.tsinghua.edu.cn
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
EOF
if [ $? -eq 0 ];then
    echo "Done"
else
    echo "Error"
fi
