#!/bin/bash
if (($EUID!=0));then
    echo -e "Need $(tput setaf 1)root$(tput sgr0) priviledge!$(tput setaf 1)\u2717"
    exit 1
fi

rm /tmp/latest.tar.gz >/dev/null 2>&1
rm -rf /var/www/html/wordpress >/dev/null 2>&1

wget https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
tar -C /var/www/html -xzvf /tmp/latest.tar.gz
chown -R www-data:www-data /var/www/html/wordpress

cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/wordpress.conf
sed -i '/<VirtualHost/a	ServerName eaagle.me' /etc/apache2/sites-available/wordpress.conf
sed -i '/<VirtualHost/a	ServerAlias www.eaagle.me' /etc/apache2/sites-available/wordpress.conf
sed -i 's+.*DocumentRoot .*+	DocumentRoot /var/www/html/wordpress+' /etc/apache2/sites-available/wordpress.conf
a2ensite wordpress.conf
#reboot apache
service apache2 restart

echo "create database for wordpress manually"
echo "for example: mysql -u root -p"
echo " then : create database wordpress;"
