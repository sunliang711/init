#!/bin/bash

proxyPort=5053
resolver="https://dns.google/dns-query"
proxy=socks5://10.1.1.177:4020

start() {
    set -x
    if [ -z "${proxy}" ]; then
        /usr/local/bin/https_dns_proxy -p "${proxyPort}" -u nobody -g nogroup -r "${resolver}" -b "8.8.8.8,8.8.4.4,1.1.1.1"
    else
        /usr/local/bin/https_dns_proxy -p "${proxyPort}" -u nobody -g nogroup -r "${resolver}" -b "8.8.8.8,8.8.4.4,1.1.1.1" -t "${proxy}"
    fi
}

em() {
    $ed $0
}

function _help() {
    cd "${this}"
    cat <<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
"" | -h | --help | help)
    _help
    ;;
*)
    "$@"
    ;;
esac
