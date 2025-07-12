#!/bin/bash
function log() {
    # redirect to stderr, because stdout is redirected to file
    echo ">> $@" 1>&2
}

function check_os() {
    if lsb_release -a | grep -q "Ubuntu"; then
        log "the os is ubuntu, ok"
    elif lsb_release -a | grep -q "Debian"; then
        log "the os is debian, ok"
    else
        log "unknown os, exit"
        exit 1
    fi
}

function redirect_stdout_to_file() {
    file_name=/tmp/reality.log
    log "redirect stdout to file: $file_name"
    exec 1>> "$file_name"
}

function update_apt() {
    log "update apt.."
    apt-get update >/dev/null
}

function install_package() {
    if ! command -v $1 > /dev/null; then
        log "$1 command not found, install $1.."
        apt-get install $1 -y >/dev/null
    fi
}

function install_ufw() {
    install_package ufw
}

function install_lsof() {
    install_package lsof
}

function find_sshd_port() {
    # find the port of sshd
    # may be 2 port (ipv4 ipv6), so use head -1
    lsof -i -P -n | grep sshd | grep -i listen | head -1 | grep -oE ':[0-9]+' | grep -oE '[0-9]+'
}

function set_firewall() {
    sshd_port=$(find_sshd_port)
    if [ -z "$sshd_port" ]; then
        log "sshd port not found, exit"
        exit 1
    fi
    log "allow ssh port $sshd_port"
    ufw allow $sshd_port/tcp

    log "allow https port 443"
    ufw allow 443/tcp

    log "enable ufw"
    ufw enable
}

function enable_bbr(){
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        log "bbr already enabled, skip"
    else
        log "enable bbr"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

function install_xray(){
    log "install xray"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root 
}

function config_xray(){
    log "config xray"

    log "get public ip"
    publicIp=$(curl -4 ifconfig.me)
    log "public ip: $publicIp"

    website="www.microsoft.com"
    date=$(date +%s)
    shortId=$(echo -n "$website$date" | sha256sum | cut -d' ' -f1 | head -c 8)
    log "shortId: $shortId"

    uuid=$(xray uuid)
    log "uuid: $uuid"
    

    keyPair=$(xray x25519)
    publicKey=$(echo "$keyPair" | grep -oE 'Public key: [^ ]+' | cut -d' ' -f3)
    privateKey=$(echo "$keyPair" | grep -oE 'Private key: [^ ]+' | cut -d' ' -f3)
    log "publicKey: $publicKey"
    log "privateKey: $privateKey"

    log "generate config file to /usr/local/etc/xray/config.json"
    cat<<EOF>/usr/local/etc/xray/config.json
{
"log": {
    "loglevel": "warning"
},
"routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
        {
            "type": "field",
            "domain": [
                "geosite:category-ads-all"
            ],
            "outboundTag": "block"
        },
        {
            "type": "field",
            "ip": [
                "geoip:cn"
            ],
            "outboundTag": "block"
        }
    ]
},
"inbounds": [
    {
        "listen": "0.0.0.0",
        "port": 443,
        "protocol": "vless",
        "settings": {
            "clients": [
                {
                    "id": "$uuid",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$website:443",
                "xver": 0,
                "serverNames": [
                    "$website"
                ],
                "privateKey": "$privateKey",
                "publicKey": "$publicKey",
                "minClientVer": "",
                "maxClientVer": "",
                "maxTimeDiff": 0,
                "shortIds": [
                    "$shortId"
                ]
            }
        },
        "sniffing": {
            "enabled": true,
            "destOverride": [
                "http",
                "tls"
            ]
        }
    }
],
"outbounds": [
    {
        "protocol": "freedom",
        "tag": "direct"
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
],
"policy": {
    "levels": {
        "0": {
            "handshake": 3,
            "connIdle": 180
        }
    }
}
}     
EOF

    systemctl restart xray

    cat<<EOF2 1>&2
=========clash config segment begin=========
proxies:
  - name: bwg
    type: vless
    server: ${publicIp}
    port: 443
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    xudp: true
    flow: xtls-rprx-vision
    servername: $website
    reality-opts:
      public-key: $publicKey
      short-id: $shortId
    client-fingerprint: chrome
=========clash config segment end=========
EOF2

cat<<EOF3 1>&2
=========shadowrocket config begin=========
{
  "host" : "$publicIp",
  "obfsParam" : "",
  "alpn" : "",
  "cert" : "",
  "created" : 1752035905.2086039,
  "updated" : 1752036056.454201,
  "tls" : true,
  "mtu" : "",
  "flag" : "US",
  "privateKey" : "",
  "hpkp" : "",
  "uuid" : "$uuid",
  "path" : "",
  "downmbps" : "",
  "type" : "VLESS",
  "user" : "",
  "xtls" : 2,
  "ech" : "",
  "plugin" : "none",
  "method" : "auto",
  "data" : "",
  "filter" : "",
  "protoParam" : "",
  "reserved" : "",
  "alterId" : "",
  "upmbps" : "",
  "keepalive" : "",
  "port" : "443",
  "obfs" : "none",
  "dns" : "",
  "publicKey" : "$publicKey",
  "peer" : "$website",
  "weight" : 1752035905,
  "ip" : "",
  "title" : "yangBwg",
  "proto" : "",
  "password" : "$uuid",
  "chain" : "",
  "shortId" : "$shortId"
}
=========shadowrocket config end=========
EOF3
}

set -e

redirect_stdout_to_file
update_apt
check_os
install_ufw
install_lsof
set_firewall
enable_bbr
install_xray
config_xray


