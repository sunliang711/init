# Manager 脚本命名统一交付说明

## 变更范围

- 将 `tools/nomad/install.sh` 重命名为 `tools/nomad/manager.sh`。
- 将 `tools/vault/vault.sh` 重命名为 `tools/vault/manager.sh`。
- 保留 `tools/nomad/job` 不变，因为它是专门的 Nomad Job 管理入口。
- 同步更新交付文档中的命令路径。

## Marker 调整

- Nomad 托管配置新 marker 为 `# Managed by tools/nomad/manager.sh`。
- Vault 托管配置新 marker 为 `# Managed by tools/vault/manager.sh`。
- 脚本仍兼容旧 marker：`# Managed by installNomad.sh` 和 `# Managed by vault.sh`。

## 验证情况

- `bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job`
- `shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job`
- `./tools/nomad/manager.sh vault-jwt --help`
- `./tools/vault/manager.sh --help`
