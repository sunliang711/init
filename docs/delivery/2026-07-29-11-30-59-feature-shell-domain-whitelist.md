# Shell 功能交付：domain-whitelist

## 变更摘要

- 新增 `tools/domain-whitelist/domain-whitelist` 管理脚本。
- 新增 `tools/domain-whitelist/install.sh` 安装脚本。
- 新增 `tools/domain-whitelist/README.md` 使用说明。

## 功能范围

- 支持按域名、IPv4、IPv6 维护整机入站来源白名单。
- 支持 `nftables` 后端，适用于较新的 Linux 系统。
- 支持 `iptables + ipset` 后端，适用于旧 Linux 系统。
- 支持 `systemd timer` 定时刷新；无 systemd 时可回退到 `/etc/cron.d`。
- 支持 `init`、`list`、`add`、`remove`、`edit`、`config show/set`、`enable`、`disable`、`refresh`、`status`、`doctor`。
- 支持记录域名解析变化导致的 IP 新增和移除日志。

## 依赖命令

- 通用：`bash`、`sed`、`sort`、`mktemp`、`install`。
- DNS 解析：优先 `dig`，缺失时使用 `getent`。
- 新后端：`nft`。
- 旧后端：`iptables`、`ipset`，IPv6 需要 `ip6tables`。
- 调度：优先 `systemctl`，旧系统可使用 `/etc/cron.d`。

## 保护措施

- 所有实际写入系统防火墙、系统目录和调度任务的命令要求 root。
- 支持 `--dry-run`，可预览写入、规则和服务操作。
- 白名单为空时默认拒绝启用或刷新，必须使用 `--yes` 才允许空白名单阻断所有新入站流量。
- 只管理自有 `nftables` table、`iptables` chain、`ipset` set 和调度任务。
- 启用后保留 `lo` 与 `established,related` 流量，避免影响本机回环和既有连接。
- 编辑、添加、删除白名单前会备份 `whitelist.allow`。
- 成功刷新后保存 `last.v4` 和 `last.v6` 快照，用于下一次刷新时生成差异日志。

## 验证情况

- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `bash -n tools/domain-whitelist/install.sh`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/install.sh`。
- 已执行 `tools/domain-whitelist/domain-whitelist --help`。
- 已执行 `tools/domain-whitelist/domain-whitelist doctor`。
- 已执行 `tools/domain-whitelist/install.sh --help`。

## 未执行项

- 当前工作机不是 Linux，未实际执行 `init`、`enable`、`disable` 或防火墙规则写入。
