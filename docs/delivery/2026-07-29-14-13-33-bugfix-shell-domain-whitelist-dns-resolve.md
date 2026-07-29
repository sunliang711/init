# Shell Bug 修复：domain-whitelist DNS 解析中断

## 问题现象

- 执行 `sudo domain-whitelist --verbose enable` 时，输出停在 `DEBUG Resolving www.rustez.cc`，随后退出码为 `1`。

## 根因

- DNS 解析结果可能包含 CNAME 行或空记录，例如 `dig +short AAAA www.rustez.cc` 可能只返回 `rustez.cc.`，但没有可用 IPv6 地址。
- 旧实现直接在严格模式下处理 `dig/getent` 输出，非 IP 行或解析异常可能导致流程静默中断，无法打印明确错误。

## 修复方式

- 重写 `resolve_domain`，显式捕获 `dig/getent` 的输出和退出状态。
- 对 DNS 查询失败输出 `WARN`，但不中断整个启用流程。
- 对 CNAME 等非 IP 行显式跳过。
- 如果域名没有可用 A/AAAA 记录，输出 `WARN No usable DNS records found for ...`。

## 影响范围

- 仅影响域名解析阶段。
- 不改变静态 IP、CIDR、nftables、iptables 或 systemd/cron 规则语义。

## 验证情况

- 已执行 `dig +time=3 +tries=1 +short A www.rustez.cc`。
- 已执行 `dig +time=3 +tries=1 +short AAAA www.rustez.cc`。
- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已执行 `git diff --check`。

## 未执行项

- 当前工作机不是 Linux，未实际执行 `enable` 写入防火墙规则。
