# Vault tutor TLS guidance

## 问题背景

`nomad-manager tutor vault-secret-job` 的示例命令固定使用 `http://127.0.0.1:8200`。当 Vault 通过 `vault-manager install --tls-auto` 安装后，实际地址应为 `https://127.0.0.1:8200`，并且 Vault CLI 需要 `VAULT_CACERT`。

同时，示例中的 `--secret-path kv/data/app/*` 没有引用保护，复制到 shell 中可能被本地文件通配符展开。

## 根因分析

教程输出使用静态字符串，没有复用 `vault-manager` 写入的 `/opt/vault/etc/vault.d/client.env`。相关 Vault 引导命令也没有统一通过 shell quoting 生成。

## 修复方案

- `nomad-manager tutor vault-secret-job` 根据 `VAULT_ADDR` 或 `client.env` 输出 Vault 地址。
- 检测到可用 `VAULT_CACERT` 时，教程同步输出 `export VAULT_CACERT=...`。
- `vault-secret-job` 中的 `vault-jwt plan/apply` 命令改为通过 `shell_command` 生成，`kv/data/app/*` 会输出为 `'kv/data/app/*'`。
- `nomad-manager tutor vault` 和 `nomad-manager tutor vault-jwt` 也复用检测到的 Vault 地址。
- `nomad-job` 的 Vault workload identity 引导命令复用检测到的 Vault 地址。
- `nomad-manager vault doctor` 的 Vault CLI 检查补齐 `VAULT_CACERT` 继承。
- `vault-manager tutor secret`、`vault-manager tutor nomad-jwt`、`vault-manager tutor recovery`、`vault-manager tutor troubleshoot` 复用当前 `VAULT_ADDR/VAULT_CACERT` 或 client env。

## 验证结果

- `env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/etc/vault.d/tls/ca.crt PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B nomad/nomad-manager tutor vault-secret-job`
- `env VAULT_ADDR=https://127.0.0.1:8200 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B nomad/nomad-manager tutor vault-jwt`
- `env VAULT_ADDR=https://127.0.0.1:8200 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B -c 'import argparse; from nomad_tools import job; args=argparse.Namespace(vault_role="nomad-workloads", identity_aud="vault.io"); print("\n".join(job.vault_setup_commands(args)))'`
- `env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/etc/vault.d/tls/ca.crt vault/vault-manager tutor secret`
- `env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/etc/vault.d/tls/ca.crt vault/vault-manager tutor nomad-jwt`
- `env VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/etc/vault.d/tls/ca.crt vault/vault-manager tutor troubleshoot`

## 风险与后续建议

该修复只调整引导输出和本地检测逻辑，不改变实际 Vault/Nomad 配置。若用户连接远端 Vault，可以通过显式设置 `VAULT_ADDR` 控制输出。
