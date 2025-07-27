#!/bin/bash
function log() {
    # redirect to stderr, because stdout is redirected to file
    echo ">> $@" 1>&2
}

xrayConfigDir="/usr/local/etc/xray"
serviceName="vmess-websocket"
vmessWebsocketConfigFile="$xrayConfigDir/${serviceName}.json"
certDir="/root/certs"
wsPath="/vmess-websocket"

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

function require_root() {
	if [ "${EUID}" -ne 0 ]; then
		log "this script must be run as root, exit"
		exit 1
	fi
}

function export_path(){
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	log "export PATH: $PATH"
}

function redirect_stdout_to_file() {
    file_name=/tmp/vmess-websocket.log
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

function install_jq(){
	install_package jq
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

function check_domain_resolve(){
    domain=${1:?"domain is required"}
    log "check domain $domain resolve"
    publicIp=$(curl -4 ifconfig.me)
    log "public ip: $publicIp"

    resolveIp=$(nslookup $domain | grep -oE 'Address: [^ ]+' | grep -oE '[0-9.]+')
    log "resolve ip: $resolveIp"

    if [ "$publicIp" != "$resolveIp" ]; then
        log "domain $domain resolve failed, exit"
        exit 1
    fi

    log "domain $domain resolve success"
}

function set_firewall() {
    sshd_port=$(find_sshd_port)
    if [ -z "$sshd_port" ]; then
        log "sshd port not found, exit"
        exit 1
    fi
    log "allow ssh port $sshd_port"
    ufw allow $sshd_port/tcp

    # acme.sh need http port 80
    log "allow http port 80"
    ufw allow 80/tcp

    log "allow https port 443"
    ufw allow 443/tcp

    log "enable ufw"
    ufw --force enable
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

function install_acme(){
    email=${1:?"email is required"}
    log "install socat"
    install_package socat

    if [ -e /root/.acme.sh/acme.sh ]; then
        log "acme already installed, skip"
        return 0
    fi

    log "install acme"
    curl https://get.acme.sh | sh -s email="$email"

    if [ ! -e /root/.acme.sh/acme.sh ]; then
        log "acme install failed, exit"
        exit 1
    fi

    log "acme install success"
}

function issue_cert(){
    domain=${1:?"domain is required"}
    log "issue cert for $domain"
    # ufw allow 80/tcp
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone

    if [ ! -e /root/.acme.sh/${domain}_ecc/${domain}.cer ]; then
        log "issue cert failed, exit"
        exit 1
    fi

    log "issue cert success"

    log "install cert to $certDir"
    mkdir -p "$certDir"
    /root/.acme.sh/acme.sh --install-cert -d "$domain" --key-file "$certDir/${domain}.key" --fullchain-file "$certDir/${domain}.pem"

    if [ ! -e "$certDir/${domain}.pem" ]; then
        log "cert install failed, exit"
        exit 1
    fi

    log "cert install success"
}



function install_xray(){
	if [ -e /usr/local/bin/xray ]; then
		log "xray already installed, skip"
		return 0
	fi

    log "install xray"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
    if [ ! -e /usr/local/bin/xray ]; then
		log "xray install failed, exit"
		exit 1
	fi
}

function config_xray(){
    domain=${1:?"domain is required"}
    log "config xray"

    uuid=$(xray uuid)
    log "uuid: $uuid"

    log "generate config file to $vmessWebsocketConfigFile"
    cat<<EOF>$vmessWebsocketConfigFile
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
        "protocol": "vmess",
        "settings": {
            "clients": [
                {
                    "id": "$uuid",
                    "alterId": 0
                }
            ]
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "certificates": [
                    {
                        "certificateFile": "$certDir/${domain}.pem",
                        "keyFile": "$certDir/${domain}.key"
                    }
                ]
            }
        },
        "wsSettings": {
            "path": "$wsPath",
            "headers": {
                "Host": "$domain"
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


    cat<<EOF2 1>&2
=========clash config segment begin=========
proxies:
    - name: "vmess-ws-tls"
        type: vmess                # 协议类型为 VMess
        server: $domain            # 服务器地址（域名或 IP）
        port: 443                  # 服务器端口，通常为 443 以使用 HTTPS 端口
        uuid: $uuid                # 你的 VMess 用户 UUID
        alterId: 0                 # Alter ID，推荐设为 0（新版 VMess 默认）
        cipher: auto               # 加密方式，推荐 auto，支持 auto/aes-128-gcm/chacha20-poly1305/none
        udp: true                  # 启用 UDP 支持（根据需要）
        tls: true                  # 启用 TLS
        skip-cert-verify: false    # 是否跳过证书验证，建议为 false 以确保安全
        servername: $domain        # TLS 的 SNI，需与服务器证书域名一致
        network: ws                # 传输协议为 WebSocket
        ws-opts:                   # WebSocket 配置(在clash中(mihomo),这行不需要，而且下面的配置不在这个节点的下一级，奇怪了)
	    path: "$wsPath"            # WebSocket 路径，需与服务器端一致
	    headers:
	      Host: $domain          # WebSocket Host
=========clash config segment end=========
EOF2

cat<<EOF3 1>&2
=========shadowrocket config begin=========
{
  "host" : "$domain",
  "tls" : true,
  "flag" : "US",
  "uuid" : "$uuid",
  "type" : "VMess",
  "alterId" : 0,
  "plugin" : "none",
  "method" : "auto",
  "port" : "443",
  "obfs" : "none",
  "peer" : "$domain",
  "weight" : 1752035905,
  "title" : "vmess-ws-tls",
  "password" : "$uuid",
  "path" : "$wsPath"
}
=========shadowrocket config end=========
EOF3

cat<<EOF4 1>&2
=========xray client config begin=========
TODO
=========xray client config end=========
EOF4
}

function restart(){
	  systemctl daemon-reload
	  systemctl restart xray@${serviceName}
      log "restart xray success"
}

set -e

email="${1:?email is required}"
domain="${2:?domain is required}"

require_root
export_path
redirect_stdout_to_file
check_os
check_domain_resolve "$domain"
update_apt
install_jq
install_lsof
install_ufw
set_firewall
enable_bbr
install_acme "$email"
issue_cert  "$domain"
install_xray
config_xray "$domain"
restart
