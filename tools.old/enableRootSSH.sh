#!/bin/bash
config=/etc/ssh/sshd_config
cp -v $config{,.bak}
#sed  -i -e 's/^PermitRootLogin without-password/#&/p' -e '/^#PermitRootLogin without-password/a PermitRootLogin yes' $config

sed -i 's/^PermitRootLogin without-password/PermitRootLogin yes/' $config
