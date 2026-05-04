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
  sudo $0 set <IP_ADDRESS> [options]
  sudo $0 set --ip <IP_ADDRESS> [options]
  $0 help               Show this help message

Options:
  --ip <CIDR>           Static IP address, e.g. 192.168.1.100/24
  --gateway <IP>        Default gateway address
  --dns <LIST>          DNS addresses, comma or space separated
  --iface <NAME>        Network interface name
  --renderer <NAME>     Netplan renderer: networkd or NetworkManager
  --mode <MODE>         Apply mode: try (default) or apply
  --timeout <SECONDS>   Timeout for "netplan try", default: 30
  --allow-existing-iface-config
                        Allow another netplan file for IFACE
  --confirm             Continue without interactive confirmation when values
                        are inferred

Supported environment variables (upper or lower case):

  IP_ADDRESS or ip_address   Static IP address (CIDR), e.g. 192.168.1.100/24
  GATEWAY    or gateway      Default gateway address, e.g. 192.168.1.1
  DNS_LIST   or dns_list     DNS addresses, e.g. "8.8.8.8 1.1.1.1"
  IFACE      or iface        Network interface name, e.g. "ens18" (optional)
  RENDERER   or renderer     Netplan renderer, e.g. "networkd" or "NetworkManager"
  APPLY_MODE or apply_mode   "try" (default) or "apply"
  ALLOW_EXISTING_IFACE_CONFIG or allow_existing_iface_config
                            Set to "true" to allow another netplan file for IFACE
  NETPLAN_TRY_TIMEOUT or netplan_try_timeout
                            Timeout for "netplan try", default: 30

Notes:
  - IP_ADDRESS is required.
  - IFACE, GATEWAY, DNS_LIST, and RENDERER are inferred when omitted.
  - If any value is inferred, the script requires interactive confirmation or
    --confirm.
  - This script writes a dedicated netplan override file and does not delete
    other files under /etc/netplan.
  - The script validates staged config before touching /etc/netplan.
  - APPLY_MODE=try requires an interactive terminal.

Example:

  sudo $0 set 192.168.66.88/24

  sudo $0 set 192.168.66.88/24 \\
       --gateway 192.168.66.1 \\
       --dns 1.1.1.1,8.8.8.8 \\
       --iface ens18
EOF
}

require_cmds() {
  local command_name
  local missing_commands=""

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing_commands="${missing_commands}${missing_commands:+ }${command_name}"
    fi
  done

  [ -z "$missing_commands" ] || die "Required commands not found: $missing_commands"
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

env_has_value() {
  local upper_name="$1"
  local lower_name="$2"

  [ -n "${!upper_name:-}" ] || [ -n "${!lower_name:-}" ]
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
  [[ "$iface" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
}

detect_iface() {
  local detected_iface

  detected_iface=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -n "$detected_iface" ] || die "Could not detect default network interface. Set IFACE explicitly."
  printf '%s\n' "$detected_iface"
}

ipv4_to_int() {
  local ip="$1"
  local a
  local b
  local c
  local d

  IFS=. read -r a b c d <<<"$ip"
  printf '%u\n' "$((10#$a * 256 ** 3 + 10#$b * 256 ** 2 + 10#$c * 256 + 10#$d))"
}

int_to_ipv4() {
  local int="$1"

  printf '%s.%s.%s.%s\n' \
    "$(((int >> 24) & 255))" \
    "$(((int >> 16) & 255))" \
    "$(((int >> 8) & 255))" \
    "$((int & 255))"
}

cidr_mask_int() {
  local prefix="$1"

  if [ "$prefix" -eq 0 ]; then
    printf '%u\n' 0
  else
    printf '%u\n' "$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))"
  fi
}

ipv4_in_cidr() {
  local ip="$1"
  local cidr="$2"
  local cidr_ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  local mask
  local ip_int
  local cidr_int

  mask="$(cidr_mask_int "$prefix")"
  ip_int="$(ipv4_to_int "$ip")"
  cidr_int="$(ipv4_to_int "$cidr_ip")"

  [ "$((ip_int & mask))" -eq "$((cidr_int & mask))" ]
}

infer_gateway_from_cidr() {
  local cidr="$1"
  local cidr_ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  local mask
  local ip_int
  local network_int
  local gateway_int
  local gateway_ip

  [ "$prefix" -lt 31 ] || return 1

  mask="$(cidr_mask_int "$prefix")"
  ip_int="$(ipv4_to_int "$cidr_ip")"
  network_int="$((ip_int & mask))"
  gateway_int="$((network_int + 1))"
  gateway_ip="$(int_to_ipv4 "$gateway_int")"

  [ "$gateway_ip" != "$cidr_ip" ] || return 1
  printf '%s\n' "$gateway_ip"
}

detect_gateway() {
  local cidr="$1"
  local current_gateway

  current_gateway="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
  if is_ipv4 "$current_gateway" && ipv4_in_cidr "$current_gateway" "$cidr"; then
    printf '%s\n' "$current_gateway"
    return 0
  fi

  infer_gateway_from_cidr "$cidr"
}

append_dns_value() {
  local dns_values="$1"
  local candidate="$2"

  case " $dns_values " in
    *" $candidate "*)
      printf '%s\n' "$dns_values"
      ;;
    *)
      printf '%s\n' "${dns_values:+$dns_values }$candidate"
      ;;
  esac
}

detect_dns_list() {
  local iface="$1"
  local fallback_gateway="$2"
  local dns_values=""
  local resolv_conf
  local token

  if command -v resolvectl >/dev/null 2>&1; then
    while read -r token; do
      if is_ipv4 "$token" && [[ "$token" != 127.* ]]; then
        dns_values="$(append_dns_value "$dns_values" "$token")"
      fi
    done < <(resolvectl dns "$iface" 2>/dev/null | tr ' ' '\n')
  fi

  for resolv_conf in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    [ -r "$resolv_conf" ] || continue
    while read -r token; do
      if is_ipv4 "$token" && [[ "$token" != 127.* ]]; then
        dns_values="$(append_dns_value "$dns_values" "$token")"
      fi
    done < <(awk '/^nameserver[[:space:]]+/ {print $2}' "$resolv_conf")
  done

  if [ -n "$dns_values" ]; then
    printf '%s\n' "$dns_values"
    return 0
  fi

  printf '%s\n' "$fallback_gateway"
}

detect_renderer() {
  local file
  local renderer

  for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    renderer="$(awk '/^[[:space:]]*renderer:[[:space:]]*/ {print $2; exit}' "$file")"
    case "$renderer" in
      networkd|NetworkManager)
        printf '%s\n' "$renderer"
        return 0
        ;;
    esac
  done

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    printf '%s\n' NetworkManager
  else
    printf '%s\n' networkd
  fi
}

normalize_dns_list() {
  local dns_list="$1"

  dns_list="${dns_list//,/ }"
  printf '%s\n' "$dns_list"
}

source_label() {
  local source="$1"

  case "$source" in
    provided)
      printf '%s\n' "provided"
      ;;
    environment)
      printf '%s\n' "environment"
      ;;
    inferred)
      printf '%s\n' "inferred"
      ;;
    default)
      printf '%s\n' "default"
      ;;
    *)
      printf '%s\n' "$source"
      ;;
  esac
}

confirm_inferred_values() {
  local confirm="$1"
  local ip_address="$2"
  local ip_source="$3"
  local iface="$4"
  local iface_source="$5"
  local gateway="$6"
  local gateway_source="$7"
  local dns_list="$8"
  local dns_source="$9"
  local renderer="${10}"
  local renderer_source="${11}"
  local apply_mode="${12}"
  local apply_mode_source="${13}"
  local has_inferred=0
  local answer
  local source

  for source in "$iface_source" "$gateway_source" "$dns_source" "$renderer_source"; do
    if [ "$source" = "inferred" ]; then
      has_inferred=1
      break
    fi
  done

  [ "$has_inferred" -eq 1 ] || return 0

  cat <<EOF
The following values include inferred settings:

  IP address: $ip_address ($(source_label "$ip_source"))
  Interface: $iface ($(source_label "$iface_source"))
  Gateway: $gateway ($(source_label "$gateway_source"))
  DNS: $dns_list ($(source_label "$dns_source"))
  Renderer: $renderer ($(source_label "$renderer_source"))
  Apply mode: $apply_mode ($(source_label "$apply_mode_source"))

EOF

  if [ "$confirm" = "true" ]; then
    echo "Confirmation skipped because --confirm was provided."
    return 0
  fi

  [ -t 0 ] || die "Inferred settings require --confirm in non-interactive mode."

  printf '%s' "Proceed with this netplan change? Type 'yes' to continue: "
  read -r answer
  [ "$answer" = "yes" ] || die "Operation cancelled."
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
  local arg
  local cfg_ip_address
  local cfg_gateway
  local cfg_dns_list
  local cfg_iface
  local cfg_renderer
  local cfg_apply_mode
  local cfg_try_timeout
  local cfg_allow_existing_iface_config
  local cfg_confirm="false"
  local ip_source=""
  local gateway_source=""
  local dns_source=""
  local iface_source=""
  local renderer_source=""
  local apply_mode_source=""
  local try_timeout_source=""
  local allow_existing_source=""
  local config_file
  local backup_file
  local conflict_files
  local dns_yaml_format
  local dns
  local stage_config_file
  local had_existing_config=0
  local -a dns_entries

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --help|-h)
        show_help
        exit 0
        ;;
      --confirm)
        cfg_confirm="true"
        ;;
      --ip)
        shift
        [ "$#" -gt 0 ] || die "--ip requires a value."
        cfg_ip_address="$1"
        ip_source="provided"
        ;;
      --ip=*)
        cfg_ip_address="${arg#*=}"
        ip_source="provided"
        ;;
      --gateway)
        shift
        [ "$#" -gt 0 ] || die "--gateway requires a value."
        cfg_gateway="$1"
        gateway_source="provided"
        ;;
      --gateway=*)
        cfg_gateway="${arg#*=}"
        gateway_source="provided"
        ;;
      --dns)
        shift
        [ "$#" -gt 0 ] || die "--dns requires a value."
        cfg_dns_list="$1"
        dns_source="provided"
        ;;
      --dns=*)
        cfg_dns_list="${arg#*=}"
        dns_source="provided"
        ;;
      --iface)
        shift
        [ "$#" -gt 0 ] || die "--iface requires a value."
        cfg_iface="$1"
        iface_source="provided"
        ;;
      --iface=*)
        cfg_iface="${arg#*=}"
        iface_source="provided"
        ;;
      --renderer)
        shift
        [ "$#" -gt 0 ] || die "--renderer requires a value."
        cfg_renderer="$1"
        renderer_source="provided"
        ;;
      --renderer=*)
        cfg_renderer="${arg#*=}"
        renderer_source="provided"
        ;;
      --mode|--apply-mode)
        shift
        [ "$#" -gt 0 ] || die "$arg requires a value."
        cfg_apply_mode="$1"
        apply_mode_source="provided"
        ;;
      --mode=*|--apply-mode=*)
        cfg_apply_mode="${arg#*=}"
        apply_mode_source="provided"
        ;;
      --timeout|--netplan-try-timeout)
        shift
        [ "$#" -gt 0 ] || die "$arg requires a value."
        cfg_try_timeout="$1"
        try_timeout_source="provided"
        ;;
      --timeout=*|--netplan-try-timeout=*)
        cfg_try_timeout="${arg#*=}"
        try_timeout_source="provided"
        ;;
      --allow-existing-iface-config)
        cfg_allow_existing_iface_config="true"
        allow_existing_source="provided"
        ;;
      --allow-existing-iface-config=*)
        cfg_allow_existing_iface_config="${arg#*=}"
        allow_existing_source="provided"
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $arg"
        ;;
      *)
        if [ -z "${cfg_ip_address:-}" ]; then
          cfg_ip_address="$arg"
          ip_source="provided"
        else
          die "Unexpected argument: $arg"
        fi
        ;;
    esac
    shift
  done

  while [ "$#" -gt 0 ]; do
    if [ -z "${cfg_ip_address:-}" ]; then
      cfg_ip_address="$1"
      ip_source="provided"
    else
      die "Unexpected argument: $1"
    fi
    shift
  done

  if [ -z "$ip_source" ]; then
    cfg_ip_address="$(get_env_value IP_ADDRESS ip_address)"
    if env_has_value IP_ADDRESS ip_address; then
      ip_source="environment"
    fi
  fi

  if [ -z "$iface_source" ]; then
    cfg_iface="$(get_env_value IFACE iface)"
    if env_has_value IFACE iface; then
      iface_source="environment"
    fi
  fi

  if [ -z "$gateway_source" ]; then
    cfg_gateway="$(get_env_value GATEWAY gateway)"
    if env_has_value GATEWAY gateway; then
      gateway_source="environment"
    fi
  fi

  if [ -z "$dns_source" ]; then
    cfg_dns_list="$(get_env_value DNS_LIST dns_list)"
    if env_has_value DNS_LIST dns_list; then
      dns_source="environment"
    fi
  fi

  if [ -z "$renderer_source" ]; then
    cfg_renderer="$(get_env_value RENDERER renderer)"
    if env_has_value RENDERER renderer; then
      renderer_source="environment"
    fi
  fi

  if [ -z "$apply_mode_source" ]; then
    cfg_apply_mode="$(get_env_value APPLY_MODE apply_mode try)"
    if env_has_value APPLY_MODE apply_mode; then
      apply_mode_source="environment"
    else
      apply_mode_source="default"
    fi
  fi

  if [ -z "$try_timeout_source" ]; then
    cfg_try_timeout="$(get_env_value NETPLAN_TRY_TIMEOUT netplan_try_timeout 30)"
    if env_has_value NETPLAN_TRY_TIMEOUT netplan_try_timeout; then
      try_timeout_source="environment"
    else
      try_timeout_source="default"
    fi
  fi

  if [ -z "$allow_existing_source" ]; then
    cfg_allow_existing_iface_config="$(get_env_value ALLOW_EXISTING_IFACE_CONFIG allow_existing_iface_config false)"
    if env_has_value ALLOW_EXISTING_IFACE_CONFIG allow_existing_iface_config; then
      allow_existing_source="environment"
    else
      allow_existing_source="default"
    fi
  fi

  [ -n "$cfg_ip_address" ] || die "IP_ADDRESS is required."
  is_ipv4_cidr "$cfg_ip_address" || die "IP_ADDRESS format is invalid. Use CIDR, e.g. 192.168.1.100/24"

  case "$cfg_renderer" in
    "")
      ;;
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

  [ "${EUID}" -eq 0 ] || die "Please run as root or use sudo."

  require_cmds ip netplan awk grep date mktemp cp chmod rm mkdir

  netplan_supports_root_dir || die "This netplan version does not support 'generate --root-dir'. Cannot safely preflight config."

  if [ -z "$cfg_renderer" ]; then
    cfg_renderer="$(detect_renderer)"
    renderer_source="inferred"
  fi

  if [ -z "$cfg_iface" ]; then
    cfg_iface="$(detect_iface)"
    iface_source="inferred"
  fi

  validate_iface_name "$cfg_iface" || die "IFACE contains unsupported characters or is longer than 15 characters."
  ip link show "$cfg_iface" >/dev/null 2>&1 || die "Network interface '$cfg_iface' does not exist."

  if [ -z "$cfg_gateway" ]; then
    cfg_gateway="$(detect_gateway "$cfg_ip_address")" || die "Could not infer GATEWAY. Set --gateway explicitly."
    gateway_source="inferred"
  fi
  is_ipv4 "$cfg_gateway" || die "GATEWAY format is invalid. Must be a valid IPv4 address."

  if [ -z "$cfg_dns_list" ]; then
    cfg_dns_list="$(detect_dns_list "$cfg_iface" "$cfg_gateway")"
    dns_source="inferred"
  fi

  cfg_dns_list="$(normalize_dns_list "$cfg_dns_list")"
  read -r -a dns_entries <<<"$cfg_dns_list"
  [ "${#dns_entries[@]}" -gt 0 ] || die "DNS_LIST must contain at least one DNS server."
  for dns in "${dns_entries[@]}"; do
    is_ipv4 "$dns" || die "DNS '$dns' is not a valid IPv4 address."
  done

  confirm_inferred_values \
    "$cfg_confirm" \
    "$cfg_ip_address" "$ip_source" \
    "$cfg_iface" "$iface_source" \
    "$cfg_gateway" "$gateway_source" \
    "$cfg_dns_list" "$dns_source" \
    "$cfg_renderer" "$renderer_source" \
    "$cfg_apply_mode" "$apply_mode_source"

  if [ "$cfg_apply_mode" = "try" ] && [ ! -t 0 ]; then
    die "APPLY_MODE=try requires an interactive terminal. Set APPLY_MODE=apply for non-interactive runs."
  fi

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
    shift
    run_set "$@"
    ;;
  *)
    echo "ERROR: Unknown command: ${1:-}" >&2
    echo >&2
    show_help
    exit 1
    ;;
esac
