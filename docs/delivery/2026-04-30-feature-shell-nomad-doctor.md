# Nomad Doctor 子命令交付说明

## 变更范围

- 为 `tools/nomad/manager.sh vault` 新增 `doctor` 子命令。
- 为 `tools/nomad/manager.sh consul` 新增 `doctor` 子命令。
- 为 `tools/nomad/manager.sh docker` 新增 `doctor` 子命令。

## 使用方式

```bash
./tools/nomad/manager.sh vault doctor --address http://127.0.0.1:8200
./tools/nomad/manager.sh consul doctor --address 127.0.0.1:8500
./tools/nomad/manager.sh consul doctor --address https://consul.service.consul:8501 --ssl true
./tools/nomad/manager.sh docker doctor
```

## 诊断边界

- `doctor` 是只读操作，不写入或删除 Nomad 配置。
- `vault doctor` 检查 Vault 配置片段、Nomad 配置校验、`vault` CLI 是否存在、Vault health endpoint 是否可访问。
- `consul doctor` 检查 Consul 配置片段、Nomad 配置校验、`consul` CLI 是否存在、Consul leader endpoint 是否可访问。
- `docker doctor` 检查 Docker 配置片段、Nomad 配置校验、Docker driver 是否被 denylist 禁用、`docker` CLI、Docker daemon 和 `/var/run/docker.sock`。
- Vault 和 Consul 支持远端服务，因此缺少本机 CLI 只输出 `WARN`，不会直接判定为失败。
- Docker 是本机 task driver，缺少 `docker` CLI 或 daemon 不可访问会输出 `FAIL`。

## 验证情况

- `bash -n tools/nomad/manager.sh`
- `shellcheck tools/nomad/manager.sh`
- `./tools/nomad/manager.sh vault --help`
- `./tools/nomad/manager.sh consul --help`
- `./tools/nomad/manager.sh docker --help`
- `./tools/nomad/manager.sh vault doctor --address http://127.0.0.1:8200`
- `./tools/nomad/manager.sh consul doctor --address 127.0.0.1:8500`
- `./tools/nomad/manager.sh docker doctor`
