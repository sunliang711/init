#!/bin/bash

set -e

# === Show help ===
function show_help() {
  cat <<EOF
Usage:
  sudo $0 set           Set static IP using environment variables
  $0 help               Show this help message

Supported environment variables (case-insensitive):

  IP_ADDRESS or ip_address   Static IP address (CIDR), e.g. 192.168.1.100/24
  GATEWAY    or gateway      Default gateway address, e.g. 192.168.1.1
  DNS_LIST   or dns_list     DNS addresses (space separated), e.g. "8.8.8.8 1.1.1.1"

Example:

  sudo IP_ADDRESS="192.168.66.88/24" \\
       GATEWAY="192.168.66.1" \\
       DNS_LIST="1.1.1.1 8.8.8.8" \\
       $0 set
EOF
}

# === Configure static IP ===
function run_set() {
  if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root or use sudo."
    exit 1
  fi

  # Read environment variables (case-insensitive)
  IP_ADDRESS="${IP_ADDRESS:-${ip_address}}"
  GATEWAY="${GATEWAY:-${gateway}}"
  DNS_LIST="${DNS_LIST:-${dns_list}}"

  # Default values
  IP_ADDRESS="${IP_ADDRESS:-192.168.1.100/24}"
  GATEWAY="${GATEWAY:-192.168.1.1}"
  DNS_LIST="${DNS_LIST:-8.8.8.8 1.1.1.1}"

  # Validate formats
  if ! echo "$IP_ADDRESS" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
    echo "ERROR: IP_ADDRESS format is invalid. Use CIDR, e.g. 192.168.1.100/24"
    exit 1
  fi

  if ! echo "$GATEWAY" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "ERROR: GATEWAY format is invalid. Must be IPv4."
    exit 1
  fi

  for dns in $DNS_LIST; do
    if ! echo "$dns" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      echo "ERROR: DNS '$dns' is not a valid IPv4 address."
      exit 1
    fi
  done

  # Format DNS for YAML
  DNS_YAML_FORMAT=$(echo "$DNS_LIST" | sed 's/ /, /g')

  # Get default network interface
  IFACE=$(ip route | awk '/^default/ {print $5}' | head -n1)
  if [ -z "$IFACE" ]; then
    echo "ERROR: Could not detect default network interface."
    exit 1
  fi
  echo "Detected default network interface: $IFACE"

  # Remove existing DHCP-enabled netplan files
  echo "Checking for existing DHCP-enabled netplan configurations..."
  for file in /etc/netplan/*.yaml; do
    if grep -qE '^\s*dhcp4:\s*true' "$file"; then
      echo "Found DHCP-enabled file: $file"
      backup_file="${file}.bak_$(date +%s)"
      echo "Backing up original to: $backup_file"
      cp "$file" "$backup_file"
      echo "Removing: $file"
      rm -f "$file"
    fi
  done

  CONFIG_FILE="/etc/netplan/01-static-ip.yaml"

  if [ -f "$CONFIG_FILE" ]; then
    echo "Backing up existing config to: ${CONFIG_FILE}.bak"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  fi

  # Write new static config
  echo "Writing new netplan configuration to $CONFIG_FILE..."
  tee "$CONFIG_FILE" > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP_ADDRESS
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS_YAML_FORMAT]
EOF

  chmod 600 "$CONFIG_FILE"

  echo "Applying netplan configuration..."
  netplan apply

  echo "Static IP configuration applied successfully."
  echo
  echo "Current network status for interface $IFACE:"
  ip addr show "$IFACE"
  ip route show dev "$IFACE"
}

# === Command dispatcher ===
case "$1" in
  help|"")
    show_help
    ;;
  set)
    run_set
    ;;
  *)
    echo "ERROR: Unknown command: $1"
    echo
    show_help
    exit 1
    ;;
esac
