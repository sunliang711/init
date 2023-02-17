#!/bin/bash
if (($EUID!=0));then
    echo "Need root privilege!"
    exit 1
fi
ehco "Only tested on Debian 8"

echo "install ssmtp..."
apt install -y ssmtp || { echo "Install ssmtp failed!"; exit 1; }

mv /etc/ssmtp/ssmtp.conf{,.bak}

read -p "Enter smtp user email (for example: xxx@163.com)" root
read -p "Enter smtp host (for example:smtp.163.com:465): " smtpHost
read -p "Enter password of your smtp: " authPass

rewriteDomain=$(echo "$root" | grep -oP '(?<=@).+')
authUser=$(echo "$root" | grep -oP '.+(?=@)')

cat > /etc/ssmtp/ssmtp.conf<<EOF
root=$root
mailhub=$smtpHost
rewriteDomain=$rewriteDomain
AuthUser=$authUser
AuthPass=$authPass
FromLineOverride=YES
UseTLS=YES
EOF
