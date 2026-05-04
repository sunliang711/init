#!/bin/bash
red=$(tput setaf 1)
green=$(tput setaf 2)
cyan=$(tput setaf 6)
reset=$(tput sgr0)
thisDir=$(cd $(dirname ${BASH_SOURCE}) && pwd)
echo "thisDir: $thisDir"

#backup sources
user=eagle
# ip=10.1.1.3
# ip=10.1.1.241
# ip=DiskStation.local
ip=10.1.1.160
host=$user@$ip
restore=0
ignore=(@eaDir .DS_Store 电视剧)
#DSM 5.2 rsync_path
#rsync_path=/usr/syno/bin/rsync
rsync_path=/bin/rsync

cat<<-EOF
user:           $user
ip:             $ip
restore:        $restore
rsync_path:     $rsync_path
ignore files:   ${ignore[@]}
EOF

declare -A srcs=(
    [eagle]=$host:/volume2/homes/eagle
    [family]=$host:/volume2/family
    [public]=$host:/volume2/public
    # [timemachine]=$host:/volume1/timemachine
    # [paopao]=$host:/volume1/homes/paopao
    [paopao]=$host:/volume2/paopao
)
#backup destination
# dest=${thisDir}/NasBackup
dest=${PWD}/NasBackup

logdir=${thisDir}/logs
if [ ! -d $logdir ];then
    mkdir $logdir
fi
logfile="$logdir/backup.log-$(date +%Y%m%d-%H%M%S)"

#make ignore list
ignoreOption=
for ign in "${ignore[@]}";do
    ignoreOption="${ignoreOption} --exclude=$ign"
done

beep(){
    echo -ne "\007"
}

usage(){
    echo "${green}Usage${reset}: key=<key> $(basename $0) Options backupdir1 backupdir2..."
    echo
    echo "Options:"
    echo "         -n dry run mode"
    echo "         -r restore mode (default: backup mode)"
    echo
    echo "backupdirs:"
    echo "           eagle"
    echo "           family"
    echo "           public"
    echo "           paopao"
    echo
    echo "run \"ssh-keygen\" to generate ssh key"
    echo "run \"ssh-copy-id USER@HOST\" to copy id to remote server"
    exit 1
}
while getopts ":nhr" opt;do
    case "$opt" in
        h)
            usage
            ;;
        n)
            dryrun=-n
            ;;
        r)
            restore=1
            ;;
        \?)
            echo "Option \"${red}$OPTARG${reset}\" not support!!"
            usage
            ;;
    esac
done

shift $((OPTIND-1))
if [[ -z "$@" ]];then
    usage
fi
if [[ -n "$dryrun" ]];then
    echo "***${red}Dryrun mode${reset}***"
else
    echo "***${red}Not dryrun mode${reset}***"
fi
#option="-rltzv --no-p --no-g --chmod=ugo=rwX --progress --rsync-path="${rsync_path}" --delete ${dryrun}"
option="-rltv --no-p --no-g --chmod=ugo=rwX --progress --rsync-path="${rsync_path}" --delete ${dryrun}"
echo "${cyan}Logfile is : ${red}$dest/$logfile${reset}"
echo "${cyan}Back up destination: ${red}$dest${reset}"
echo "${cyan}Prepare backing up ${red}$srcs${reset} to ${red}$dest${reset}..."
beep
read -p "Press Enter to ${red}Continue${reset},^C to ${cyan}Quit${reset}..." con
echo


#begin backup
if [ ! -d "$dest" ];then
    mkdir -pv "$dest"
fi
cd "$dest"

for eachDir in "$@";do
    beep
    src=${srcs[$eachDir]}
    echo
    echo "backup $src..."
    sleep 2
    if [ $restore -eq 1 ];then
        echo "Begin restore..."
        cmd="rsync $option $ignoreOption $eachDir/ $src 2>&1 | tee -a $logfile"
    else
        echo "Begin backup..."
        cmd="rsync $option $ignoreOption $src . 2>&1 | tee -a $logfile"
    fi
    eval "${cmd}"
    if [ $? -eq 0 ];then
        curl -XPOST -d "{\"to\":\"cargocheck001@163.com\",\"subject\":\"backup complete\",\"body\":\"backup ${eachDir} completed\",\"auth_key\":\"${key}\"}" https://gitez.cc/api/mail/v1/send
    fi
done

if [ $restore -eq 1 ];then
    echo "${red}Note${reset}: fix homes/xxx permission manually after restore data."
fi
#ln -svf $logfile lastlog
