#!/bin/bash
# 本脚本基于xray@.service配置，所有在/usr/local/etc/xray/%i.json文件都可以作为实例运行
# 支持两种TLS模式:
#   1. xray   - xray直接处理TLS证书 (原有方式)
#   2. nginx  - nginx反代xray, 由nginx处理TLS证书
xrayConfigDir="/usr/local/etc/xray"
serviceName="vmess-websocket"
vmessWebsocketConfigFile="$xrayConfigDir/${serviceName}.json"
certDir="/root/certs"
wsPath="/vmess-websocket"
nginxConfDir="/etc/nginx"
nginxSiteConf="/etc/nginx/sites-available/${serviceName}.conf"
nginxSiteLink="/etc/nginx/sites-enabled/${serviceName}.conf"
# xray在nginx模式下的本地监听端口
xrayLocalPort=10086

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
	cmd=${1}
	pkg=${2:-$1}
    if ! command -v ${cmd} > /dev/null; then
        log "$1 command not found, install $1.."
        apt-get install ${pkg} -y >/dev/null
    fi
}

function install_jq(){
	install_package jq
}

function install_nslookup() {
	install_package nslookup dnsutils
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
    # if /etc/sysctl.conf not exist, create it
    if [ ! -e /etc/sysctl.conf ]; then
        log "enable bbr"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        return
    fi

    # if /etc/sysctl.conf exist, check if bbr is enabled
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
    if [ -e /root/.acme.sh/${domain}_ecc/${domain}.cer ]; then
        log "cert already exists, skip"
        return 0
    fi

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

function issue_cert_nginx(){
    domain=${1:?"domain is required"}
    if [ -e /root/.acme.sh/${domain}_ecc/${domain}.cer ]; then
        log "cert already exists, skip"
        return 0
    fi

    log "issue cert for $domain (nginx mode, using webroot)"

    # 创建webroot目录
    mkdir -p /var/www/acme-challenge

    # 先写一个临时nginx配置用于http验证
    cat > /etc/nginx/sites-available/acme-temp.conf <<ACMEEOF
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root /var/www/acme-challenge;
    }
}
ACMEEOF
    ln -sf /etc/nginx/sites-available/acme-temp.conf /etc/nginx/sites-enabled/acme-temp.conf
    # 移除default站点避免冲突
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx

    /root/.acme.sh/acme.sh --issue -d "$domain" -w /var/www/acme-challenge

    # 清理临时配置
    rm -f /etc/nginx/sites-available/acme-temp.conf
    rm -f /etc/nginx/sites-enabled/acme-temp.conf

    if [ ! -e /root/.acme.sh/${domain}_ecc/${domain}.cer ]; then
        log "issue cert failed, exit"
        exit 1
    fi

    log "issue cert success"

    log "install cert to $certDir"
    mkdir -p "$certDir"
    /root/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$certDir/${domain}.key" \
        --fullchain-file "$certDir/${domain}.pem" \
        --reloadcmd "systemctl reload nginx"

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

function install_nginx(){
    if command -v nginx > /dev/null; then
        log "nginx already installed, skip"
        return 0
    fi

    log "install nginx"
    apt-get install nginx -y >/dev/null

    if ! command -v nginx > /dev/null; then
        log "nginx install failed, exit"
        exit 1
    fi

    log "nginx install success"

    # 启动并设置开机自启
    systemctl start nginx
    systemctl enable nginx
}

function config_nginx(){
    domain=${1:?"domain is required"}
    log "config nginx for domain $domain"

    if [ -e "$nginxSiteConf" ]; then
        log "nginx config file: $nginxSiteConf already exists, skip"
        return 0
    fi

    cat > "$nginxSiteConf" <<NGINXEOF
server {
    listen 80;
    server_name $domain;

    # ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/acme-challenge;
    }

    # 其余请求重定向到HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     $certDir/${domain}.pem;
    ssl_certificate_key $certDir/${domain}.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # websocket反代到xray
    location $wsPath {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${xrayLocalPort};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 60s;
    }

    # 默认返回一个伪装页面
    location / {
        default_type text/html;
        return 200 '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works!</h1></body></html>';
    }
}
NGINXEOF

    # 移除default站点避免冲突
    rm -f /etc/nginx/sites-enabled/default

    # 启用站点
    ln -sf "$nginxSiteConf" "$nginxSiteLink"

    # 检查nginx配置
    nginx -t
    if [ $? -ne 0 ]; then
        log "nginx config test failed, exit"
        exit 1
    fi

    log "nginx config success"
    systemctl reload nginx
}

# xray模式: xray直接处理TLS
function config_xray_direct(){
    domain=${1:?"domain is required"}
    log "config xray (direct TLS mode)"

    if [ -e $vmessWebsocketConfigFile ]; then
        log "xray config file: $vmessWebsocketConfigFile already exists, skip"
        return 0
    fi

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
                    "email": "default@example.com",
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
            },
            "wsSettings": {
                "path": "$wsPath",
                "headers": {
                    "Host": "$domain"
                }
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
"api": {
    "tag": "api",
    "listen": "127.0.0.1:18080",
    "services": [
        "StatsService"
    ]
},
"stats":{},
"policy": {
    "levels": {
        "0": {
            "handshake": 3,
            "connIdle": 180,
            "statsUserUplink": true,
            "statsUserDownlink": true,
            "statsUserOnline": true
        }
    },
    "system": {
        "statsInboundUplink": true,
        "statsInboundDownlink": true,
        "statsOutboundUplink": true,
        "statsOutboundDownlink": true
    }
}
}
EOF

    print_client_config "$domain" "$uuid" 443 "tls"
}

# nginx模式: xray监听本地端口, nginx反代并处理TLS
function config_xray_nginx(){
    domain=${1:?"domain is required"}
    log "config xray (nginx reverse proxy mode)"

    if [ -e $vmessWebsocketConfigFile ]; then
        log "xray config file: $vmessWebsocketConfigFile already exists, skip"
        return 0
    fi

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
        "listen": "127.0.0.1",
        "port": $xrayLocalPort,
        "protocol": "vmess",
        "settings": {
            "clients": [
                {
                    "email": "default@example.com",
                    "id": "$uuid",
                    "alterId": 0
                }
            ]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {
                "path": "$wsPath",
                "headers": {
                    "Host": "$domain"
                }
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
"api": {
    "tag": "api",
    "listen": "127.0.0.1:18080",
    "services": [
        "StatsService"
    ]
},
"stats":{},
"policy": {
    "levels": {
        "0": {
            "handshake": 3,
            "connIdle": 180,
            "statsUserUplink": true,
            "statsUserDownlink": true,
            "statsUserOnline": true
        }
    },
    "system": {
        "statsInboundUplink": true,
        "statsInboundDownlink": true,
        "statsOutboundUplink": true,
        "statsOutboundDownlink": true
    }
}
}
EOF

    print_client_config "$domain" "$uuid" 443 "tls"
}

function print_client_config(){
    local domain=$1
    local uuid=$2
    local port=$3
    local tls=$4

    cat<<EOF2 1>&2
=========clash config segment begin=========
proxies:
    - name: "vmess_ws"
      type: vmess                # 协议类型为 VMess
      server: $domain            # 服务器地址（域名或 IP）
      port: $port                # 服务器端口，通常为 443 以使用 HTTPS 端口
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
  "port" : "$port",
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

function restart_xray(){
    systemctl daemon-reload
    systemctl restart xray@${serviceName}
    systemctl enable xray@${serviceName}
    log "restart xray success"
}

function restart_nginx(){
    nginx -t
    if [ $? -ne 0 ]; then
        log "nginx config test failed, exit"
        exit 1
    fi
    systemctl restart nginx
    systemctl enable nginx
    log "restart nginx success"
}

function install_traffic_sh(){
    log "install traffic.sh"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cp "$script_dir/../traffic.sh" /usr/local/bin/traffic.sh
    chmod +x /usr/local/bin/traffic.sh
}

# ==================== install ====================
# xray直接处理TLS模式
function install_xray_direct(){
    set -e

    email="${1:?email is required}"
    domain="${2:?domain is required}"

    require_root
    export_path
    redirect_stdout_to_file

    log "=========================================="
    log "  Mode: xray direct TLS"
    log "  Email: $email"
    log "  Domain: $domain"
    log "=========================================="

    check_os
    update_apt
    install_nslookup
    install_jq
    install_lsof
    install_ufw
    check_domain_resolve "$domain"
    set_firewall
    enable_bbr
    install_acme "$email"
    issue_cert  "$domain"
    install_xray
    config_xray_direct "$domain"
    restart_xray
    install_traffic_sh
}

# nginx反代模式
function install_nginx_proxy(){
    set -e

    email="${1:?email is required}"
    domain="${2:?domain is required}"

    require_root
    export_path
    redirect_stdout_to_file

    log "=========================================="
    log "  Mode: nginx reverse proxy TLS"
    log "  Email: $email"
    log "  Domain: $domain"
    log "=========================================="

    check_os
    update_apt
    install_nslookup
    install_jq
    install_lsof
    install_ufw
    check_domain_resolve "$domain"
    set_firewall
    enable_bbr

    # 安装nginx (需要先于acme, 因为nginx模式下用webroot方式签发证书)
    install_nginx
    install_acme "$email"
    issue_cert_nginx "$domain"

    # 安装并配置xray (监听本地端口, 不处理TLS)
    install_xray
    config_xray_nginx "$domain"
    restart_xray

    # 配置并启动nginx反代
    config_nginx "$domain"
    restart_nginx

    install_traffic_sh
}

# ==================== uninstall ====================
function uninstall_xray_direct(){
    set -e
    require_root
    log "uninstall xray direct mode"
    systemctl disable --now xray@${serviceName} 2>/dev/null || true
    rm -f $vmessWebsocketConfigFile
    rm -f /usr/local/bin/traffic.sh
    log "uninstall xray direct mode done"
}

function uninstall_nginx_proxy(){
    set -e
    require_root
    log "uninstall nginx proxy mode"

    # 停止xray实例
    systemctl disable --now xray@${serviceName} 2>/dev/null || true
    rm -f $vmessWebsocketConfigFile

    # 清理nginx配置
    rm -f "$nginxSiteLink"
    rm -f "$nginxSiteConf"
    # 如果nginx还有其他站点配置则只reload, 否则可以选择停止
    if [ -d /etc/nginx/sites-enabled ] && [ -z "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]; then
        log "no more nginx sites, stopping nginx"
        systemctl stop nginx 2>/dev/null || true
    else
        log "other nginx sites exist, just reload"
        nginx -t && systemctl reload nginx 2>/dev/null || true
    fi

    rm -f /usr/local/bin/traffic.sh
    log "uninstall nginx proxy mode done"
}

# ==================== usage ====================
function usage(){
    cat <<USAGE
Usage: $0 <command> [options]

Commands:
  install-xray   <email> <domain>   Install with xray handling TLS directly (xray listens on 443)
  install-nginx  <email> <domain>   Install with nginx reverse proxy handling TLS (nginx 443 -> xray local)
  uninstall-xray                    Uninstall xray direct mode
  uninstall-nginx                   Uninstall nginx proxy mode

Examples:
  $0 install-xray  admin@example.com  example.com
  $0 install-nginx admin@example.com  example.com
  $0 uninstall-xray
  $0 uninstall-nginx
USAGE
}

# ==================== main ====================
case $1 in
    install-xray)
        install_xray_direct "${@:2}"
        ;;
    install-nginx)
        install_nginx_proxy "${@:2}"
        ;;
    uninstall-xray)
        uninstall_xray_direct "${@:2}"
        ;;
    uninstall-nginx)
        uninstall_nginx_proxy "${@:2}"
        ;;
    *)
        usage
        ;;
esac
