#!/bin/bash
if (($EUID!=0));then
    echo "Run as root."
    exit 1
fi
NOPASS=nopass
if ! grep -qE '^#includedir /etc/sudoers.d$' /etc/sudoers;then
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
fi

if ! grep -qE "^$NOPASS:" /etc/group;then
    groupadd $NOPASS
fi

cat<<EOF>/etc/sudoers.d/custom-sudoers
%$NOPASS ALL=(ALL:ALL) NOPASSWD:ALL
EOF

user=${SUDO_USER:-$(whoami)}
echo -n "add \"$user\" to group \"$NOPASS\" to permit no password permission?[y/N] "
read xx
if [[ $xx =~ [yY] ]];then
    usermod -aG $NOPASS $user
else
    echo -n "add who to group \"$NOPASS\"? (empty to quit) "
    read yy
    if [ -n "$yy" ];then
        if ! grep -qE "^$yy:" /etc/passwd;then
            echo "user: \"$yy\" not exist."
            exit 1
        fi
        usermod -aG $NOPASS $yy
    fi
fi
