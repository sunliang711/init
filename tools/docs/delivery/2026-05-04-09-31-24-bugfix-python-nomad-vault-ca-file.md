# Nomad Vault ca_file

## 问题背景

提交带 `vault { ... }` 的 Nomad job 时出现：

```text
Constraint ${attr.vault.version} semver >= 0.6.1 filtered 1 node
```

## 根因分析

该约束由 Nomad 的 Vault 集成自动产生。节点被过滤通常表示 Nomad client 没有成功初始化 Vault 集成，因此没有上报 `attr.vault.version`。

在 `vault-manager install --tls-auto` 场景下，Vault 地址是 HTTPS 且使用自签 CA。此前 `nomad-manager vault-jwt apply` 写入 Nomad `vault {}` 配置时没有写入 `ca_file`，导致 Nomad client 无法验证 Vault 证书，进而无法检测 Vault 版本。

## 修复方案

- `nomad-manager vault-jwt apply` 写 Nomad Vault 配置时，自动复用 `VAULT_CACERT` 或 `/opt/vault/etc/vault.d/client.env` 中匹配当前 Vault 地址的 CA 文件。
- `nomad-manager tutor vault` 在 TLS 场景下输出 `--ca-file ...`，避免手工启用 Vault 集成时漏配 CA。

## 验证结果

- `env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/etc/vault.d/tls/ca.crt PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B nomad/nomad-manager tutor vault`
- 使用 monkey patch 验证 `cmd_vault_jwt_apply` 传给 `cmd_vault_enable` 的 `ca_file` 为 `/opt/vault/etc/vault.d/tls/ca.crt`。

## 风险与后续建议

已生成过错误 Nomad Vault 配置的节点需要重新执行 `nomad-manager vault-jwt apply ...` 或 `nomad-manager vault enable --address ... --ca-file ...`，让 `/opt/nomad/etc/nomad.d/60-vault.hcl` 更新并重启 Nomad。
