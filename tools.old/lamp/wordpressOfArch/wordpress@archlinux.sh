#!/bin/bash

#pull mysql
echo "pull mysql"
docker pull mysql

#pull wordpress
echo "pull wordpress"
docker pull sunliang711/wordpress

#pull data
echo "pull data"
docker pull sunliang711/data

./createContainer.sh
