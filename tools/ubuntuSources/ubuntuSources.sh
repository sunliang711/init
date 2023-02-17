#!/bin/bash

if [ $EUID -ne 0 ];then
    echo "Need run as root!"
    exit 1
fi
usage(){
    cat<<-EOF
		Usage: $(basename $0) Options

		Options:
		        -h        print this message
		        -o        outputfile [default is /etc/apt/sources.list]
		        -u        url of source [default is http://mirrors.163.com/ubuntu/]
EOF
    exit 1
}

defaultOutput="/etc/apt/sources.list"
defaultUrl="http://mirrors.163.com/ubuntu/"
url="$defaultUrl"
output="$defaultOutput"
while getopts ":ho:u:" opt ;do
    case "$opt" in
        h)
            usage
            ;;
        o)
            output=$OPTARG
            ;;
        u)
            url=$OPTARG
            ;;
        :)
            if [[ "$OPTARG" == "o" ]];then
                echo "'-o' option no argument,using default value: $defaultOutput"
                output=$defaultOutput
            elif [[ "$OPTARG" == "u" ]];then
                echo "'-u' option no argument,using default value: $defaultUrl"
                url=$defaultUrl
            else
                echo "Unknown option $OPTARG"
                echo
                usage
            fi
            ;;
        \?)
            usage
            ;;
        *)
            usage
            ;;
    esac
done
make(){
    if [[ ! -f /etc/os-release ]];then
        echo "No file /etc/os-release!" 1>&2
        exit 1
    fi
    #check id
    id=$(grep '^ID' /etc/os-release |grep -oP '(?<=ID=)[^=]+')
    if [[ "$id" != "ubuntu" ]] ;then
        echo "Not ubuntu" 1>&2
        exit 1
    fi
    declare -A release2codename
    release2codename=(
        ["10.04"]=lucid
        ["10.10"]=maverick
        ["11.04"]=natty
        ["11.10"]=oneiric
        ["12.04"]=precise
        ["12.10"]=quantal
        ["13.04"]=raring
        ["13.10"]=saucy
        ["14.04"]=trusty
        ["14.10"]=utopic
        ["15.04"]=vivid
        ["15.10"]=wily
        ["16.04"]=xenial
        ["16.10"]=yakkety
        ["17.04"]=zesty
        ["17.10"]=artful
        ["18.04"]=bionic
        )
    codename=$(grep -oP '(?<=DISTRIB_CODENAME=)[^=]+' /etc/lsb-release)
    #if cannot find codename,then use find release to find it
    if [[ -z "$codename" ]];then
        release=$(grep -oP '(?<=DISTRIB_RELEASE=)[^=]+' /etc/lsb-release)
        codename="${release2codename[$release]}"
    fi

    type=(security updates proposed backports)
    tmpoutput=/tmp/sources.list
    echo "deb $url $codename main restricted universe multiverse" > "$tmpoutput"
    echo "deb-src $url $codename main restricted universe multiverse">> "$tmpoutput"
    for t in "${type[@]}";do
        echo "deb $url $codename-$t main restricted universe multiverse" >> "$tmpoutput"
        echo "deb-src $url $codename-$t main restricted universe multiverse" >> "$tmpoutput"
    done
    #backup
    if [[ -e "$output" ]];then
        cp "${output}" "${output}.backup"
    fi
    #cat "$tmpoutput"
    if [[ -n "$output" ]];then
        echo "Write to $output..."
        mv "$tmpoutput" $output
        echo "Done."
    fi
    # echo "Run \"apt-get update\" to update source list" 1>&2
    apt-get update
}
make
