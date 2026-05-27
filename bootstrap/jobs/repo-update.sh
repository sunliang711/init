#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_LIB="${SCRIPT_DIR}/../lib/runtime.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=../lib/runtime.sh
source "${RUNTIME_LIB}"
unset RUNTIME_LIB INIT_CALLER_SOURCE

# ------------------------------------------------------------
# 子命令数组
# shellcheck disable=SC2034
COMMANDS=("help" "install" "uninstall" "check" "update")
# shellcheck disable=SC2034
HELP_OPTIONS=("-l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)")

show_help() {
    show_standard_help "$0 [-l LOG_LEVEL] <command>" COMMANDS HELP_OPTIONS
}

JOB_SCRIPT_PATH="${INIT_REPO_ROOT}/bootstrap/jobs/repo-update.sh"
CRON_LINE="0 0 * * * ${JOB_SCRIPT_PATH} update >/dev/null 2>&1"
LEGACY_CRON_LINE_BROKEN="0 0 * * * /repo-update.sh update >/dev/null 2>&1"
LEGACY_CRON_LINE_OLD_PATH="0 0 * * * ${INIT_REPO_ROOT}/tools/updateInit.sh update >/dev/null 2>&1"
LAUNCH_AGENT_LABEL="local.init.repo-update"
LAUNCH_AGENT_PATH="${INIT_TARGET_HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

# 转义 plist XML 文本节点中的特殊字符，避免路径包含特殊字符时生成无效 plist。
xml_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

filter_repo_update_crontab_lines() {
    grep -Fvx "${CRON_LINE}" | grep -Fvx "${LEGACY_CRON_LINE_BROKEN}" | grep -Fvx "${LEGACY_CRON_LINE_OLD_PATH}" || true
}

# install to crontab
install_crontab() {
    local existing_crontab
    existing_crontab="$(crontab -l 2>/dev/null || true)"

    if printf '%s\n' "${existing_crontab}" | grep -Fqx "${CRON_LINE}"; then
        echo "update crontab already exists"
        return 0
    fi

    (
        printf '%s\n' "${existing_crontab}" | filter_repo_update_crontab_lines
        echo "${CRON_LINE}"
    ) | sed '/^$/d' | crontab -
}

uninstall_crontab() {
    local existing_crontab
    existing_crontab="$(crontab -l 2>/dev/null || true)"
    [ -n "${existing_crontab}" ] || return 0

    printf '%s\n' "${existing_crontab}" | filter_repo_update_crontab_lines | crontab -
}

# 生成当前目标用户的 launchd domain，供 macOS 用户级 LaunchAgent 使用。
launchctl_domain() {
    local uid
    uid="$(id -u "${INIT_TARGET_USER}" 2>/dev/null || id -u)"
    printf 'gui/%s\n' "${uid}"
}

# 写入 macOS LaunchAgent plist，保持与原 cron 一样每天 00:00 执行。
write_launch_agent_plist() {
    local job_script_path_xml
    local repo_root_xml

    job_script_path_xml="$(printf '%s' "${JOB_SCRIPT_PATH}" | xml_escape)"
    repo_root_xml="$(printf '%s' "${INIT_REPO_ROOT}" | xml_escape)"

    ensure_dir "$(dirname "${LAUNCH_AGENT_PATH}")"
    cat >"${LAUNCH_AGENT_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${job_script_path_xml}</string>
        <string>update</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>0</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>WorkingDirectory</key>
    <string>${repo_root_xml}</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
    chmod 644 "${LAUNCH_AGENT_PATH}"
}

# 在 macOS 上安装用户级 LaunchAgent，并清理本仓库历史 cron 行。
install_launch_agent() {
    local domain

    write_launch_agent_plist
    domain="$(launchctl_domain)"
    launchctl bootout "${domain}" "${LAUNCH_AGENT_PATH}" >/dev/null 2>&1 || true
    launchctl enable "${domain}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "${domain}" "${LAUNCH_AGENT_PATH}"

    if command_exists crontab; then
        uninstall_crontab
    fi
}

# 在 macOS 上卸载用户级 LaunchAgent，同时清理旧 cron 行。
uninstall_launch_agent() {
    local domain

    domain="$(launchctl_domain)"
    if [ -f "${LAUNCH_AGENT_PATH}" ]; then
        launchctl bootout "${domain}" "${LAUNCH_AGENT_PATH}" >/dev/null 2>&1 || true
        launchctl disable "${domain}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
        case "${LAUNCH_AGENT_PATH}" in
        "${INIT_TARGET_HOME}/Library/LaunchAgents/"*.plist)
            rm -f "${LAUNCH_AGENT_PATH}"
            ;;
        esac
    fi

    if command_exists crontab; then
        uninstall_crontab
    fi
}

# 按系统选择调度器，macOS 使用 launchd，其他系统保持 crontab。
install() {
    case "$(uname -s)" in
    Darwin)
        install_launch_agent
        ;;
    *)
        install_crontab
        ;;
    esac
}

# 按系统选择卸载方式，macOS 额外兼容清理历史 cron 行。
uninstall() {
    case "$(uname -s)" in
    Darwin)
        uninstall_launch_agent
        ;;
    *)
        uninstall_crontab
        ;;
    esac
}

check() {
    case "$(uname -s)" in
    Darwin)
        require_commands git launchctl sed
        ;;
    *)
        require_commands crontab git
        ;;
    esac
}

update() {
    if git -C "${INIT_REPO_ROOT}" diff-index --quiet HEAD --; then
        echo "the repo is clean. git pull --ff-only.."
        git -C "${INIT_REPO_ROOT}" pull --ff-only
    else
        echo "the repo has changes."
    fi
}


dispatch_cli show_help resolve_cli_handler "$@"
unset SCRIPT_DIR
