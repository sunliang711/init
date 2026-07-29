# Shell 功能交付：domain-whitelist CIDR 支持

## 变更摘要

- 更新 `tools/domain-whitelist/domain-whitelist`，支持 IPv4/IPv6 CIDR 网段白名单。
- 更新 `tools/domain-whitelist/README.md`，补充 CIDR 示例和说明。

## 功能范围

- 白名单条目支持域名、IPv4、IPv6、IPv4 CIDR 和 IPv6 CIDR。
- `nftables` 后端 set 增加 `interval` 能力，支持 CIDR 元素。
- `iptables + ipset` 后端 set 从 `hash:ip` 升级为 `hash:net`，支持 CIDR 元素。
- 检测旧版 `nftables` set 或 `ipset hash:ip` 时，会重建本工具自有对象以兼容 CIDR。

## 保护措施

- 仍只管理本工具自有 `nftables` table、`iptables` chain 和 `ipset` set。
- CIDR 输入在写入防火墙前先校验前缀范围：IPv4 为 `0..32`，IPv6 为 `0..128`。
- 防火墙对象重建仅发生在检测到旧 schema 不支持 CIDR 时。

## 验证情况

- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `bash -n tools/domain-whitelist/install.sh`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/install.sh`。
- 已执行 `tools/domain-whitelist/domain-whitelist --help`。
- 已执行 `tools/domain-whitelist/domain-whitelist doctor`。
- 已执行 `git diff --check`。

## 未执行项

- 当前工作机不是 Linux，未实际写入 `nftables`、`iptables` 或 `ipset` 规则。
