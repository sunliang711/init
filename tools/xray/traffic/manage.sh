#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${XRAY_TRAFFIC_HOME:-/opt/xray-traffic}"
BIN_DIR=""
CONFIG_DIR=""
DATA_DIR=""
LOG_DIR=""
CONFIG_FILE=""
PY_TARGET=""
OLD_PY_TARGET=""
MANAGE_TARGET=""
LOCAL_BIN_DIR="/usr/local/bin"
PY_LINK="${LOCAL_BIN_DIR}/xray-traffic"
OLD_PY_LINK="${LOCAL_BIN_DIR}/xray_traffic.py"
SYSTEMD_DIR="/etc/systemd/system"
HOURLY_SERVICE="xray-traffic-hourly.service"
HOURLY_TIMER="xray-traffic-hourly.timer"
DAILY_SERVICE="xray-traffic-daily.service"
DAILY_TIMER="xray-traffic-daily.timer"
DEFAULT_XRAY_BIN="/usr/local/bin/xray"
DEFAULT_INSTANCES="default=127.0.0.1:18080"
DEFAULT_RETENTION_DAYS="180"
DEFAULT_TIMEZONE="Asia/Shanghai"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
PYTHON_BIN="$(command -v python3 || true)"

log_info() {
    # 输出普通流程日志，适用于安装、更新和卸载过程定位。
    printf 'INFO %s\n' "$*" >&2
}

log_warn() {
    # 输出非阻断告警，适用于依赖缺失但不影响安装文件落地的场景。
    printf 'WARN %s\n' "$*" >&2
}

die() {
    # 输出错误并退出，适用于前置检查失败和危险路径拦截。
    printf 'ERROR %s\n' "$*" >&2
    exit 1
}

usage() {
    # 输出管理脚本帮助，适用于手工安装、更新和卸载。
    cat <<'EOF'
Usage:
  manage.sh install [--py /path/to/xray-traffic]
  manage.sh update [--py /path/to/xray-traffic]
  manage.sh uninstall [--purge]
  manage.sh status
  manage.sh help

Environment:
  XRAY_TRAFFIC_HOME  Install directory, default /opt/xray-traffic

Installed timers:
  collect hourly --instance ALL
  collect daily --instance ALL
EOF
}

require_root() {
    # 检查 root 权限，适用于需要写 /opt 和 /etc/systemd/system 的操作。
    if [ "${EUID}" -ne 0 ]; then
        die "This command must be run as root"
    fi
}

require_command() {
    # 检查必要命令是否存在，适用于安装前置依赖校验。
    local command_name="$1"
    command -v "${command_name}" >/dev/null 2>&1 || die "Missing required command: ${command_name}"
}

check_python_version() {
    # 检查 Python 版本，xray-traffic 依赖 Python 3.9+ 标准库 zoneinfo。
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' ||
        die "Python 3.9 or newer is required"
}

refresh_app_paths() {
    # 根据规范化后的 APP_DIR 刷新派生路径，避免校验路径和实际操作路径不一致。
    BIN_DIR="${APP_DIR}/bin"
    CONFIG_DIR="${APP_DIR}/config"
    DATA_DIR="${APP_DIR}/data"
    LOG_DIR="${APP_DIR}/logs"
    CONFIG_FILE="${CONFIG_DIR}/xray-traffic.env"
    PY_TARGET="${BIN_DIR}/xray-traffic"
    OLD_PY_TARGET="${BIN_DIR}/xray_traffic.py"
    MANAGE_TARGET="${APP_DIR}/manage.sh"
}

validate_app_dir() {
    # 规范化并限制安装目录必须位于 /opt 子目录，避免卸载时误删系统路径。
    [ -n "${APP_DIR}" ] || die "APP_DIR must not be empty"
    [ -n "${PYTHON_BIN}" ] || die "Missing required command: python3"

    APP_DIR="$("${PYTHON_BIN}" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${APP_DIR}")" ||
        die "Failed to normalize APP_DIR: ${APP_DIR}"

    case "${APP_DIR}" in
    /opt/*) ;;
    *) die "APP_DIR must be under /opt: ${APP_DIR}" ;;
    esac

    if [ "${APP_DIR}" = "/opt" ] || [ "${APP_DIR}" = "/opt/" ]; then
        die "Refuse to use unsafe APP_DIR: ${APP_DIR}"
    fi

    refresh_app_paths
}

read_env_value() {
    # 从 KEY=VALUE 配置文件读取单个值，适用于检查已安装配置。
    local key="$1"
    local default_value="$2"

    if [ ! -f "${CONFIG_FILE}" ]; then
        printf '%s\n' "${default_value}"
        return 0
    fi

    local line
    line="$(grep -E "^${key}=" "${CONFIG_FILE}" | tail -n 1 || true)"
    if [ -z "${line}" ]; then
        printf '%s\n' "${default_value}"
        return 0
    fi
    printf '%s\n' "${line#*=}" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

resolve_source_py() {
    # 解析 Python 源文件路径，适用于从仓库安装或显式指定更新文件。
    local source_py="$1"

    if [ -n "${source_py}" ]; then
        [ -f "${source_py}" ] || die "Python source file not found: ${source_py}"
        printf '%s\n' "${source_py}"
        return 0
    fi

    if [ -f "${SCRIPT_DIR}/xray-traffic" ]; then
        printf '%s\n' "${SCRIPT_DIR}/xray-traffic"
        return 0
    fi

    die "Python source file not found. Use --py /path/to/xray-traffic"
}

ensure_directories() {
    # 创建 /opt 下的程序、配置、数据和日志目录。
    install -d -m 0755 "${APP_DIR}"
    install -d -m 0755 "${BIN_DIR}"
    install -d -m 0750 "${CONFIG_DIR}"
    install -d -m 0750 "${DATA_DIR}"
    install -d -m 0750 "${LOG_DIR}"
}

install_config_if_missing() {
    # 首次安装时创建默认配置，更新时不覆盖用户已有配置。
    if [ -f "${CONFIG_FILE}" ]; then
        log_info "Keep existing config: ${CONFIG_FILE}"
        return 0
    fi

    umask 077
    cat >"${CONFIG_FILE}" <<EOF
XRAY_TRAFFIC_INSTANCES=${DEFAULT_INSTANCES}
XRAY_BIN=${DEFAULT_XRAY_BIN}
XRAY_TRAFFIC_DB=${DATA_DIR}/traffic.db
XRAY_TRAFFIC_RETENTION_DAYS=${DEFAULT_RETENTION_DAYS}
XRAY_TRAFFIC_TIMEZONE=${DEFAULT_TIMEZONE}
XRAY_TRAFFIC_TIMEOUT_SECONDS=30
EOF
    chmod 0600 "${CONFIG_FILE}"
    log_info "Config created: ${CONFIG_FILE}"
}

copy_python_file() {
    # 复制 Python 主脚本，适用于安装和只更新主命令文件。
    local source_py="$1"
    local resolved_source
    resolved_source="$(resolve_source_py "${source_py}")"

    install -m 0755 "${resolved_source}" "${PY_TARGET}"
    log_info "Command file installed: ${PY_TARGET}"
}

copy_manage_file() {
    # 复制管理脚本到 /opt，方便后续在目标机查看状态或卸载。
    if [ "${SCRIPT_PATH}" = "${MANAGE_TARGET}" ]; then
        return 0
    fi
    install -m 0755 "${SCRIPT_PATH}" "${MANAGE_TARGET}"
    log_info "Manager installed: ${MANAGE_TARGET}"
}

install_python_link() {
    # 创建 /usr/local/bin 软链接，适用于安装和更新后直接执行命令。
    local existing_target=""

    install -d -m 0755 "${LOCAL_BIN_DIR}"
    if [ -e "${PY_LINK}" ] && [ ! -L "${PY_LINK}" ]; then
        die "Refuse to overwrite non-symlink: ${PY_LINK}"
    fi

    if [ -L "${PY_LINK}" ]; then
        existing_target="$(readlink "${PY_LINK}" || true)"
        if [ "${existing_target}" != "${PY_TARGET}" ]; then
            log_warn "Replace existing symlink: ${PY_LINK} -> ${existing_target}"
        fi
    fi

    ln -sfn "${PY_TARGET}" "${PY_LINK}"
    log_info "Python symlink installed: ${PY_LINK} -> ${PY_TARGET}"
}

remove_python_link() {
    # 删除由本脚本管理的 /usr/local/bin 软链接，避免误删用户文件。
    local existing_target=""

    if [ ! -e "${PY_LINK}" ] && [ ! -L "${PY_LINK}" ]; then
        return 0
    fi
    if [ ! -L "${PY_LINK}" ]; then
        log_warn "Keep non-symlink file: ${PY_LINK}"
        return 0
    fi

    existing_target="$(readlink "${PY_LINK}" || true)"
    if [ "${existing_target}" != "${PY_TARGET}" ]; then
        log_warn "Keep unmanaged symlink: ${PY_LINK} -> ${existing_target}"
        return 0
    fi

    rm -f "${PY_LINK}"
    log_info "Python symlink removed: ${PY_LINK}"
}

remove_legacy_python_entry() {
    # 清理旧文件名的受管入口，避免更新后留下过期命令。
    local existing_target=""

    if [ -L "${OLD_PY_LINK}" ]; then
        existing_target="$(readlink "${OLD_PY_LINK}" || true)"
        if [ "${existing_target}" = "${OLD_PY_TARGET}" ] || [ "${existing_target}" = "${PY_TARGET}" ]; then
            rm -f "${OLD_PY_LINK}"
            log_info "Legacy Python symlink removed: ${OLD_PY_LINK}"
        else
            log_warn "Keep unmanaged legacy symlink: ${OLD_PY_LINK} -> ${existing_target}"
        fi
    elif [ -e "${OLD_PY_LINK}" ]; then
        log_warn "Keep non-symlink legacy file: ${OLD_PY_LINK}"
    fi

    if [ -e "${OLD_PY_TARGET}" ] || [ -L "${OLD_PY_TARGET}" ]; then
        rm -f "${OLD_PY_TARGET}"
        log_info "Legacy Python file removed: ${OLD_PY_TARGET}"
    fi
}

warn_xray_binary() {
    # 检查配置中的 xray 路径，缺失时提示但不阻断安装。
    local xray_bin
    xray_bin="${XRAY_BIN:-$(read_env_value XRAY_BIN "${DEFAULT_XRAY_BIN}")}"
    if [ ! -x "${xray_bin}" ]; then
        log_warn "Xray binary is not executable: ${xray_bin}"
    fi
}

write_systemd_units() {
    # 写入 systemd service 和 timer，适用于自动小时采集和每日聚合。
    [ -n "${PYTHON_BIN}" ] || die "Missing required command: python3"

    cat >"${SYSTEMD_DIR}/${HOURLY_SERVICE}" <<EOF
[Unit]
Description=Xray traffic hourly snapshot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${CONFIG_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=${PYTHON_BIN} ${PY_TARGET} --config ${CONFIG_FILE} collect hourly --instance ALL
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
EOF

    cat >"${SYSTEMD_DIR}/${HOURLY_TIMER}" <<'EOF'
[Unit]
Description=Run Xray traffic hourly snapshot

[Timer]
OnCalendar=*-*-* *:00:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    cat >"${SYSTEMD_DIR}/${DAILY_SERVICE}" <<EOF
[Unit]
Description=Xray traffic daily aggregation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${CONFIG_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=${PYTHON_BIN} ${PY_TARGET} --config ${CONFIG_FILE} collect daily --instance ALL
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}
EOF

    cat >"${SYSTEMD_DIR}/${DAILY_TIMER}" <<'EOF'
[Unit]
Description=Run Xray traffic daily aggregation

[Timer]
OnCalendar=*-*-* 00:10:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    chmod 0644 \
        "${SYSTEMD_DIR}/${HOURLY_SERVICE}" \
        "${SYSTEMD_DIR}/${HOURLY_TIMER}" \
        "${SYSTEMD_DIR}/${DAILY_SERVICE}" \
        "${SYSTEMD_DIR}/${DAILY_TIMER}"
    log_info "Systemd units written"
}

reload_and_enable_timers() {
    # 重新加载 systemd 并启用两个 timer。
    systemctl daemon-reload
    systemctl enable --now "${HOURLY_TIMER}" "${DAILY_TIMER}"
    log_info "Systemd timers enabled"
}

run_health_check() {
    # 调用 Python health 子命令，适用于安装或更新后验证数据库可打开。
    "${PYTHON_BIN}" "${PY_TARGET}" --config "${CONFIG_FILE}" check health >/dev/null
    log_info "Health check passed"
}

install_app() {
    # 执行完整安装，包含 /opt 文件、默认配置和 systemd timer。
    local source_py="$1"

    require_root
    validate_app_dir
    require_command install
    require_command python3
    require_command systemctl
    check_python_version

    ensure_directories
    install_config_if_missing
    copy_python_file "${source_py}"
    copy_manage_file
    remove_legacy_python_entry
    install_python_link
    warn_xray_binary
    run_health_check
    write_systemd_units
    reload_and_enable_timers
    log_info "Install finished"
}

update_app() {
    # 只更新 Python 主脚本并刷新 systemd unit，不覆盖配置和数据库。
    local source_py="$1"

    require_root
    validate_app_dir
    require_command install
    require_command python3
    require_command systemctl
    check_python_version

    [ -d "${APP_DIR}" ] || die "App directory not found: ${APP_DIR}"
    ensure_directories
    copy_python_file "${source_py}"
    copy_manage_file
    remove_legacy_python_entry
    install_python_link
    run_health_check
    write_systemd_units
    systemctl daemon-reload
    log_info "Update finished"
}

disable_timers() {
    # 停止并禁用 timer，适用于卸载前解除自动任务。
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${HOURLY_TIMER}" "${DAILY_TIMER}" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

remove_systemd_units() {
    # 删除 systemd unit 文件，适用于卸载时清理调度入口。
    rm -f \
        "${SYSTEMD_DIR}/${HOURLY_SERVICE}" \
        "${SYSTEMD_DIR}/${HOURLY_TIMER}" \
        "${SYSTEMD_DIR}/${DAILY_SERVICE}" \
        "${SYSTEMD_DIR}/${DAILY_TIMER}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl reset-failed >/dev/null 2>&1 || true
    fi
}

purge_app_dir() {
    # 删除整个 /opt 应用目录，适用于用户明确传入 --purge 的场景。
    validate_app_dir
    if [ ! -d "${APP_DIR}" ]; then
        return 0
    fi
    rm -rf -- "${APP_DIR}"
    log_info "Application directory purged: ${APP_DIR}"
}

uninstall_app() {
    # 执行卸载；默认保留配置、数据库和日志，--purge 时删除整个 /opt 子目录。
    local purge="$1"

    require_root
    validate_app_dir

    disable_timers
    remove_systemd_units
    remove_python_link
    remove_legacy_python_entry
    rm -f "${PY_TARGET}" "${MANAGE_TARGET}"
    rmdir "${BIN_DIR}" >/dev/null 2>&1 || true

    if [ "${purge}" = "1" ]; then
        purge_app_dir
    else
        log_info "Data kept under: ${APP_DIR}"
    fi
    log_info "Uninstall finished"
}

show_status() {
    # 展示安装路径和 timer 状态，适用于快速检查当前部署。
    validate_app_dir
    printf 'APP_DIR=%s\n' "${APP_DIR}"
    printf 'CONFIG_FILE=%s\n' "${CONFIG_FILE}"
    printf 'PY_TARGET=%s\n' "${PY_TARGET}"
    printf 'PY_LINK=%s\n' "${PY_LINK}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-timers "${HOURLY_TIMER}" "${DAILY_TIMER}" --no-pager || true
        systemctl is-enabled "${HOURLY_TIMER}" "${DAILY_TIMER}" 2>/dev/null || true
    else
        log_warn "systemctl not found"
    fi
}

main() {
    # 解析管理命令并分发到安装、更新、卸载和状态查看。
    local command="${1:-help}"
    local purge="0"
    local source_py=""

    if [ "$#" -gt 0 ]; then
        shift
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --purge)
            purge="1"
            ;;
        --py)
            shift
            [ "$#" -gt 0 ] || die "Missing value for --py"
            source_py="$1"
            ;;
        -h | --help)
            usage
            return 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
        esac
        shift
    done

    case "${command}" in
    install)
        install_app "${source_py}"
        ;;
    update)
        update_app "${source_py}"
        ;;
    uninstall)
        uninstall_app "${purge}"
        ;;
    status)
        show_status
        ;;
    help | -h | --help)
        usage
        ;;
    *)
        usage
        die "Unknown command: ${command}"
        ;;
    esac
}

main "$@"
