# Nomad Wrapper 移除交付说明

## 变更范围

- 删除 `tools/installNomad.sh`。
- 删除 `tools/nomad-job`。
- 统一使用 `tools/nomad/manager.sh` 和 `tools/nomad/job`。
- 同步清理交付文档中的兼容入口说明。

## 当前入口

```bash
./tools/nomad/manager.sh help
./tools/nomad/manager.sh install --version 2.0.0
./tools/nomad/manager.sh vault-jwt --help
./tools/nomad/job --help
./tools/nomad/job scaffold docker --job web --image nginx:alpine --out jobs/web.nomad.hcl
```

## 验证情况

- `bash -n tools/nomad/manager.sh tools/nomad/job`
- `shellcheck tools/nomad/manager.sh tools/nomad/job`
- `./tools/nomad/manager.sh vault-jwt --help`
- `./tools/nomad/job --help`
- `test ! -e tools/installNomad.sh`
- `test ! -e tools/nomad-job`
