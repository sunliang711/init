#!/bin/bash

set -e

# === 显示帮助信息 ===
function show_help() {
  cat <<EOF
🔧 用法:
  sudo $0 set           使用环境变量配置静态 IP
  $0 help               显示此帮助信息

📌 可用环境变量（大小写均可）:

  IP_ADDRESS  或 ip_address   静态 IP 地址（CIDR格式），如: 192.168.1.100/24
  GATEWAY     或 gateway      默认网关地址，如: 192.168.1.1
  DNS_LIST    或 dns_list     DNS 地址（空格分隔），如: "8.8.8.8 1.1.1.1"

✅ 示例:

  sudo IP_ADDRESS="192.168.66.88/24" \\
       GATEWAY="192.168.66.1" \\
       DNS_LIST="1.1.1.1 8.8.8.8" \\
       $0 set
EOF
}

# === 设置静态 IP ===
function run_set() {
  # 检查 root 权限
  if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 用户或通过 sudo 执行此命令。"
    exit 1
  fi

  # 支持小写变量
  IP_ADDRESS="${IP_ADDRESS:-${ip_address}}"
  GATEWAY="${GATEWAY:-${gateway}}"
  DNS_LIST="${DNS_LIST:-${dns_list}}"

  # 默认值
  IP_ADDRESS="${IP_ADDRESS:-192.168.1.100/24}"
  GATEWAY="${GATEWAY:-192.168.1.1}"
  DNS_LIST="${DNS_LIST:-8.8.8.8 1.1.1.1}"

  # 格式检查
  if ! echo "$IP_ADDRESS" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
    echo "❌ IP_ADDRESS 格式错误，应为 CIDR，如 192.168.1.100/24"
    exit 1
  fi

  if ! echo "$GATEWAY" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "❌ GATEWAY 格式错误，应为 IPv4 地址，如 192.168.1.1"
    exit 1
  fi

  for dns in $DNS_LIST; do
    if ! echo "$dns" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
      echo "❌ DNS 格式错误：'$dns' 不是合法 IPv4 地址"
      exit 1
    fi
  done

  # 格式化 DNS 为 YAML
  DNS_YAML_FORMAT=$(echo "$DNS_LIST" | sed 's/ /, /g')

  # 获取默认网卡
  IFACE=$(ip route | awk '/^default/ {print $5}' | head -n1)
  if [ -z "$IFACE" ]; then
    echo "❌ 未检测到默认网关对应的网络接口。"
    exit 1
  fi
  echo "📡 检测到默认网络接口: $IFACE"

  CONFIG_FILE="/etc/netplan/01-static-ip.yaml"

  # 备份
  if [ -f "$CONFIG_FILE" ]; then
    echo "📁 备份原配置到 ${CONFIG_FILE}.bak"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  fi

  # 写入配置
  echo "📝 写入 Netplan 配置..."
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

  echo "🚀 应用 Netplan 配置..."
  netplan apply

  echo "✅ 设置完成，当前网络状态："
  ip addr show "$IFACE"
  ip route show dev "$IFACE"
}

# === 解析子命令 ===
case "$1" in
  help|"")
    show_help
    ;;
  set)
    run_set
    ;;
  *)
    echo "❌ 未知命令: $1"
    echo
    show_help
    exit 1
    ;;
esac
