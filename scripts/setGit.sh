#!/bin/bash

COMMON_LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/init-common.sh"
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE

# 显示帮助信息
show_help() {
  echo "Usage: $0 [-l LOG_LEVEL] <command>"
  echo ""
  echo "Commands:"
  for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
  done
  echo ""
  echo "Options:"
  echo "  -l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)"
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "check" "set" "unset")

check() {
    _require_commands git
}

set() {
    check

    defaultEmail="sunliang711@163.com"
    defaultUser="sunliang711"
    if command -v whiptail >/dev/null 2>&1; then
        email="$(whiptail --title 'set git email' --inputbox 'enter email address' 5 40 ${defaultEmail} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
        name="$(whiptail --title 'set git name' --inputbox 'enter name ' 5 40 ${defaultUser} 3>&1 1>&2 2>&3)"
        if [ $? -eq 0 ]; then
            echo
        else
            echo "canceled"
            return 1
        fi
    else
        read -p "git user.email: (default: ${defaultEmail}) " email
        if [[ -z "$email" ]]; then
            email="${defaultEmail}"
            echo
        fi
        read -p "git user.name: (default: ${defaultUser}) " name
        if [[ -z "$name" ]]; then
            name="${defaultUser}"
            echo
        fi
    fi

    git config --global user.email "${email}"
    git config --global user.name "${name}"
    git config --global http.postBuffer 524288000
    git config --global push.default simple
    git config --global pull.rebase false
    #save password for several minutes
    git config --global credential.helper cache
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global merge.tool vimdiff
    else
        echo "No vimdiff, so merge.tool is empty"
    fi
    # git config --global alias.tree "log --oneline --graph --decorate --all"
    git config --global alias.tree "log --pretty=format:"%Cgreen%h %Cred%d %Cblue%s %x09%Creset[%cn %cd]" --graph --date=iso"
    git config --global alias.list "config --global --list"
    if command -v nvim >/dev/null 2>&1; then
        git config --global core.editor nvim
    elif command -v vim >/dev/null 2>&1; then
        git config --global core.editor vim
    elif command -v vi >/dev/null 2>&1; then
        git config --global core.editor vi
    fi
    if command -v vimdiff >/dev/null 2>&1; then
        git config --global diff.tool vimdiff
    fi
}

unset() {
    local keys=(
        user.email
        user.name
        http.postBuffer
        push.default
        pull.rebase
        credential.helper
        merge.tool
        alias.tree
        alias.list
        core.editor
        diff.tool
    )
    local key

    for key in "${keys[@]}"; do
        git config --global --unset-all "${key}" >/dev/null 2>&1 || true
    done
}
# write your code above


# ------------------------------------------------------------

# 解析命令行参数
while getopts ":l:" opt; do
  case ${opt} in
    l )
      set_log_level "$OPTARG"
      ;;
    \? )
      show_help
      exit 1
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      show_help
      exit 1
      ;;
  esac
done
# NOTE: 这里全局使用了OPTIND，如果在某个函数中也使用了getopts，那么在函数的开头需要重置OPTIND (OPTIND=1)
shift $((OPTIND -1))

# 解析子命令
command=$1
shift

if [[ -z "$command" ]]; then
  show_help
  exit 0
fi

case "$command" in
  help)
    show_help
    ;;
  *)
    ${command} "$@"
    ;;
esac
