#!/bin/bash
make(){
    if [ ! -e /etc/os-release ];then
        echo "No file: /etc/os-release" 1>&2
        exit 1
    fi
    if [ ! -e /etc/apt/sources.list ];then
        echo "No file: /etc/apt/sources.list" 1>&2
        exit 1
    fi
    id=$(grep '^ID=' /etc/os-release | grep -o 'debian')
    if [[ "$id" != "debian" ]];then
        echo "Not debian" 1>&2
        exit 1
    fi
    sourcefile=${1:-/etc/apt/sources.list}
    #backup
    cp "$sourcefile" "${sourcefile}.bak"
    url=${2:-"http://mirrors.163.com"}
    codename=$(grep '^VERSION=' /etc/os-release |grep -oP '(?<=\()[^)]+')
    cat<<-EOF>$sourcefile
		deb ${url}/debian/ ${codename} main non-free contrib
		deb ${url}/debian/ ${codename}-updates main non-free contrib
		deb ${url}/debian/ ${codename}-backports main non-free contrib
		deb-src ${url}/debian/ ${codename} main non-free contrib
		deb-src ${url}/debian/ ${codename}-updates main non-free contrib
		deb-src ${url}/debian/ ${codename}-backports main non-free contrib
		deb ${url}/debian-security/ ${codename}/updates main non-free contrib
		deb-src ${url}/debian-security/ ${codename}/updates main non-free contrib
	EOF
}
make
echo "Run \"apt-get update\" to update source list"
