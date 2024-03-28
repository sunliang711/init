#!/bin/bash
#
baseUrl="/etc/letsencrypt/live/sh.gitez.cc"
cert="fullchain.pem"
key="privkey.pem"
remoteCert="$baseUrl/$cert"
remoteKey="$baseUrl/$key"
remoteHost=aliyun.gitez.cc
remotePort=2000
# 需要使用root权限拷贝，如果root账户没有配置，则使用sudo passwd root给root配置密码
remoteUser=root

echo "download cert.."
set -x
scp -P $remotePort $remoteUser@$remoteHost:$remoteCert .
scp -P $remotePort $remoteUser@$remoteHost:$remoteKey .
set +x


base="/etc/pve/nodes/pve"
localCert="$base/pveproxy-ssl.pem"
localKey="$base/pveproxy-ssl.key"

echo "backup old local certs.."
suffix=$(date +%FT%T)
set -x
# backup
cp "${localCert}" "${localCert}.${suffix}"
cp "${localKey}" "${localKey}.${suffix}"
set +x

echo "replace with new certs.."
set -x
systemctl stop pveproxy.service
install -m 640 -g www-data $cert $localCert
install -m 640 -g www-data $key $localKey
systemctl start pveproxy.service
set +x

rm -rf $cert
rm -rf $key




exit
echo "restart pveproxy service.."
systemctl restart pveproxy

