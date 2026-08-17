# domain-whitelist

`domain-whitelist` 用于在 Linux 上按域名、静态 IP 和 CIDR 网段维护整机入站来源白名单。它会定时解析域名，将域名解析结果、静态 IP 和网段写入 `nftables` set 或 `iptables + ipset`，并丢弃非白名单来源的新入站流量。

## 特性

- 新系统优先使用 `nftables`。
- 旧系统可回退到 `iptables + ipset`。
- 支持 `systemd timer`，无 systemd 时可回退到 `/etc/cron.d`。
- 支持编辑、添加、删除、启用、禁用、立即刷新和依赖检查。
- 默认只做前置来源门禁，不会自动打开原本被系统防火墙阻断的服务。
- 支持端口维度：可把某个来源限定到指定端口，也可以开放不限来源的公开端口。
- 内置 ICMPv6 处理，默认放行邻居发现和差错报文，避免 IPv6 静默失效。
- 规则原子提交：nft 走整表事务，iptables 链内容经 `iptables-restore` 单次 COMMIT 重填，
  提交失败时保留上一次生效的规则。
- DNS 解析失败按域名回退：解析失败的域名沿用它自己上次成功的地址（`resolve.cache`），
  不影响其它域名的新鲜结果；解析结果为空且无缓存可用时拒绝提交，
  不会出现「空白名单 + 全丢弃」还返回成功的情况。

## 与旧版本的差异

- `whitelist.allow` 新增 `key=value` 写法，旧的「一行一个来源」格式继续有效，无需迁移。
- `SET_TIMEOUT` 配置项和 `--timeout` 参数已废弃。集合元素不再设置超时，
  改为每次刷新整表替换。旧写法仍被接受，但不再产生任何效果。
- 新增 `version` 子命令，用于对比当前脚本与已安装副本的版本。
- `refresh` 在未启用状态下会拒绝执行，避免 `disable` 之后被手工刷新或残留 cron 悄悄装回规则；
  确需强制刷新时加 `--force`（与确认危险操作的 `--yes` 是两个开关）。
  `--dry-run` 预览不受该限制；如果检测到本工具的门禁对象仍在运行
  （通常是 state.env 丢失被重建），refresh 会继续刷新并提示状态不一致。
- `0.0.0.0/0` 和 `::/0` 这类前缀为 0 的条目会被拒绝：它等于放行整个互联网，
  且两个后端表现相反（nft 静默全放行，ipset 报错中止刷新）。
- 域名解析结果按域名缓存在 `resolve.cache`，单个域名故障只影响它自己；
  已从白名单删除的来源会在下一次刷新时立即撤销，不会被旧快照并回来。

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

`status` 中的 `enabled` 会综合状态文件和运行时规则判断；`state_enabled` 是 `/etc/domain-whitelist/state.env` 的原始记录；`runtime_backend` 是当前检测到的防火墙运行时对象。枚举型字段（`runtime_backend`、`backend`、`configured_backend`、`scheduler`）会列出全部候选值，当前值用中括号标记，例如 `scheduler=[systemd]/cron/none`。

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
sudo domain-whitelist logs
sudo domain-whitelist logs --lines 200
sudo domain-whitelist logs --follow
sudo domain-whitelist logs --cron
```

systemd 环境也可以直接使用：

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
- `/etc/domain-whitelist/resolve.cache`
- `/etc/domain-whitelist/backups/`

### whitelist.allow

支持 `#` 注释和空行。每行是一条放行规则，两种写法可以混用：

```text
# 裸来源：该来源全部端口放行（旧格式，继续有效）
office.example.com
203.0.113.10
192.168.1.0/24
2001:db8::/32

# key=value：可附加端口维度
src=office.example.com  proto=tcp  port=22
src=203.0.113.0/24      proto=tcp  port=22,443
src=10.0.0.5            proto=tcp  port=8000-8100

# 省略 src 表示该端口对所有来源开放
proto=udp  port=51820      # wireguard
proto=tcp  port=443
```

字段：`src`（域名 / IPv4 / IPv6 / CIDR）、`proto`（`tcp` 或 `udp`）、`port`
（单端口、逗号列表、连字符区间，可混写）。`proto` 与 `port` 必须成对出现，
未知字段会直接报错而不是被忽略。完整示例写在文件头部注释里，`edit` 打开即可参照。

同一来源如果既写了裸来源又写了端口限定，裸来源优先（全端口放行），
端口限定不起作用，校验时会给出警告。

`remove` 按来源匹配，会删除该来源的全部规则行；没有 `src` 的公开端口条目需要用 `edit` 手工删除。

### config.env

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `BACKEND` | `auto` | `auto` / `nft` / `iptables` |
| `REFRESH_INTERVAL` | `300` | 刷新间隔秒数 |
| `SCHEDULER` | `auto` | `auto` / `systemd` / `cron` / `none` |
| `IPV6_MODE` | `on` | `off` 时在防火墙层丢弃全部入站 IPv6 |
| `ICMPV6_ACCEPT_RA` | `1` | 放行路由通告，SLAAC 自动配置依赖它 |
| `ICMPV6_ACCEPT_MLD` | `1` | 放行组播监听发现 |
| `ICMPV6_ACCEPT_ECHO` | `0` | 放行 `ping6` |
| `ICMPV6_ACCEPT_REDIRECT` | `0` | 放行 ICMPv6 重定向 |

配置文件里缺失的键按默认值处理；升级后运行任意子命令会把新增键补写进已有的 `config.env`。

## 注意事项

- 域名条目最终仍然会转换成 IP 白名单，CIDR 条目会按整个网段放行；CDN 或共享 IP 场景可能扩大允许范围。
- 该工具适合动态 DNS、办公出口固定域名、合作方域名等场景。
- 启用后如果白名单为空，工具会拒绝执行；确需空白名单阻断所有新入站流量时使用 `--yes`。
- 使用 cron 调度的旧系统，日志位置取决于发行版，常见位置是 `/var/log/syslog`、`/var/log/cron` 或 cron 服务的 journal。

### 与其他防火墙共存

本工具的链挂在 `inet` 家族、`hook input priority -100`，早于 `iptables` 兼容层的
filter INPUT（priority 0）。链末尾的 `drop` 是终结判决，**`ufw` 和 `firewalld`
的放行规则不会有机会执行**。在跑这两者的机器上启用前，要把需要放行的来源和端口
一并写进 `whitelist.allow`，不能指望原有防火墙配置继续生效。

### 端口维度的后端差异

- `nft` 后端为每个「来源 × 端口区间」生成一条独立规则，不使用 concat set，
  因此没有内核版本要求，来源之间互相重叠（CIDR + 解析进该网段的域名）也不会导致提交失败。
- `iptables` 后端使用 `hash:net,port`，老内核可用，但端口区间会被展开成逐个端口存储，
  跨度超过 1024 的区间会被拒绝，以免撑爆 ipset。
- `IPV6_MODE=off` 在 `iptables` 后端上要求 `ip6tables` 存在：没有它就无法丢弃入站 IPv6，
  此时刷新会显式失败而不是静默留下敞开的 IPv6。

### DHCP 主机需要注意

链末尾的 `drop` 之前没有放行 DHCP。单播续租（T1 阶段）走 conntrack 的
established 不受影响，但**初次获取地址和 REBIND 阶段的广播应答不匹配 conntrack，会被丢弃**。
靠 DHCP 拿地址的云主机若在租约到期后无法续租，会掉 IP 失联。

如果机器是 DHCP 取址，启用前先确认续租行为，必要时在 `whitelist.allow` 里放行
DHCP 服务器地址，或把本工具的链优先级调到 DHCP 客户端之后。

### 关闭 IPv6

`IPV6_MODE=off` 只是防火墙层的兜底。真正关闭主机 IPv6 应当用内核 sysctl：

```bash
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
```

只想保留 IPv6 但不要自动配置时，用 `net.ipv6.conf.<iface>.accept_ra=0`，
并把 `ICMPV6_ACCEPT_RA` 设为 `0`。

不要靠「不放行邻居发现」来间接关闭 IPv6：那样主机仍有链路本地地址、仍会尝试走 IPv6，
但邻居解析永远完不成，结果是超时而不是快速失败，表现为「什么都能用但每步慢二十秒」。

### 升级

`git pull` 不会更新已安装的副本，必须重新执行 `install.sh`：

```bash
sudo tools/domain-whitelist/install.sh
```

`install.sh` 不会顺带刷新规则，新脚本会在下一次定时刷新时才被调度器使用。
用 `domain-whitelist version` 对比当前脚本与已安装副本的版本，`status` 也会在两者
不一致时给出告警。
