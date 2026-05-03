# Vault tls-auto duplicate SAN

## 问题

`vault-manager install --tls-auto` 在添加默认 TLS SAN 时失败：

```text
[ERROR] Failed command (1) at line 1279: return
[ERROR] Failed vault-manager command (1): install --tls-auto
```

不带 `--tls-auto` 时可以安装。

## 根因

`--tls-auto` 会自动把 `localhost`、`vault-server`、`hostname`、`hostname -f`、API 地址和集群地址加入证书 SAN。

当 `hostname` 与 `hostname -f` 相同，或默认地址重复时，去重逻辑命中：

```bash
[ "$existing" != "$value" ] || return
```

这里的 `return` 会沿用上一条测试命令的退出码 `1`。脚本启用了 `set -eEuo pipefail` 和 `ERR` trap，因此“重复值跳过”被误判为安装失败。

## 修复方式

- `add_tls_dns_name` 中重复 DNS SAN 时返回 `0`
- `add_tls_ip_address` 中重复 IP SAN 时返回 `0`
- 保留原有去重行为，不改变证书内容规则

## 验证情况

- 已执行：`bash -n vault/vault-manager`
- 已执行：`shellcheck vault/vault-manager`
- 已执行严格模式下重复 SAN 的轻量级复现验证

## 回归风险

低。修改只影响重复 SAN 的返回码，不改变安装路径、Vault 配置、证书生成参数或 systemd 流程。
