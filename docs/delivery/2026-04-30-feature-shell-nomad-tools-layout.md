# Nomad 工具目录调整交付说明

## 变更范围

- 新增目录 `tools/nomad/`，作为 Nomad 相关脚本的主目录。
- 将安装与配置脚本移动到 `tools/nomad/manager.sh`。
- 将 Job 管理脚本移动到 `tools/nomad/job`。
- 不再保留 `tools/installNomad.sh` 和 `tools/nomad-job` wrapper，统一使用 `tools/nomad/` 下入口。

## 推荐入口

```bash
./tools/nomad/manager.sh help
./tools/nomad/manager.sh install --version 2.0.0
./tools/nomad/manager.sh vault-jwt plan --profile default --vault-addr http://127.0.0.1:8200 --nomad-addr http://10.2.37.64:4646
./tools/nomad/job --help
./tools/nomad/job scaffold docker --job web --image nginx:alpine --out jobs/web.nomad.hcl
```

## 验证情况

- `bash -n tools/nomad/manager.sh tools/nomad/job`
- `shellcheck tools/nomad/manager.sh tools/nomad/job`
- `./tools/nomad/manager.sh vault-jwt --help`
- `./tools/nomad/job --help`
