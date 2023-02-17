#!/bin/bash

install(){
    sudo iptables -A OUTPUT -p tcp --sport 30303
    sudo iptables -A OUTPUT -p udp --sport 30303
}

clear(){
    sudo iptables -D OUTPUT -p tcp --sport 30303
    sudo iptables -D OUTPUT -p udp --sport 30303
}

check(){
    sudo iptables -n -L -v
}

help(){
  cat<<EOF
Usage: $(basename $0) CMD

CMD:
EOF
perl -lne 'print "\t$2" if /^(function)?\s*?(\w+)\(\)\{$/' $(basename ${BASH_SOURCE})
}

case "$1" in
    ""|-h|--help|help)
    help
    ;;
  *)
    "$@"
esac
