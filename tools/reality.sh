#!/bin/bash
function check_os() {
    if lsb_release -a | grep -q "Ubuntu"; then
        echo "the os is ubuntu, ok"
    elif lsb_release -a | grep -q "Debian"; then
        echo "the os is debian, ok"
    else
        echo "unknown os, exit"
        exit 1
    fi
}

function install_ufw() {
    apt-get update
    apt-get install ufw -y
}

function install_lsof() {
    apt-get install lsof -y
}

function find_sshd_port() {
    # find the port of sshd
    lsof -i -P -n | grep sshd | grep -i listen | grep -oE ':[0-9]+' | grep -oE '[0-9]+'
}

function set_firewall() {
    echo "allow ssh port $1"
    sshd_port=$(find_sshd_port)
    if [ -z "$sshd_port" ]; then
        echo "sshd port not found, exit"
        exit 1
    fi
    ufw allow $sshd_port/tcp

    echo "allow https port 443"
    ufw allow 443/tcp

    echo "enable ufw"
    ufw enable
}

function enable_bbr(){
    echo "enable bbr"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
}

function install_xray(){
    echo "install xray"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root 
}

function config_xray(){
    echo "config xray"
    website="www.microsoft.com"
    shortId=$(echo -n "$website" | sha256sum | cut -d' ' -f1 | head -c 8)
    echo "shortId: $shortId"

    uuid=$(xray uuid)
    echo "uuid: $uuid"
    

    keyPair=$(xray x25519)
    publicKey=$(echo "$keyPair" | grep -oE 'Public key: [^ ]+' | cut -d' ' -f3)
    privateKey=$(echo "$keyPair" | grep -oE 'Private key: [^ ]+' | cut -d' ' -f3)
    echo "publicKey: $publicKey"
    echo "privateKey: $privateKey"

    echo "generate config file to /usr/local/etc/xray/config.json"
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

    echo "clash config segment"
    cat<<EOF2
proxies:
  - name: bwg
    type: vless
    server: <IP>
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
EOF2
}

set -e
check_os
install_ufw
install_lsof
set_firewall
enable_bbr
install_xray
config_xray


