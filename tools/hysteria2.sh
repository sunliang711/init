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

function check_domain_resole(){
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
    file_name=/tmp/hysteria.log
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

function set_firewall() {
    sshd_port=$(find_sshd_port)
    if [ -z "$sshd_port" ]; then
        log "sshd port not found, exit"
        exit 1
    fi
    log "allow ssh port $sshd_port"
    ufw allow $sshd_port/tcp

    log "allow http port 80"
	ufw allow 80/tcp

    log "allow udp port 443"
    ufw allow 443/udp

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

    if [ ! -e /root/.acme.sh/${domain}_ecc/${domain}.cer ]; then
        log "issue cert for $domain"
        # ufw allow 80/tcp
        /root/.acme.sh/acme.sh --issue -d "$domain" --standalone
    else
        log "cert issued, skip"
    fi


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


function install_h2(){
	if [ -e /usr/local/bin/hysteria ]; then
		log "hysteria already installed, skip"
		return 0
	fi

    log "install hysteria"
    bash <(curl -fsSL https://get.hy2.sh/)

    if [ ! -e /usr/local/bin/hysteria ]; then
		log "hysteria install failed, exit"
		exit 1
	fi
}

function config_h2(){
	domain=${1:?'missing domain'}
	email=${2:?'missing email'}
    # withAcme=${3:-false}
    # TODO 暂时不支持自动配置acme，因为生成的证书会有权限问题，以后修复
    withAcme=false

	configFile="/etc/hysteria/config.yaml"
    log "generate config file to $configFile"
    cat<<EOF>$configFile
listen: :443

auth:
  # type: password
  # password: 87ccaaCff3
  type: userpass
  userpass:
      user1: password1
      user2: password2

masquerade:
  type: proxy
  proxy:
    url: https://microsoft.com
    rewriteHost: true

ignoreClientBandwidth: true


sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,8000-9000
  udpPorts: all

# 流量统计
trafficStats:
  listen: 127.0.0.1:9999
  # secret: some_secret
EOF

    if [ "$withAcme" = true ]; then
        cat<<EOF2>>$configFile
tls:
  cert: /root/certs/${domain}.pem
  key: /root/certs/${domain}.key
  # sniGuard: strict | disable | dns-san
  sniGuard: disable
# acme:
#   domains:
#     - ${domain}
#   email: ${email}
EOF2
    else
        cat<<EOF3>>$configFile
# tls:
#   cert: /root/certs/${domain}.pem
#   key: /root/certs/${domain}.key
#   # sniGuard: strict | disable | dns-san
#   sniGuard: disable
acme:
  domains:
    - ${domain}
  email: ${email}
EOF3
    fi


    cat<<EOF20 1>&2
=========clash config segment begin=========
proxies:
- name: hy2
  type: hysteria2
  server: ${domain}
  port: 443
  password: user1:password1
  sni: ''
  skip-cert-verify: true
=========clash config segment end=========
EOF20

cat<<EOF30 1>&2
=========shadowrocket config begin=========
TODO
=========shadowrocket config end=========
EOF30

cat<<EOF40 1>&2
=========xray client config begin=========
TODO
=========xray client config end=========
EOF40

}

function restart(){
  systemctl daemon-reload
  systemctl restart hysteria-server
  systemctl enable hysteria-server
  log "restart hysteria success"
}

set -e

domain=${1:?'missing domain'}
email=${2:?'missing email'}
withAcme=${3:?'missing withAcme: true | false'}
certDir=/root/certs

require_root
export_path
redirect_stdout_to_file
check_os
check_domain_resole "$domain"
update_apt
install_jq
install_ufw
install_lsof
set_firewall
enable_bbr
if [ "$withAcme" = true ]; then
    install_acme "$email"
    issue_cert "$domain"
fi
install_h2
config_h2 $domain $email $withAcme
restart
