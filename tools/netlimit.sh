#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${SCRIPT_NAME}"
APP_DIR="/etc/netlimit"
CONFIG_FILE="${APP_DIR}/rules.conf"
STATE_FILE="${APP_DIR}/active-devs"
PID_CLASS_FILE="${APP_DIR}/pid-classes.conf"
SYSTEMD_SERVICE="/etc/systemd/system/netlimit.service"
INSTALL_PATH="/usr/local/sbin/netlimit"
SERVICE_NAME="netlimit.service"
MAX_RATE="10000mbit"
DEFAULT_CLASS_MINOR="999"
PID_CLASS_MINOR_START=30000
PID_CLASS_MINOR_END=59999

log_info() {
    printf 'INFO %s\n' "$*" >&2
}

log_warn() {
    printf 'WARN %s\n' "$*" >&2
}

die() {
    printf 'ERROR %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} global --dev DEV --upload RATE --download RATE
  ${SCRIPT_NAME} port --dev DEV --port PORT [--proto tcp|udp|both] [--side local|remote|any] --upload RATE --download RATE
  ${SCRIPT_NAME} pid --dev DEV --pid PID [--upload RATE] [--download RATE]
  ${SCRIPT_NAME} apply
  ${SCRIPT_NAME} clear --dev DEV
  ${SCRIPT_NAME} clear-all
  ${SCRIPT_NAME} reset --dev DEV
  ${SCRIPT_NAME} status [--dev DEV|--all-devs]
  ${SCRIPT_NAME} install-service
  ${SCRIPT_NAME} uninstall-service

Rates:
  Use tc units such as 500kbit, 10mbit, 1gbit.

Notes:
  global and port rules are persisted in ${CONFIG_FILE}.
  pid rules are runtime-only. They are not restored after reboot.
  pid download limiting is best-effort: it discovers current local ports with ss(8).
  Existing PID connections or future sockets may need the command to be run again.
  status prints all saved config and runtime state; use --dev or --all-devs for live tc details.

Examples:
  sudo ${SCRIPT_NAME} global --dev eth0 --upload 10mbit --download 20mbit
  sudo ${SCRIPT_NAME} port --dev eth0 --port 8080 --proto tcp --side local --upload 2mbit --download 5mbit
  sudo ${SCRIPT_NAME} pid --dev eth0 --pid 12345 --upload 1mbit --download 3mbit
  sudo ${SCRIPT_NAME} install-service
EOF
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "This command must be run as root"
    fi
}

require_linux() {
    if [ "$(uname)" != "Linux" ]; then
        die "Only Linux is supported"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_commands() {
    local command_name

    for command_name in "$@"; do
        require_command "${command_name}"
    done
}

read_os_value() {
    local key="$1"
    local value=""

    value="$(grep -E "^${key}=" /etc/os-release 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "${value}"
}

require_debian_or_ubuntu() {
    local os_id

    [ -r /etc/os-release ] || die "Cannot read /etc/os-release"
    os_id="$(read_os_value "ID")"
    case "${os_id}" in
        debian|ubuntu)
            ;;
        *)
            die "Unsupported OS: ${os_id:-unknown}"
            ;;
    esac
}

ensure_config_dir() {
    install -d -m 0755 "${APP_DIR}"
    if [ ! -f "${CONFIG_FILE}" ]; then
        umask 022
        : >"${CONFIG_FILE}"
        chmod 0644 "${CONFIG_FILE}"
    fi
}

validate_dev() {
    local dev="$1"

    [ -n "${dev}" ] || die "Device must not be empty"
    case "${dev}" in
        *[!a-zA-Z0-9_.:-]*)
            die "Invalid device name: ${dev}"
            ;;
    esac
    [ -d "/sys/class/net/${dev}" ] || die "Network device not found: ${dev}"
}

normalize_rate() {
    local value

    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    if [ "${value}" = "none" ]; then
        printf '%s\n' "none"
        return 0
    fi

    case "${value}" in
        *[!0-9a-z.]*)
            die "Invalid rate: ${1}"
            ;;
    esac

    if [[ ! "${value}" =~ ^[0-9]+([.][0-9]+)?(bit|kbit|mbit|gbit|tbit)$ ]]; then
        die "Invalid rate: ${1}. Use units like 500kbit, 10mbit, 1gbit"
    fi

    printf '%s\n' "${value}"
}

validate_port() {
    local port="$1"

    if [[ ! "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        die "Invalid port: ${port}"
    fi
}

validate_proto() {
    local proto="$1"

    case "${proto}" in
        tcp|udp|both)
            ;;
        *)
            die "Invalid proto: ${proto}"
            ;;
    esac
}

validate_side() {
    local side="$1"

    case "${side}" in
        local|remote|any)
            ;;
        *)
            die "Invalid side: ${side}"
            ;;
    esac
}

validate_pid() {
    local pid="$1"

    if [[ ! "${pid}" =~ ^[0-9]+$ ]] || [ ! -d "/proc/${pid}" ]; then
        die "PID not found: ${pid}"
    fi
}

ifb_name() {
    local dev="$1"
    local number

    number="$(printf '%s' "${dev}" | cksum | awk '{print $1}')"
    printf 'ifbnl%s' "${number}"
}

line_value() {
    local line="$1"
    local key="$2"
    local part

    for part in ${line}; do
        case "${part}" in
            "${key}="*)
                printf '%s\n' "${part#*=}"
                return 0
                ;;
        esac
    done

    return 1
}

line_kind() {
    local line="$1"

    printf '%s\n' "${line%% *}"
}

is_rule_line() {
    local line="$1"

    [ -n "${line}" ] || return 1
    case "${line}" in
        \#*)
            return 1
            ;;
    esac
    return 0
}

config_devs() {
    local line
    local dev

    [ -f "${CONFIG_FILE}" ] || return 0
    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        dev="$(line_value "${line}" "dev" || true)"
        [ -n "${dev}" ] || continue
        printf '%s\n' "${dev}"
    done <"${CONFIG_FILE}" | sort -u
}

# 记录脚本实际设置过的网卡，避免 clear-all 误清理其他 tc 规则。
active_devs() {
    local dev

    [ -f "${STATE_FILE}" ] || return 0
    while IFS= read -r dev || [ -n "${dev}" ]; do
        [ -n "${dev}" ] || continue
        case "${dev}" in
            *[!a-zA-Z0-9_.:-]*)
                continue
                ;;
        esac
        printf '%s\n' "${dev}"
    done <"${STATE_FILE}" | sort -u
}

tracked_devs() {
    {
        config_devs
        active_devs
    } | sort -u
}

record_active_dev() {
    local dev="$1"
    local tmp_file

    validate_dev "${dev}"
    ensure_config_dir
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    {
        if [ -f "${STATE_FILE}" ]; then
            cat "${STATE_FILE}"
        fi
        printf '%s\n' "${dev}"
    } | awk 'NF > 0 { print }' | sort -u >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${STATE_FILE}"
    rm -f "${tmp_file}"
}

remove_active_dev() {
    local dev="$1"
    local tmp_file

    [ -f "${STATE_FILE}" ] || return 0
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    awk -v target_dev="${dev}" '$0 != target_dev { print }' "${STATE_FILE}" >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${STATE_FILE}"
    rm -f "${tmp_file}"
}

clear_runtime_state() {
    rm -f "${STATE_FILE}" "${PID_CLASS_FILE}"
}

write_config_line() {
    local id="$1"
    local line="$2"
    local tmp_file

    ensure_config_dir
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    awk -v id_field="id=${id}" '
        {
            keep = 1
            for (i = 1; i <= NF; i++) {
                if ($i == id_field) {
                    keep = 0
                }
            }
            if (keep == 1) {
                print
            }
        }
    ' "${CONFIG_FILE}" >"${tmp_file}"
    printf '%s\n' "${line}" >>"${tmp_file}"
    install -m 0644 "${tmp_file}" "${CONFIG_FILE}"
    rm -f "${tmp_file}"
}

remove_config_dev() {
    local dev="$1"
    local tmp_file

    ensure_config_dir
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    awk -v dev_field="dev=${dev}" '
        {
            keep = 1
            for (i = 1; i <= NF; i++) {
                if ($i == dev_field) {
                    keep = 0
                }
            }
            if (keep == 1) {
                print
            }
        }
    ' "${CONFIG_FILE}" >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${CONFIG_FILE}"
    rm -f "${tmp_file}"
}

get_global_rate() {
    local dev="$1"
    local direction="$2"
    local line
    local kind
    local line_dev
    local rate

    [ -f "${CONFIG_FILE}" ] || {
        printf '%s\n' "none"
        return 0
    }

    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        kind="$(line_kind "${line}")"
        [ "${kind}" = "GLOBAL" ] || continue
        line_dev="$(line_value "${line}" "dev" || true)"
        [ "${line_dev}" = "${dev}" ] || continue
        rate="$(line_value "${line}" "${direction}" || true)"
        printf '%s\n' "${rate:-none}"
        return 0
    done <"${CONFIG_FILE}"

    printf '%s\n' "none"
}

has_config_direction() {
    local dev="$1"
    local direction="$2"
    local line
    local line_dev
    local rate

    [ -f "${CONFIG_FILE}" ] || return 1
    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        line_dev="$(line_value "${line}" "dev" || true)"
        [ "${line_dev}" = "${dev}" ] || continue
        rate="$(line_value "${line}" "${direction}" || true)"
        if [ -n "${rate}" ] && [ "${rate}" != "none" ]; then
            return 0
        fi
    done <"${CONFIG_FILE}"

    return 1
}

root_rate_for_direction() {
    local dev="$1"
    local direction="$2"
    local rate

    rate="$(get_global_rate "${dev}" "${direction}")"
    if [ "${rate}" = "none" ]; then
        printf '%s\n' "${MAX_RATE}"
    else
        printf '%s\n' "${rate}"
    fi
}

clear_active_dev() {
    local dev="$1"
    local ifb_dev

    validate_dev "${dev}"
    ifb_dev="$(ifb_name "${dev}")"

    tc qdisc del dev "${dev}" root >/dev/null 2>&1 || true
    tc qdisc del dev "${dev}" ingress >/dev/null 2>&1 || true

    if ip link show "${ifb_dev}" >/dev/null 2>&1; then
        tc qdisc del dev "${ifb_dev}" root >/dev/null 2>&1 || true
        ip link set dev "${ifb_dev}" down >/dev/null 2>&1 || true
        ip link delete "${ifb_dev}" type ifb >/dev/null 2>&1 || true
    fi
}

setup_egress_dev() {
    local dev="$1"
    local root_rate="$2"

    validate_dev "${dev}"
    tc qdisc replace dev "${dev}" root handle 1: htb default "${DEFAULT_CLASS_MINOR}"
    tc class replace dev "${dev}" parent 1: classid 1:1 htb rate "${root_rate}" ceil "${root_rate}"
    tc class replace dev "${dev}" parent 1:1 classid "1:${DEFAULT_CLASS_MINOR}" htb rate "${root_rate}" ceil "${root_rate}"
    record_active_dev "${dev}"
}

setup_ingress_dev() {
    local dev="$1"
    local ifb_dev="$2"
    local root_rate="$3"

    validate_dev "${dev}"
    modprobe ifb numifbs=16 >/dev/null 2>&1 || modprobe ifb >/dev/null 2>&1 || die "Failed to load ifb module"

    if ! ip link show "${ifb_dev}" >/dev/null 2>&1; then
        ip link add "${ifb_dev}" type ifb
    fi
    ip link set dev "${ifb_dev}" up

    tc qdisc replace dev "${ifb_dev}" root handle 1: htb default "${DEFAULT_CLASS_MINOR}"
    tc class replace dev "${ifb_dev}" parent 1: classid 1:1 htb rate "${root_rate}" ceil "${root_rate}"
    tc class replace dev "${ifb_dev}" parent 1:1 classid "1:${DEFAULT_CLASS_MINOR}" htb rate "${root_rate}" ceil "${root_rate}"

    tc qdisc replace dev "${dev}" ingress
    tc filter del dev "${dev}" parent ffff: protocol all prio 1 matchall >/dev/null 2>&1 || true
    tc filter add dev "${dev}" parent ffff: protocol all prio 1 matchall action mirred egress redirect dev "${ifb_dev}"
    record_active_dev "${dev}"
}

add_flower_filter() {
    local dev="$1"
    local transport_proto="$2"
    local port_field="$3"
    local port="$4"
    local classid="$5"
    local prio="$6"
    local network_proto

    for network_proto in ip ipv6; do
        tc filter add dev "${dev}" parent 1: protocol "${network_proto}" prio "${prio}" flower \
            ip_proto "${transport_proto}" "${port_field}" "${port}" classid "${classid}"
    done
}

add_port_filters_for_rule() {
    local dev="$1"
    local direction="$2"
    local proto="$3"
    local side="$4"
    local port="$5"
    local classid="$6"
    local prio="$7"
    local transport_proto
    local local_field
    local remote_field

    if [ "${direction}" = "upload" ]; then
        local_field="src_port"
        remote_field="dst_port"
    else
        local_field="dst_port"
        remote_field="src_port"
    fi

    for transport_proto in tcp udp; do
        if [ "${proto}" != "both" ] && [ "${proto}" != "${transport_proto}" ]; then
            continue
        fi

        case "${side}" in
            local)
                add_flower_filter "${dev}" "${transport_proto}" "${local_field}" "${port}" "${classid}" "${prio}"
                ;;
            remote)
                add_flower_filter "${dev}" "${transport_proto}" "${remote_field}" "${port}" "${classid}" "${prio}"
                ;;
            any)
                add_flower_filter "${dev}" "${transport_proto}" "${local_field}" "${port}" "${classid}" "${prio}"
                add_flower_filter "${dev}" "${transport_proto}" "${remote_field}" "${port}" "${classid}" "${prio}"
                ;;
        esac
    done
}

apply_port_rules() {
    local dev="$1"
    local target_dev="$2"
    local direction="$3"
    local line
    local kind
    local line_dev
    local proto
    local side
    local port
    local rate
    local minor_decimal=16
    local class_minor
    local classid
    local prio=20

    [ -f "${CONFIG_FILE}" ] || return 0
    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        kind="$(line_kind "${line}")"
        [ "${kind}" = "PORT" ] || continue
        line_dev="$(line_value "${line}" "dev" || true)"
        [ "${line_dev}" = "${dev}" ] || continue

        rate="$(line_value "${line}" "${direction}" || true)"
        if [ -z "${rate}" ] || [ "${rate}" = "none" ]; then
            continue
        fi

        proto="$(line_value "${line}" "proto")"
        side="$(line_value "${line}" "side")"
        port="$(line_value "${line}" "port")"
        class_minor="$(printf '%x' "${minor_decimal}")"
        classid="1:${class_minor}"

        tc class replace dev "${target_dev}" parent 1:1 classid "${classid}" htb rate "${rate}" ceil "${rate}"
        add_port_filters_for_rule "${target_dev}" "${direction}" "${proto}" "${side}" "${port}" "${classid}" "${prio}"

        minor_decimal=$((minor_decimal + 1))
        prio=$((prio + 1))
    done <"${CONFIG_FILE}"
}

apply_dev_from_config() {
    local dev="$1"
    local ifb_dev
    local upload_root_rate
    local download_root_rate

    validate_dev "${dev}"
    clear_active_dev "${dev}"

    if has_config_direction "${dev}" "upload"; then
        upload_root_rate="$(root_rate_for_direction "${dev}" "upload")"
        setup_egress_dev "${dev}" "${upload_root_rate}"
        apply_port_rules "${dev}" "${dev}" "upload"
        log_info "Applied upload rules on ${dev}"
    fi

    if has_config_direction "${dev}" "download"; then
        ifb_dev="$(ifb_name "${dev}")"
        download_root_rate="$(root_rate_for_direction "${dev}" "download")"
        setup_ingress_dev "${dev}" "${ifb_dev}" "${download_root_rate}"
        apply_port_rules "${dev}" "${ifb_dev}" "download"
        log_info "Applied download rules on ${dev} via ${ifb_dev}"
    fi
}

apply_config() {
    local dev
    local has_dev=0

    ensure_config_dir
    while IFS= read -r dev || [ -n "${dev}" ]; do
        [ -n "${dev}" ] || continue
        has_dev=1
        apply_dev_from_config "${dev}"
    done < <(config_devs)

    if [ "${has_dev}" -eq 0 ]; then
        log_info "No persistent rules found"
    fi
}

ensure_egress_ready() {
    local dev="$1"

    validate_dev "${dev}"
    if tc qdisc show dev "${dev}" | grep -q 'htb 1:'; then
        return 0
    fi
    setup_egress_dev "${dev}" "${MAX_RATE}"
}

ensure_ingress_ready() {
    local dev="$1"
    local ifb_dev

    validate_dev "${dev}"
    ifb_dev="$(ifb_name "${dev}")"
    if ip link show "${ifb_dev}" >/dev/null 2>&1 && tc qdisc show dev "${ifb_dev}" | grep -q 'htb 1:'; then
        return 0
    fi
    setup_ingress_dev "${dev}" "${ifb_dev}" "${MAX_RATE}"
}

net_cls_mountpoint() {
    awk '$3 == "cgroup" && $4 ~ /(^|,)net_cls(,|$)/ { print $2; exit }' /proc/mounts
}

ensure_net_cls_mount() {
    local mount_point

    if ! grep -qw '^net_cls' /proc/cgroups 2>/dev/null; then
        die "Kernel net_cls cgroup is unavailable"
    fi

    mount_point="$(net_cls_mountpoint || true)"
    if [ -n "${mount_point}" ]; then
        printf '%s\n' "${mount_point}"
        return 0
    fi

    mount_point="/sys/fs/cgroup/net_cls"
    install -d -m 0755 "${mount_point}"
    mount -t cgroup -o net_cls net_cls "${mount_point}" || die "Failed to mount net_cls cgroup"
    printf '%s\n' "${mount_point}"
}

# 使用进程启动时间区分 PID 复用，避免 runtime PID classid 互相覆盖。
pid_start_time() {
    local pid="$1"

    awk '{
        line = $0
        sub(/^.*\) /, "", line)
        split(line, fields, " ")
        print fields[20]
    }' "/proc/${pid}/stat"
}

prune_pid_class_file() {
    local line
    local kind
    local line_dev
    local line_pid
    local line_start
    local line_minor
    local current_start
    local tmp_file

    ensure_config_dir
    [ -f "${PID_CLASS_FILE}" ] || return 0
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        kind="$(line_kind "${line}")"
        [ "${kind}" = "PID_CLASS" ] || continue
        line_dev="$(line_value "${line}" "dev" || true)"
        line_pid="$(line_value "${line}" "pid" || true)"
        line_start="$(line_value "${line}" "start" || true)"
        line_minor="$(line_value "${line}" "minor" || true)"
        [ -n "${line_dev}" ] || continue
        case "${line_dev}" in
            *[!a-zA-Z0-9_.:-]*)
                continue
                ;;
        esac
        [[ "${line_pid}" =~ ^[0-9]+$ ]] || continue
        [[ "${line_start}" =~ ^[0-9]+$ ]] || continue
        case "${line_minor}" in
            ""|*[!0-9a-f]*)
                continue
                ;;
        esac
        [ -d "/proc/${line_pid}" ] || continue
        current_start="$(pid_start_time "${line_pid}" || true)"
        [ "${current_start}" = "${line_start}" ] || continue
        printf '%s\n' "${line}"
    done <"${PID_CLASS_FILE}" >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${PID_CLASS_FILE}"
    rm -f "${tmp_file}"
}

pid_class_minor_is_used() {
    local dev="$1"
    local minor="$2"
    local line
    local line_dev
    local line_minor

    [ -f "${PID_CLASS_FILE}" ] || return 1
    while IFS= read -r line || [ -n "${line}" ]; do
        is_rule_line "${line}" || continue
        line_dev="$(line_value "${line}" "dev" || true)"
        line_minor="$(line_value "${line}" "minor" || true)"
        [ "${line_dev}" = "${dev}" ] || continue
        [ "${line_minor}" = "${minor}" ] || continue
        return 0
    done <"${PID_CLASS_FILE}"

    return 1
}

write_pid_class_line() {
    local dev="$1"
    local pid="$2"
    local start_time="$3"
    local minor="$4"
    local tmp_file

    ensure_config_dir
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    if [ -f "${PID_CLASS_FILE}" ]; then
        awk -v dev_field="dev=${dev}" -v pid_field="pid=${pid}" '
            {
                has_dev = 0
                has_pid = 0
                for (i = 1; i <= NF; i++) {
                    if ($i == dev_field) {
                        has_dev = 1
                    }
                    if ($i == pid_field) {
                        has_pid = 1
                    }
                }
                if (has_dev == 0 || has_pid == 0) {
                    print
                }
            }
        ' "${PID_CLASS_FILE}" >"${tmp_file}"
    fi
    printf 'PID_CLASS dev=%s pid=%s start=%s minor=%s\n' "${dev}" "${pid}" "${start_time}" "${minor}" >>"${tmp_file}"
    install -m 0644 "${tmp_file}" "${PID_CLASS_FILE}"
    rm -f "${tmp_file}"
}

remove_pid_classes_dev() {
    local dev="$1"
    local tmp_file

    [ -f "${PID_CLASS_FILE}" ] || return 0
    tmp_file="$(mktemp)" || die "Failed to create temporary file"
    awk -v dev_field="dev=${dev}" '
        {
            keep = 1
            for (i = 1; i <= NF; i++) {
                if ($i == dev_field) {
                    keep = 0
                }
            }
            if (keep == 1) {
                print
            }
        }
    ' "${PID_CLASS_FILE}" >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${PID_CLASS_FILE}"
    rm -f "${tmp_file}"
}

pid_class_minor() {
    local dev="$1"
    local pid="$2"
    local start_time
    local line
    local line_dev
    local line_pid
    local line_start
    local line_minor
    local minor_decimal
    local class_minor

    prune_pid_class_file
    start_time="$(pid_start_time "${pid}" || true)"
    [ -n "${start_time}" ] || die "Cannot read start time for pid=${pid}"

    if [ -f "${PID_CLASS_FILE}" ]; then
        while IFS= read -r line || [ -n "${line}" ]; do
            is_rule_line "${line}" || continue
            line_dev="$(line_value "${line}" "dev" || true)"
            line_pid="$(line_value "${line}" "pid" || true)"
            line_start="$(line_value "${line}" "start" || true)"
            line_minor="$(line_value "${line}" "minor" || true)"
            [ "${line_dev}" = "${dev}" ] || continue
            [ "${line_pid}" = "${pid}" ] || continue
            [ "${line_start}" = "${start_time}" ] || continue
            printf '%s\n' "${line_minor}"
            return 0
        done <"${PID_CLASS_FILE}"
    fi

    minor_decimal="${PID_CLASS_MINOR_START}"
    while [ "${minor_decimal}" -le "${PID_CLASS_MINOR_END}" ]; do
        class_minor="$(printf '%x' "${minor_decimal}")"
        if ! pid_class_minor_is_used "${dev}" "${class_minor}"; then
            write_pid_class_line "${dev}" "${pid}" "${start_time}" "${class_minor}"
            printf '%s\n' "${class_minor}"
            return 0
        fi
        minor_decimal=$((minor_decimal + 1))
    done

    die "No available PID class id for dev=${dev}"
}

classid_to_net_cls_value() {
    local minor_hex="$1"
    local minor_decimal

    minor_decimal=$((16#${minor_hex}))
    printf '0x%04x%04x\n' 1 "${minor_decimal}"
}

# PID 下载 filter 使用 class minor 作为唯一 prio，便于重跑时精确清理旧规则。
pid_filter_prio() {
    local minor_hex="$1"

    printf '%d\n' "$((16#${minor_hex}))"
}

clear_pid_download_filters() {
    local dev="$1"
    local class_minor="$2"
    local prio
    local network_proto

    prio="$(pid_filter_prio "${class_minor}")"
    for network_proto in ip ipv6; do
        tc filter del dev "${dev}" parent 1: protocol "${network_proto}" prio "${prio}" >/dev/null 2>&1 || true
    done
}

apply_pid_upload_rule() {
    local dev="$1"
    local pid="$2"
    local rate="$3"
    local mount_point
    local cgroup_dir
    local class_minor
    local classid
    local net_cls_value

    ensure_egress_ready "${dev}"
    mount_point="$(ensure_net_cls_mount)"
    cgroup_dir="${mount_point}/netlimit/${dev}/${pid}"
    install -d -m 0755 "${cgroup_dir}"

    class_minor="$(pid_class_minor "${dev}" "${pid}")"
    classid="1:${class_minor}"
    net_cls_value="$(classid_to_net_cls_value "${class_minor}")"

    printf '%s\n' "${net_cls_value}" >"${cgroup_dir}/net_cls.classid"
    if [ -w "${cgroup_dir}/cgroup.procs" ]; then
        printf '%s\n' "${pid}" >"${cgroup_dir}/cgroup.procs"
    else
        printf '%s\n' "${pid}" >"${cgroup_dir}/tasks"
    fi

    tc class replace dev "${dev}" parent 1:1 classid "${classid}" htb rate "${rate}" ceil "${rate}"
    tc filter replace dev "${dev}" parent 1: protocol ip prio 1 handle 1: cgroup
    tc filter replace dev "${dev}" parent 1: protocol ipv6 prio 1 handle 1: cgroup
    record_active_dev "${dev}"
    log_info "Applied runtime PID upload rule: pid=${pid} dev=${dev} rate=${rate}"
}

discover_pid_ports() {
    local pid="$1"

    ss -H -tunp 2>/dev/null | awk -v needle="pid=${pid}," '
        index($0, needle) > 0 {
            proto = $1
            local_addr = $5
            sub(/.*:/, "", local_addr)
            if ((proto == "tcp" || proto == "udp") && local_addr ~ /^[0-9]+$/ && local_addr != "0") {
                print proto ":" local_addr
            }
        }
    ' | sort -u
}

apply_pid_download_rule() {
    local dev="$1"
    local pid="$2"
    local rate="$3"
    local ifb_dev
    local class_minor
    local classid
    local proto_port
    local proto
    local port
    local found_port=0
    local prio

    require_command ss
    ensure_ingress_ready "${dev}"
    ifb_dev="$(ifb_name "${dev}")"
    class_minor="$(pid_class_minor "${dev}" "${pid}")"
    classid="1:${class_minor}"
    prio="$(pid_filter_prio "${class_minor}")"

    clear_pid_download_filters "${ifb_dev}" "${class_minor}"
    tc class replace dev "${ifb_dev}" parent 1:1 classid "${classid}" htb rate "${rate}" ceil "${rate}"
    record_active_dev "${dev}"

    while IFS= read -r proto_port || [ -n "${proto_port}" ]; do
        [ -n "${proto_port}" ] || continue
        proto="${proto_port%%:*}"
        port="${proto_port#*:}"
        add_port_filters_for_rule "${ifb_dev}" "download" "${proto}" "local" "${port}" "${classid}" "${prio}"
        found_port=1
        log_warn "PID download rule uses local port ${port}/${proto}; traffic from other processes on this port may also be limited"
    done < <(discover_pid_ports "${pid}")

    if [ "${found_port}" -eq 0 ]; then
        log_warn "No current TCP/UDP ports found for pid=${pid}; download rule was not applied"
    else
        log_info "Applied best-effort runtime PID download rule: pid=${pid} dev=${dev} rate=${rate}"
    fi
}

cmd_global() {
    local dev=""
    local upload="none"
    local download="none"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            --upload)
                [ "$#" -ge 2 ] || die "Missing value for --upload"
                upload="$(normalize_rate "$2")"
                shift 2
                ;;
            --download)
                [ "$#" -ge 2 ] || die "Missing value for --download"
                download="$(normalize_rate "$2")"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for global: $1"
                ;;
        esac
    done

    validate_dev "${dev}"
    if [ "${upload}" = "none" ] && [ "${download}" = "none" ]; then
        die "At least one of --upload or --download must be set"
    fi

    write_config_line "global:${dev}" "GLOBAL id=global:${dev} dev=${dev} upload=${upload} download=${download}"
    apply_dev_from_config "${dev}"
    log_info "Persistent global rule saved for ${dev}"
}

cmd_port() {
    local dev=""
    local port=""
    local proto="tcp"
    local side="local"
    local upload="none"
    local download="none"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            --port)
                [ "$#" -ge 2 ] || die "Missing value for --port"
                port="$2"
                shift 2
                ;;
            --proto)
                [ "$#" -ge 2 ] || die "Missing value for --proto"
                proto="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --side)
                [ "$#" -ge 2 ] || die "Missing value for --side"
                side="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --upload)
                [ "$#" -ge 2 ] || die "Missing value for --upload"
                upload="$(normalize_rate "$2")"
                shift 2
                ;;
            --download)
                [ "$#" -ge 2 ] || die "Missing value for --download"
                download="$(normalize_rate "$2")"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for port: $1"
                ;;
        esac
    done

    validate_dev "${dev}"
    validate_port "${port}"
    validate_proto "${proto}"
    validate_side "${side}"
    if [ "${upload}" = "none" ] && [ "${download}" = "none" ]; then
        die "At least one of --upload or --download must be set"
    fi

    write_config_line "port:${dev}:${proto}:${side}:${port}" \
        "PORT id=port:${dev}:${proto}:${side}:${port} dev=${dev} proto=${proto} side=${side} port=${port} upload=${upload} download=${download}"
    apply_dev_from_config "${dev}"
    log_info "Persistent port rule saved for ${dev} ${port}/${proto} side=${side}"
}

cmd_pid() {
    local dev=""
    local pid=""
    local upload="none"
    local download="none"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            --pid)
                [ "$#" -ge 2 ] || die "Missing value for --pid"
                pid="$2"
                shift 2
                ;;
            --upload)
                [ "$#" -ge 2 ] || die "Missing value for --upload"
                upload="$(normalize_rate "$2")"
                shift 2
                ;;
            --download)
                [ "$#" -ge 2 ] || die "Missing value for --download"
                download="$(normalize_rate "$2")"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for pid: $1"
                ;;
        esac
    done

    validate_dev "${dev}"
    validate_pid "${pid}"
    if [ "${upload}" = "none" ] && [ "${download}" = "none" ]; then
        die "At least one of --upload or --download must be set"
    fi

    log_warn "PID rules are runtime-only and will not be written to ${CONFIG_FILE}"
    if [ "${upload}" != "none" ]; then
        apply_pid_upload_rule "${dev}" "${pid}" "${upload}"
    fi
    if [ "${download}" != "none" ]; then
        apply_pid_download_rule "${dev}" "${pid}" "${download}"
    fi
}

cmd_clear() {
    local dev=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for clear: $1"
                ;;
        esac
    done

    validate_dev "${dev}"
    clear_active_dev "${dev}"
    remove_active_dev "${dev}"
    remove_pid_classes_dev "${dev}"
    log_info "Cleared active tc rules on ${dev}; persistent config was kept"
}

cmd_clear_all() {
    local dev
    local has_dev=0

    while IFS= read -r dev || [ -n "${dev}" ]; do
        [ -n "${dev}" ] || continue
        has_dev=1
        if [ ! -d "/sys/class/net/${dev}" ]; then
            log_warn "Skip missing network device: ${dev}"
            continue
        fi
        clear_active_dev "${dev}"
        log_info "Cleared active tc rules on ${dev}"
    done < <(tracked_devs)
    clear_runtime_state

    if [ "${has_dev}" -eq 0 ]; then
        log_info "No active or persistent devices found"
    fi
}

cmd_reset() {
    local dev=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for reset: $1"
                ;;
        esac
    done

    validate_dev "${dev}"
    clear_active_dev "${dev}"
    remove_config_dev "${dev}"
    remove_active_dev "${dev}"
    remove_pid_classes_dev "${dev}"
    log_info "Removed active and persistent rules for ${dev}"
}

print_status_file() {
    local title="$1"
    local path="$2"

    printf '== %s: %s ==\n' "${title}" "${path}"
    if [ ! -f "${path}" ]; then
        printf '(missing)\n'
        return 0
    fi
    if [ ! -s "${path}" ]; then
        printf '(empty)\n'
        return 0
    fi
    cat "${path}"
}

print_service_status() {
    local service_enabled
    local service_active

    printf '\n== Service: %s ==\n' "${SERVICE_NAME}"
    if [ -f "${SYSTEMD_SERVICE}" ]; then
        printf 'unit_file=%s\n' "${SYSTEMD_SERVICE}"
    else
        printf 'unit_file=(missing)\n'
    fi

    if command -v systemctl >/dev/null 2>&1; then
        service_enabled="$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)"
        service_active="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"
        printf 'enabled=%s\n' "${service_enabled:-unknown}"
        printf 'active=%s\n' "${service_active:-unknown}"
    else
        printf 'systemctl=(missing)\n'
    fi
}

print_tc_status_dev() {
    local dev="$1"
    local ifb_dev

    require_commands cksum ip tc
    validate_dev "${dev}"
    ifb_dev="$(ifb_name "${dev}")"
    printf '\n== qdisc dev %s ==\n' "${dev}"
    tc qdisc show dev "${dev}" || true
    printf '\n== class dev %s ==\n' "${dev}"
    tc class show dev "${dev}" || true
    printf '\n== filter dev %s ==\n' "${dev}"
    tc filter show dev "${dev}" || true

    if ip link show "${ifb_dev}" >/dev/null 2>&1; then
        printf '\n== qdisc dev %s ==\n' "${ifb_dev}"
        tc qdisc show dev "${ifb_dev}" || true
        printf '\n== class dev %s ==\n' "${ifb_dev}"
        tc class show dev "${ifb_dev}" || true
        printf '\n== filter dev %s ==\n' "${ifb_dev}"
        tc filter show dev "${ifb_dev}" || true
    fi
}

cmd_status() {
    local dev=""
    local all_devs=0
    local status_dev
    local has_dev=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dev)
                [ "$#" -ge 2 ] || die "Missing value for --dev"
                dev="$2"
                shift 2
                ;;
            --all-devs)
                all_devs=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option for status: $1"
                ;;
        esac
    done

    if [ -n "${dev}" ] && [ "${all_devs}" -eq 1 ]; then
        die "Use either --dev or --all-devs, not both"
    fi

    print_status_file "Persistent config" "${CONFIG_FILE}"
    printf '\n'
    print_status_file "Runtime active devices" "${STATE_FILE}"
    printf '\n'
    print_status_file "Runtime PID class mappings" "${PID_CLASS_FILE}"
    print_service_status

    if [ -n "${dev}" ]; then
        print_tc_status_dev "${dev}"
    fi

    if [ "${all_devs}" -eq 1 ]; then
        while IFS= read -r status_dev || [ -n "${status_dev}" ]; do
            [ -n "${status_dev}" ] || continue
            has_dev=1
            if [ ! -d "/sys/class/net/${status_dev}" ]; then
                log_warn "Skip missing network device: ${status_dev}"
                continue
            fi
            print_tc_status_dev "${status_dev}"
        done < <(tracked_devs)

        if [ "${has_dev}" -eq 0 ]; then
            log_info "No active or persistent devices found"
        fi
    fi
}

cmd_install_service() {
    if [ "${SCRIPT_PATH}" != "${INSTALL_PATH}" ]; then
        install -m 0755 "${SCRIPT_PATH}" "${INSTALL_PATH}"
    else
        chmod 0755 "${INSTALL_PATH}"
    fi
    cat >"${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Restore Linux network rate limits
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply
ExecStop=${INSTALL_PATH} clear-all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"
    log_info "Installed and enabled ${SERVICE_NAME}"
}

cmd_uninstall_service() {
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    if [ -f "${SYSTEMD_SERVICE}" ]; then
        rm -f "${SYSTEMD_SERVICE}"
    fi
    systemctl daemon-reload
    log_info "Uninstalled ${SERVICE_NAME}; config was kept at ${CONFIG_FILE}"
}

main() {
    local command="${1:-help}"

    case "${command}" in
        help|-h|--help)
            usage
            exit 0
            ;;
    esac

    case "${command}" in
        global|port|pid|apply|clear|clear-all|reset|status|install-service|uninstall-service)
            ;;
        *)
            die "Unknown command: ${command}"
            ;;
    esac

    require_linux
    require_debian_or_ubuntu

    if [ "${command}" = "status" ]; then
        require_commands awk grep head cut sort
        shift || true
        cmd_status "$@"
        return 0
    fi

    require_root
    require_commands awk cksum grep head cut sort mktemp install tr ip tc modprobe

    shift || true
    case "${command}" in
        global)
            cmd_global "$@"
            ;;
        port)
            cmd_port "$@"
            ;;
        pid)
            cmd_pid "$@"
            ;;
        apply)
            apply_config
            ;;
        clear)
            cmd_clear "$@"
            ;;
        clear-all)
            cmd_clear_all "$@"
            ;;
        reset)
            cmd_reset "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        install-service)
            require_command systemctl
            cmd_install_service
            ;;
        uninstall-service)
            require_command systemctl
            cmd_uninstall_service
            ;;
        *)
            die "Unknown command: ${command}"
            ;;
    esac
}

main "$@"
