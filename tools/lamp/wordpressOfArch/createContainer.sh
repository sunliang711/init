
#start data
docker run -d --name data-one sunliang711/data tail -f /dev/null

#start mysql
docker run -d --name mysql-one --volumes-from data-one -e MYSQL_ROOT_PASSWORD=sl580226 mysql

#start wordpress
docker run -d --name wordpress-one --volumes-from data-one --link mysql-one:mysql -p 80 sunliang711/wordpress
