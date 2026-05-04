#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

STAGE_ROOT=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

show_help() {
  cat <<EOF
Usage:
  sudo $0 set           Set static IP using environment variables
  $0 help               Show this help message

Supported environment variables (upper or lower case):

  IP_ADDRESS or ip_address   Static IP address (CIDR), e.g. 192.168.1.100/24
  GATEWAY    or gateway      Default gateway address, e.g. 192.168.1.1
  DNS_LIST   or dns_list     DNS addresses (space separated), e.g. "8.8.8.8 1.1.1.1"
  IFACE      or iface        Network interface name, e.g. "ens18" (optional)
  RENDERER   or renderer     Netplan renderer, e.g. "networkd" or "NetworkManager"
  APPLY_MODE or apply_mode   "try" (default) or "apply"
  ALLOW_EXISTING_IFACE_CONFIG or allow_existing_iface_config
                            Set to "true" to allow another netplan file for IFACE
  NETPLAN_TRY_TIMEOUT or netplan_try_timeout
                            Timeout for "netplan try", default: 30

Notes:
  - IP_ADDRESS, GATEWAY, and DNS_LIST are required.
  - This script writes a dedicated netplan override file and does not delete
    other files under /etc/netplan.
  - The script validates staged config before touching /etc/netplan.
  - APPLY_MODE=try requires an interactive terminal.

Example:

  sudo IP_ADDRESS="192.168.66.88/24" \\
       GATEWAY="192.168.66.1" \\
       DNS_LIST="1.1.1.1 8.8.8.8" \\
       IFACE="ens18" \\
       RENDERER="networkd" \\
       $0 set
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

get_env_value() {
  local upper_name="$1"
  local lower_name="$2"
  local default_value="${3:-}"

  if [ -n "${!upper_name:-}" ]; then
    printf '%s\n' "${!upper_name}"
  elif [ -n "${!lower_name:-}" ]; then
    printf '%s\n' "${!lower_name}"
  else
    printf '%s\n' "$default_value"
  fi
}

is_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets

  read -r -a octets <<<"$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

is_ipv4_cidr() {
  local cidr="$1"
  local ip_part="${cidr%/*}"
  local prefix="${cidr#*/}"

  [ "$ip_part" != "$cidr" ] || return 1
  is_ipv4 "$ip_part" || return 1
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
}

validate_iface_name() {
  local iface="$1"

  [ -n "$iface" ] || return 1
  [ "${#iface}" -le 15 ] || return 1
  [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
}

detect_iface() {
  local detected_iface

  detected_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$detected_iface" ] || die "Could not detect default network interface. Set IFACE explicitly."
  printf '%s\n' "$detected_iface"
}

netplan_supports_root_dir() {
  local help_text

  help_text="$(netplan generate --help 2>&1 || true)"
  grep -q -- '--root-dir' <<<"$help_text"
}

cleanup_stage_root() {
  if [ -n "${STAGE_ROOT:-}" ]; then
    rm -rf "$STAGE_ROOT"
  fi
}

list_iface_config_conflicts() {
  local iface="$1"
  local target_file="$2"
  local file
  local found=0

  for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [ "$file" = "$target_file" ] && continue
    if awk -v iface="$iface" 'index($0, "    " iface ":") == 1 { found=1 } END { exit found ? 0 : 1 }' "$file"; then
      printf '  - %s\n' "$file"
      found=1
    fi
  done

  [ "$found" -eq 1 ]
}

write_netplan_config() {
  local output_file="$1"
  local iface="$2"
  local renderer="$3"
  local ip_address="$4"
  local gateway="$5"
  local dns_yaml_format="$6"

  cat >"$output_file" <<EOF
network:
  version: 2
  renderer: $renderer
  ethernets:
    $iface:
      dhcp4: false
      addresses:
        - $ip_address
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [$dns_yaml_format]
EOF
}

prepare_staged_netplan_root() {
  local stage_root="$1"
  local stage_netplan_dir="${stage_root}/etc/netplan"
  local file

  mkdir -p "$stage_netplan_dir"
  for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    cp -p "$file" "$stage_netplan_dir/"
  done
}

rollback_config_file() {
  local config_file="$1"
  local backup_file="$2"
  local had_existing_config="$3"

  if [ "$had_existing_config" -eq 1 ] && [ -f "$backup_file" ]; then
    cp -p "$backup_file" "$config_file"
  else
    rm -f "$config_file"
  fi
}

apply_restored_config() {
  if ! netplan generate >/dev/null 2>&1; then
    warn "Restored config file, but 'netplan generate' still failed."
    return 1
  fi

  if ! netplan apply >/dev/null 2>&1; then
    warn "Restored config file, but 'netplan apply' still failed."
    return 1
  fi
}

run_set() {
  local cfg_ip_address
  local cfg_gateway
  local cfg_dns_list
  local cfg_iface
  local cfg_renderer
  local cfg_apply_mode
  local cfg_try_timeout
  local cfg_allow_existing_iface_config
  local config_file
  local backup_file
  local conflict_files
  local dns_yaml_format
  local dns
  local stage_config_file
  local had_existing_config=0
  local -a dns_entries

  [ "${EUID}" -eq 0 ] || die "Please run as root or use sudo."

  require_cmd ip
  require_cmd netplan
  require_cmd awk
  require_cmd grep
  require_cmd date
  require_cmd mktemp
  require_cmd cp
  require_cmd chmod
  require_cmd rm
  require_cmd mkdir

  netplan_supports_root_dir || die "This netplan version does not support 'generate --root-dir'. Cannot safely preflight config."

  cfg_ip_address="$(get_env_value IP_ADDRESS ip_address)"
  cfg_gateway="$(get_env_value GATEWAY gateway)"
  cfg_dns_list="$(get_env_value DNS_LIST dns_list)"
  cfg_iface="$(get_env_value IFACE iface)"
  cfg_renderer="$(get_env_value RENDERER renderer networkd)"
  cfg_apply_mode="$(get_env_value APPLY_MODE apply_mode try)"
  cfg_try_timeout="$(get_env_value NETPLAN_TRY_TIMEOUT netplan_try_timeout 30)"
  cfg_allow_existing_iface_config="$(get_env_value ALLOW_EXISTING_IFACE_CONFIG allow_existing_iface_config false)"

  [ -n "$cfg_ip_address" ] || die "IP_ADDRESS is required."
  [ -n "$cfg_gateway" ] || die "GATEWAY is required."
  [ -n "$cfg_dns_list" ] || die "DNS_LIST is required."

  is_ipv4_cidr "$cfg_ip_address" || die "IP_ADDRESS format is invalid. Use CIDR, e.g. 192.168.1.100/24"
  is_ipv4 "$cfg_gateway" || die "GATEWAY format is invalid. Must be a valid IPv4 address."

  read -r -a dns_entries <<<"$cfg_dns_list"
  [ "${#dns_entries[@]}" -gt 0 ] || die "DNS_LIST must contain at least one DNS server."
  for dns in "${dns_entries[@]}"; do
    is_ipv4 "$dns" || die "DNS '$dns' is not a valid IPv4 address."
  done

  case "$cfg_renderer" in
    networkd|NetworkManager)
      ;;
    *)
      die "RENDERER must be 'networkd' or 'NetworkManager'."
      ;;
  esac

  case "$cfg_apply_mode" in
    apply|try)
      ;;
    *)
      die "APPLY_MODE must be 'apply' or 'try'."
      ;;
  esac

  case "$cfg_allow_existing_iface_config" in
    true|false)
      ;;
    *)
      die "ALLOW_EXISTING_IFACE_CONFIG must be 'true' or 'false'."
      ;;
  esac

  [[ "$cfg_try_timeout" =~ ^[0-9]+$ ]] || die "NETPLAN_TRY_TIMEOUT must be a positive integer."
  [ "$cfg_try_timeout" -gt 0 ] || die "NETPLAN_TRY_TIMEOUT must be greater than 0."

  if [ "$cfg_apply_mode" = "try" ] && [ ! -t 0 ]; then
    die "APPLY_MODE=try requires an interactive terminal. Set APPLY_MODE=apply for non-interactive runs."
  fi

  if [ -z "$cfg_iface" ]; then
    cfg_iface="$(detect_iface)"
    echo "Detected default network interface: $cfg_iface"
  else
    echo "Using interface from IFACE: $cfg_iface"
  fi

  validate_iface_name "$cfg_iface" || die "IFACE contains unsupported characters or is longer than 15 characters."
  ip link show "$cfg_iface" >/dev/null 2>&1 || die "Network interface '$cfg_iface' does not exist."

  dns_yaml_format="${dns_entries[*]}"
  dns_yaml_format="${dns_yaml_format// /, }"

  config_file="/etc/netplan/99-static-${cfg_iface}.yaml"
  backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"

  if conflict_files="$(list_iface_config_conflicts "$cfg_iface" "$config_file")"; then
    if [ "$cfg_allow_existing_iface_config" = "false" ]; then
      die "Existing netplan entries reference interface '$cfg_iface':
$conflict_files
Set ALLOW_EXISTING_IFACE_CONFIG=true only after confirming these files will not conflict."
    fi
    warn "Existing netplan entries reference interface '$cfg_iface':"
    printf '%s\n' "$conflict_files" >&2
  fi

  STAGE_ROOT="$(mktemp -d)"
  trap cleanup_stage_root EXIT
  prepare_staged_netplan_root "$STAGE_ROOT"
  stage_config_file="${STAGE_ROOT}/etc/netplan/99-static-${cfg_iface}.yaml"
  write_netplan_config "$stage_config_file" "$cfg_iface" "$cfg_renderer" "$cfg_ip_address" "$cfg_gateway" "$dns_yaml_format"
  chmod 600 "$stage_config_file"

  echo "Validating staged netplan configuration..."
  netplan generate --root-dir "$STAGE_ROOT"

  if [ -f "$config_file" ]; then
    had_existing_config=1
    echo "Backing up existing config to: $backup_file"
    cp -p "$config_file" "$backup_file"
  fi

  echo "Installing netplan configuration to $config_file..."
  cp "$stage_config_file" "$config_file"
  chmod 600 "$config_file"

  echo "Validating installed netplan configuration..."
  if ! netplan generate; then
    rollback_config_file "$config_file" "$backup_file" "$had_existing_config"
    die "netplan generate failed. Previous config file was restored."
  fi

  if [ "$cfg_apply_mode" = "try" ]; then
    echo "Applying netplan configuration with confirmation window..."
    if ! netplan try --timeout "$cfg_try_timeout"; then
      rollback_config_file "$config_file" "$backup_file" "$had_existing_config"
      die "netplan try was rejected or failed. Previous config file was restored."
    fi
  else
    echo "Applying netplan configuration..."
    if ! netplan apply; then
      rollback_config_file "$config_file" "$backup_file" "$had_existing_config"
      apply_restored_config || true
      die "netplan apply failed. Previous config file was restored."
    fi
  fi

  echo "Static IP configuration applied successfully."
  echo
  echo "Current network status for interface $cfg_iface:"
  ip addr show "$cfg_iface"
  ip route show dev "$cfg_iface"

  cleanup_stage_root
  trap - EXIT
}

case "${1:-}" in
  help|"")
    show_help
    ;;
  set)
    run_set
    ;;
  *)
    echo "ERROR: Unknown command: ${1:-}" >&2
    echo >&2
    show_help
    exit 1
    ;;
esac
