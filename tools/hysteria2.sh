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

	configFile="/etc/hysteria/config.yaml"
    log "generate config file to $configFile"
    cat<<EOF>$configFile
listen: :443

acme:
  domains:
    - ${domain}
  email: ${email}


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

    cat<<EOF2 1>&2
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
EOF2

cat<<EOF3 1>&2
=========shadowrocket config begin=========
TODO
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
	  systemctl restart hysteria-server
  }

set -e

domain=${1:?'missing domain'}
email=${2:?'missing email'}

require_root
export_path
redirect_stdout_to_file
update_apt
check_os
install_jq
install_ufw
install_lsof
set_firewall
enable_bbr
install_h2
config_h2 $domain $email
restart
