#!/bin/bash

if (($EUID!=0));then
    echo "Need run as root."
    exit 1
fi

case $(uname) in
    Linux)
        SWAP=/var/swap.img
        if [[ ! -e "$SWAP" ]];then
            echo "create $SWAP file,wait a minute..."
            if command -v pv >/dev/null 2>&1;then
                pv /dev/zero | dd of="$SWAP" bs=1024K count=1000
            else
                dd if=/dev/zero of="$SWAP" bs=1024k count=1000
            fi
            chmod 0600 "$SWAP"
            mkswap "$SWAP"
            swapon "$SWAP"
            echo "$SWAP none swap sw 0 0">>/etc/fstab
        else
            echo "Already exist swap file."
        fi
        ;;
    *)
        echo "Only run on Linux"
        ;;
esac
