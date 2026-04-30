# Nomad 安装默认配置日志增强交付说明

## 变更范围

- 修改 `tools/nomad/manager.sh` 的 `write_default_managed_configs()` 安装日志。
- 安装时明确输出 `/etc/nomad.d/40-telemetry.hcl` 和 `/etc/nomad.d/80-docker.hcl` 是脚本生成的托管默认配置，不是 Nomad 官方自动生成文件。

## 日志内容

- Telemetry 默认配置说明：
  - 开启 Prometheus metrics。
  - 开启 allocation metrics。
  - 开启 node metrics。

- Docker 默认配置说明：
  - 为单节点便利性开启 privileged tasks。
  - 开启 host volume mounts。
  - 开启 image/container garbage collection。
  - 开启 Nomad labels。
  - 提示后续可用 `docker enable --allow-privileged false --volumes false` 调整为更保守配置。

## 行为说明

- 本次只增强安装日志，不修改默认配置内容和安装流程。
- 日志信息保持英文，符合脚本日志规范。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
```

结果：全部通过。
