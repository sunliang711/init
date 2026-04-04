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
COMMANDS=("help" "install" "uninstall" "check" "update")

thisScript="${this}/updateInit.sh"
cronLine="0 0 * * * ${thisScript} update >/dev/null 2>&1"
# install to crontab
install() {
    local existing_crontab
    existing_crontab="$(crontab -l 2>/dev/null || true)"

    if printf '%s\n' "${existing_crontab}" | grep -Fqx "${cronLine}"; then
        echo "update crontab already exists"
        return 0
    fi

    (
        printf '%s\n' "${existing_crontab}"
        echo "${cronLine}"
    ) | sed '/^$/d' | crontab -
}

uninstall() {
    local existing_crontab
    existing_crontab="$(crontab -l 2>/dev/null || true)"
    [ -n "${existing_crontab}" ] || return 0

    printf '%s\n' "${existing_crontab}" | grep -Fvx "${cronLine}" | crontab -
}

check() {
    _require_commands crontab
}

update() {
    repo=${home}/.local/apps/init
    cd ${repo}
    if git diff-index --quiet HEAD --; then
        echo "the repo is clean. git pull.."
        git pull
    else
        echo "the repo has changes."
    fi
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
