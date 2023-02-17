#tested on debian 8.8
apt-get update
apt-get install apache2 php5 mysql-server
mysql_secure_installation
apt-get install phpmyadmin
a2enmod rewrite

service apache2 restart
echo '<?php phpinfo();?>'>/var/www/html/info.php

#config phpmyadmin
cp /etc/phpmyadmin/config.inc.php{,.bak}
sed -ri 's=([ ]+)//(.+AllowNoPassword.+)=\1\2=' /etc/phpmyadmin/config.inc.php

echo 'Include /etc/phpmyadmin/apache.conf' >> /etc/apache2/apache2.conf
service apache2 restart

#如果运行wordpress的时候主页可以打开，其他页面打不开
#在wordpress后台-设置-固定链接 使用自定义结构的时候会出现，把固定链接设置成『默认』方式即可
#或者如果非要用自定义结构的话，则有两个地方要设置
#1.要启用rewrite模块，通过a2enmod rewrite命令
#2.在/etc/apache2/apache2.conf中
#  把<Directory /var/www/>里面的AllowOverride None改成AllowOverride All

#Note
#别忘了把网站目录所有权改成www-data
#chown -R www-data:www-data /var/www/html/example.com
