#!/bin/bash

set -euo pipefail
shopt -s nullglob

die() {
  echo "ERROR: $*" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage:
  sudo $0 set           Set static IP using environment variables
  $0 help               Show this help message

Supported environment variables (case-insensitive):

  IP_ADDRESS or ip_address   Static IP address (CIDR), e.g. 192.168.1.100/24
  GATEWAY    or gateway      Default gateway address, e.g. 192.168.1.1
  DNS_LIST   or dns_list     DNS addresses (space separated), e.g. "8.8.8.8 1.1.1.1"
  IFACE      or iface        Network interface name, e.g. "ens18" (optional)
  RENDERER   or renderer     Netplan renderer, e.g. "networkd" or "NetworkManager"
  APPLY_MODE or apply_mode   "apply" (default) or "try"

Notes:
  - IP_ADDRESS, GATEWAY, and DNS_LIST are required.
  - This script writes a dedicated netplan override file and does not delete
    other files under /etc/netplan.
  - The script runs "netplan generate" before "netplan apply".

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

detect_iface() {
  local detected_iface

  detected_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$detected_iface" ] || die "Could not detect default network interface. Set IFACE explicitly."
  printf '%s\n' "$detected_iface"
}

warn_on_existing_iface_config() {
  local iface="$1"
  local file
  local warned=0

  for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    if grep -Eq "^[[:space:]]{4}${iface}:" "$file"; then
      if [ "$warned" -eq 0 ]; then
        echo "WARNING: Existing netplan entries reference interface '$iface':"
        warned=1
      fi
      echo "  - $file"
    fi
  done

  if [ "$warned" -eq 1 ]; then
    echo "WARNING: Review merged netplan config if this host already defines '$iface' elsewhere."
  fi
}

run_set() {
  local ip_address
  local gateway
  local dns_list
  local iface
  local renderer
  local apply_mode
  local try_timeout
  local config_file
  local backup_file
  local dns_yaml_format
  local dns
  local -a dns_entries

  [ "${EUID}" -eq 0 ] || die "Please run as root or use sudo."

  require_cmd ip
  require_cmd netplan
  require_cmd awk
  require_cmd grep

  ip_address="${IP_ADDRESS:-${ip_address:-}}"
  gateway="${GATEWAY:-${gateway:-}}"
  dns_list="${DNS_LIST:-${dns_list:-}}"
  iface="${IFACE:-${iface:-}}"
  renderer="${RENDERER:-${renderer:-networkd}}"
  apply_mode="${APPLY_MODE:-${apply_mode:-apply}}"
  try_timeout="${NETPLAN_TRY_TIMEOUT:-30}"

  [ -n "$ip_address" ] || die "IP_ADDRESS is required."
  [ -n "$gateway" ] || die "GATEWAY is required."
  [ -n "$dns_list" ] || die "DNS_LIST is required."

  is_ipv4_cidr "$ip_address" || die "IP_ADDRESS format is invalid. Use CIDR, e.g. 192.168.1.100/24"
  is_ipv4 "$gateway" || die "GATEWAY format is invalid. Must be a valid IPv4 address."

  read -r -a dns_entries <<<"$dns_list"
  [ "${#dns_entries[@]}" -gt 0 ] || die "DNS_LIST must contain at least one DNS server."
  for dns in "${dns_entries[@]}"; do
    is_ipv4 "$dns" || die "DNS '$dns' is not a valid IPv4 address."
  done

  case "$renderer" in
    networkd|NetworkManager)
      ;;
    *)
      die "RENDERER must be 'networkd' or 'NetworkManager'."
      ;;
  esac

  case "$apply_mode" in
    apply|try)
      ;;
    *)
      die "APPLY_MODE must be 'apply' or 'try'."
      ;;
  esac

  [[ "$try_timeout" =~ ^[0-9]+$ ]] || die "NETPLAN_TRY_TIMEOUT must be a non-negative integer."

  if [ -z "$iface" ]; then
    iface="$(detect_iface)"
    echo "Detected default network interface: $iface"
  else
    echo "Using interface from IFACE: $iface"
  fi

  ip link show "$iface" >/dev/null 2>&1 || die "Network interface '$iface' does not exist."

  dns_yaml_format="${dns_entries[*]}"
  dns_yaml_format="${dns_yaml_format// /, }"

  config_file="/etc/netplan/99-static-${iface}.yaml"
  backup_file="${config_file}.bak.$(date +%Y%m%d%H%M%S)"

  warn_on_existing_iface_config "$iface"

  if [ -f "$config_file" ]; then
    echo "Backing up existing config to: $backup_file"
    cp "$config_file" "$backup_file"
  fi

  echo "Writing new netplan configuration to $config_file..."
  tee "$config_file" >/dev/null <<EOF
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

  chmod 600 "$config_file"

  echo "Validating netplan configuration..."
  netplan generate

  if [ "$apply_mode" = "try" ]; then
    [ -t 0 ] || die "APPLY_MODE=try requires an interactive terminal."
    echo "Applying netplan configuration with confirmation window..."
    netplan try --timeout "$try_timeout"
  else
    echo "Applying netplan configuration..."
    netplan apply
  fi

  echo "Static IP configuration applied successfully."
  echo
  echo "Current network status for interface $iface:"
  ip addr show "$iface"
  ip route show dev "$iface"
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
