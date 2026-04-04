#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/init-common.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE SCRIPT_DIR

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "install" "uninstall" "check" "update")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    _show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

thisScript="${SCRIPT_DIR}/updateInit.sh"
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
    _require_commands crontab git
}

update() {
    if git -C "${INIT_REPO_ROOT}" diff-index --quiet HEAD --; then
        echo "the repo is clean. git pull --ff-only.."
        git -C "${INIT_REPO_ROOT}" pull --ff-only
    else
        echo "the repo has changes."
    fi
}


_dispatch_cli show_help _resolve_cli_handler "$@"
