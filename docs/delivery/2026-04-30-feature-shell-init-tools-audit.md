# Nomad / Vault init tools 落地与审计交付说明

## 变更范围

- `tools/nomad/manager.sh`
  - 安装时落地 Nomad 管理脚本快照。
  - 增加安装元数据、数据目录指针和审计日志。
  - 增加 `uninstall --remove-tools` 与 `uninstall --purge`。
  - 所有命令执行时输出开始/结束日志。

- `tools/vault/manager.sh`
  - 安装时落地 Vault 管理脚本快照。
  - 增加安装元数据、状态目录指针和审计日志。
  - 增加 `uninstall --remove-tools` 与 `uninstall --purge`，保留原有 `--purge-data`。
  - 所有命令执行时输出开始/结束日志。

- `tools/nomad/job`
  - 所有命令执行时输出开始/结束日志。
  - 增加 job 操作审计日志。
  - 对 validate、plan、apply、status、stop 增加明确动作日志。

## 安装后目录

Nomad:

```text
/usr/local/lib/nomad-init-tools/
/usr/local/sbin/nomad-manager
/usr/local/sbin/nomad-job
/var/lib/nomad-init-tools/install.json
/var/log/nomad-init-tools/manager.audit.log
/var/log/nomad-init-tools/job.audit.log
/var/lib/nomad/.managed-by-nomad-init-tools
```

Vault:

```text
/usr/local/lib/vault-init-tools/
/usr/local/sbin/vault-manager
/var/lib/vault-init-tools/install.json
/var/log/vault-init-tools/manager.audit.log
/opt/vault/.managed-by-vault-init-tools
```

## 卸载语义

Nomad:

- `uninstall`：删除 Nomad runtime，保留工具快照、元数据和审计日志。
- `uninstall --remove-tools`：额外删除 `/usr/local/sbin/nomad-manager`、`/usr/local/sbin/nomad-job` 和 `/usr/local/lib/nomad-init-tools`，保留元数据和审计日志。
- `uninstall --purge`：删除 runtime、工具快照、元数据和审计日志。

Vault:

- `uninstall`：删除 Vault service、binary、config，保留 `/opt/vault`、工具快照、元数据和审计日志。
- `uninstall --purge-data`：额外删除 `/opt/vault`。
- `uninstall --remove-tools`：额外删除 `/usr/local/sbin/vault-manager` 和 `/usr/local/lib/vault-init-tools`，保留元数据和审计日志。
- `uninstall --purge`：删除 runtime、Vault state、工具快照、元数据和审计日志。

## 审计日志

- 管理脚本审计日志是 JSON Lines。
- 记录时间、工具名、用户、sudo 用户、主机、cwd、脚本路径、命令、脱敏参数、结果和 exit code。
- `--token`、`--token-file`、`--key-file`、`--keys-file`、`--tls-key-file`、`--auth-config`、`--password`、`--client-secret` 会脱敏。
- 审计写入是 best-effort，不会因为日志目录不可写导致业务命令失败。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
git diff --check -- tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job docs/delivery/2026-04-30-feature-shell-init-tools-audit.md
./tools/nomad/manager.sh help
./tools/vault/manager.sh help
./tools/nomad/job help
./tools/nomad/manager.sh ui --help
./tools/vault/manager.sh auth --help
```

结果：全部通过。
