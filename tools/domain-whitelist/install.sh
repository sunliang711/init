#!/usr/bin/env bash

set -euo pipefail

# 文件用途:
#   安装 domain-whitelist 管理脚本到 Linux 系统目录。
# 安全约束:
#   默认只复制脚本和初始化配置；只有显式传入 --enable 才启用防火墙规则。

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_SRC="${SCRIPT_DIR}/domain-whitelist"
INSTALL_PATH="${DWL_INSTALL_PATH:-/usr/local/sbin/domain-whitelist}"
LINK_PATH="${DWL_LINK_PATH:-/usr/local/bin/dwl}"
CREATE_LINK=0
ENABLE_AFTER_INSTALL=0
DRY_RUN=0
YES=0

declare -a ENABLE_ARGS=()

# 输出普通日志，日志内容保持英文，便于安装排错。
log_info() {
    printf 'INFO %s\n' "$*" >&2
}

# 输出错误并退出，所有失败路径统一通过该函数返回。
die() {
    printf 'ERROR %s\n' "$*" >&2
    exit 1
}

# 展示安装脚本的参数和示例。
usage() {
    cat <<EOF
用法:
  ${SCRIPT_NAME} [options]

参数:
  --path <path>
      安装路径，默认 ${INSTALL_PATH}

  --link
      同时创建快捷命令 ${LINK_PATH}

  --enable
      安装后立即执行 domain-whitelist enable。白名单为空时仍会失败，除非同时传 --yes。

  --backend auto|nft|iptables
  --interval seconds
  --timeout seconds
  --scheduler auto|systemd|cron|none
      传给 domain-whitelist enable/config 的配置项。

  --dry-run
      只打印将要执行的动作。

  --yes
      传给 domain-whitelist enable，用于确认危险操作。

  -h, --help
      显示帮助。

示例:
  sudo ${SCRIPT_NAME}
  sudo ${SCRIPT_NAME} --link
  sudo ${SCRIPT_NAME} --enable --backend auto
EOF
}

# 检查当前系统为 Linux，避免安装到非目标平台。
require_linux() {
    if [ "$(uname)" != "Linux" ]; then
        die "Only Linux is supported"
    fi
}

# 检查 root 权限，安装系统目录前统一失败。
require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "This installer must be run as root"
    fi
}

# dry-run 兼容执行器，安装前展示将要运行的命令。
run_cmd() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf 'DRY-RUN'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

# 解析安装脚本参数，防止未知参数静默生效。
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --path)
                [ "$#" -ge 2 ] || die "Missing value for --path"
                INSTALL_PATH="$2"
                shift 2
                ;;
            --link)
                CREATE_LINK=1
                shift
                ;;
            --enable)
                ENABLE_AFTER_INSTALL=1
                shift
                ;;
            --backend|--interval|--timeout|--scheduler)
                [ "$#" -ge 2 ] || die "Missing value for $1"
                ENABLE_ARGS+=("$1" "$2")
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                YES=1
                shift
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

# 复制管理脚本并初始化配置目录。
install_manager() {
    local install_dir

    [ -f "${MANAGER_SRC}" ] || die "Manager script not found: ${MANAGER_SRC}"
    install_dir="$(dirname "${INSTALL_PATH}")"
    run_cmd install -d -m 0755 "${install_dir}"
    run_cmd install -m 0755 "${MANAGER_SRC}" "${INSTALL_PATH}"
    run_cmd "${INSTALL_PATH}" init
}

# 按需创建短命令链接，存在非链接文件时拒绝覆盖。
create_short_link() {
    local link_dir

    [ "${CREATE_LINK}" -eq 1 ] || return 0
    link_dir="$(dirname "${LINK_PATH}")"
    run_cmd install -d -m 0755 "${link_dir}"

    if [ -e "${LINK_PATH}" ] && [ ! -L "${LINK_PATH}" ]; then
        die "Refuse to overwrite non-symlink: ${LINK_PATH}"
    fi

    run_cmd ln -sfn "${INSTALL_PATH}" "${LINK_PATH}"
}

# 安装后按需启用防火墙规则和调度任务。
enable_if_requested() {
    local args=()

    [ "${ENABLE_AFTER_INSTALL}" -eq 1 ] || return 0

    if [ "${DRY_RUN}" -eq 1 ]; then
        args+=(--dry-run)
    fi
    if [ "${YES}" -eq 1 ]; then
        args+=(--yes)
    fi
    args+=(enable)
    args+=("${ENABLE_ARGS[@]}")
    run_cmd "${INSTALL_PATH}" "${args[@]}"
}

# 主入口，按固定顺序执行安装、链接和可选启用。
main() {
    parse_args "$@"
    require_linux
    require_root
    install_manager
    create_short_link
    enable_if_requested
    log_info "Installed domain-whitelist: ${INSTALL_PATH}"
}

main "$@"
