# domain-whitelist

`domain-whitelist` 用于在 Linux 上按域名、静态 IP 和 CIDR 网段维护整机入站来源白名单。它会定时解析域名，将域名解析结果、静态 IP 和网段写入 `nftables` set 或 `iptables + ipset`，并丢弃非白名单来源的新入站流量。

## 特性

- 新系统优先使用 `nftables`。
- 旧系统可回退到 `iptables + ipset`。
- 支持 `systemd timer`，无 systemd 时可回退到 `/etc/cron.d`。
- 支持编辑、添加、删除、启用、禁用、立即刷新和依赖检查。
- 默认只做前置来源门禁，不会自动打开原本被系统防火墙阻断的服务。

## 安装

```bash
sudo tools/domain-whitelist/install.sh
```

可选创建短命令：

```bash
sudo tools/domain-whitelist/install.sh --link
```

## 快速使用

```bash
sudo domain-whitelist add office.example.com 203.0.113.10 192.168.1.0/24 2001:db8::/32
sudo domain-whitelist config set --backend auto --interval 300
sudo domain-whitelist enable
sudo domain-whitelist status
```

`status` 中的 `enabled` 会综合状态文件和运行时规则判断；`state_enabled` 是 `/etc/domain-whitelist/state.env` 的原始记录；`runtime_backend` 是当前检测到的防火墙运行时对象。

编辑白名单：

```bash
sudo domain-whitelist edit
```

立即刷新：

```bash
sudo domain-whitelist refresh
```

查看日志：

```bash
sudo journalctl -u domain-whitelist.service -n 100 --no-pager
```

当解析结果发生变化时，会看到类似日志：

```text
INFO IPv4 whitelist changed: +1 -1
INFO + IPv4 203.0.113.10
INFO + IPv4 192.168.1.0/24
INFO - IPv4 198.51.100.20
```

禁用：

```bash
sudo domain-whitelist disable
```

## 配置文件

- `/etc/domain-whitelist/config.env`
- `/etc/domain-whitelist/whitelist.allow`
- `/etc/domain-whitelist/state.env`
- `/etc/domain-whitelist/last.v4`
- `/etc/domain-whitelist/last.v6`
- `/etc/domain-whitelist/backups/`

`whitelist.allow` 一行一个域名、IPv4、IPv6 或 CIDR 网段，支持 `#` 注释。

## 注意事项

- 域名条目最终仍然会转换成 IP 白名单，CIDR 条目会按整个网段放行；CDN 或共享 IP 场景可能扩大允许范围。
- 该工具适合动态 DNS、办公出口固定域名、合作方域名等场景。
- 启用后如果白名单为空，工具会拒绝执行；确需空白名单阻断所有新入站流量时使用 `--yes`。
- 如果系统使用 `firewalld` 或 `ufw`，它们 reload 后可能重写规则，定时刷新会再次补齐本工具的规则。
- 使用 cron 调度的旧系统，日志位置取决于发行版，常见位置是 `/var/log/syslog`、`/var/log/cron` 或 cron 服务的 journal。
