#!/bin/bash
if (($EUID != 0));then
    echo -e "Need $(tput setaf 1)root$(tput sgr0) priviledge!$(tput setaf 1)\u2717"
    exit 1
fi

if ! command -v pacman>/dev/null 2>&1;then
    echo "Only works in ArchLinux!"
    exit 1
fi

pacman -Syu --noconfirm
pacman -S nginx-mainline --noconfirm --needed
pacman -S mariadb --noconfirm --needed
pacman -S php-fpm --noconfirm --needed

mysql_install_db --user=mysql  --basedir=/usr --datadir=/var/lib/mysql
systemctl start mysqld
cat>mysql_secure_installation.sh<<'EOF'
#!/bin/bash
read -p "Input new password for root: " passwd
sudo mysql_secure_installation<<end

y
$passwd
$passwd
y
y
y
y
end
EOF
bash mysql_secure_installation.sh
rm mysql_secure_installation.sh

mv /etc/nginx/nginx.conf{,.bak}
cp ./nginx.conf /etc/nginx/nginx.conf

systemctl restart nginx php-fpm mysqld
