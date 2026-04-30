# Nomad / Vault manager help 增强交付说明

## 变更范围

- 增强 `tools/nomad/manager.sh` 顶层帮助中的子命令索引。
- 增强 `tools/nomad/manager.sh` 以下子命令帮助：
  - `telemetry`
  - `tls`
  - `ui`
  - `raw-exec`
  - `driver`
  - `host-volume`
  - `meta`
- 增强 `tools/vault/manager.sh` 顶层帮助，补充命令分组、常见流程、Token 处理、初始化/解封说明和安全说明。
- 增强 `tools/vault/manager.sh auth` 与 `tools/vault/manager.sh policy` 子命令帮助，补充参数、行为和示例。

## 行为说明

- 本次只修改帮助信息，不修改安装、卸载、配置写入、Vault auth、Vault policy 的执行逻辑。
- Nomad 配置类帮助中补充了托管文件路径、校验重启行为、常见示例和安全边界。
- Vault 帮助中补充了 `--token-file` 用法、init 输出安全性、unseal 流程和 auth/policy 管理示例。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
./tools/nomad/manager.sh help
./tools/nomad/manager.sh vault-jwt --help
./tools/nomad/manager.sh vault --help
./tools/nomad/manager.sh consul --help
./tools/nomad/manager.sh docker --help
./tools/nomad/manager.sh telemetry --help
./tools/nomad/manager.sh tls --help
./tools/nomad/manager.sh ui --help
./tools/nomad/manager.sh raw-exec --help
./tools/nomad/manager.sh driver --help
./tools/nomad/manager.sh host-volume --help
./tools/nomad/manager.sh meta --help
./tools/vault/manager.sh help
./tools/vault/manager.sh auth help
./tools/vault/manager.sh policy help
```

结果：全部通过。
