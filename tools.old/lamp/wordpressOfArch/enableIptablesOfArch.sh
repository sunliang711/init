#!/bin/bash

if (($EUID!=0));then
	echo -e "Need $(tput setaf 1)root$(tput sgr0) priviledge!"
	exit 0
fi

cp /etc/iptables/empty.rules /etc/iptables/iptables.rules
systemctl enable iptables
systemctl start iptables
