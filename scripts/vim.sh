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
COMMANDS=("help" "check" "global" "user")


globalPath=/etc/vim/vimrc.local
macOSGlobalPath=/usr/share/vim/vimrc
userPath="${INIT_TARGET_HOME}/.vimrc"
sourceVimrc="${this}/vimrc"
nerdtreePath="${INIT_TARGET_HOME}/.vim/pack/vendor/start/nerdtree"
nerdtreeRepo="https://github.com/preservim/nerdtree.git"

_git_remote_matches() {
    local repo_dir="${1:?missing repo dir}"
    local expected_remote="${2:?missing expected remote}"
    local current_remote

    [ -d "${repo_dir}/.git" ] || return 1
    current_remote="$(git -C "${repo_dir}" config --get remote.origin.url 2>/dev/null)"
    [ "${current_remote}" = "${expected_remote}" ]
}

check() {
    errorCount=0

    _require_commands vim
}

global() {
    case "$(uname)" in
    Darwin)
        if [ ! -e ${macOSGlobalPath}.orig ]; then
            _runAsRoot cp ${macOSGlobalPath} ${macOSGlobalPath}.orig
        fi
        log INFO "Copy vimrc to ${macOSGlobalPath}"
        _runAsRoot cp vimrc ${macOSGlobalPath}
        ;;
    Linux)
        log INFO "Copy vimrc to ${globalPath}"
        _runAsRoot cp vimrc ${globalPath}
        ;;
    esac
}

user() {
    log INFO "Copy vimrc to $userPath"
    if [ -f "${userPath}" ] && ! _files_match "${userPath}" "${sourceVimrc}" ; then
        _backup_existing_path "${userPath}"
    fi
    if [ ! -f "${userPath}" ] || ! _files_match "${userPath}" "${sourceVimrc}" ; then
        cp "${sourceVimrc}" "${userPath}"
    fi

    log INFO "install nerdtree plugin.."
    # requrie vim 8+
    if [ ! -d "${nerdtreePath}" ]; then
        _ensure_parent_dir "${nerdtreePath}"
        git clone "${nerdtreeRepo}" "${nerdtreePath}"
    elif _git_remote_matches "${nerdtreePath}" "${nerdtreeRepo}"; then
        log INFO "nerdtree already exists at ${nerdtreePath}, skip clone"
    else
        log WARNING "${nerdtreePath} exists and is not the expected nerdtree repo, skip clone"
    fi

    if [ -d "${nerdtreePath}/doc" ]; then
        vim -Nu NONE -n -es -c "helptags ${nerdtreePath}/doc" -c q
    fi

    log SCUCESS "Done"
}


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
