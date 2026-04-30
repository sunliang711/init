# Nomad Job 管理脚本交付说明

## 变更范围

- 新增 Nomad Job 管理脚本，入口为 `tools/nomad/job`。
- 提供 Docker Job HCL 生成、Docker Compose 转 Nomad HCL、Job 校验、计划、应用、状态和停止命令。

## 主要命令

```bash
./tools/nomad/job scaffold docker --job web --image nginx:alpine --out jobs/web.nomad.hcl
./tools/nomad/job compose convert docker-compose.yml --out jobs/app.nomad.hcl
./tools/nomad/job validate jobs/app.nomad.hcl
./tools/nomad/job plan jobs/app.nomad.hcl
./tools/nomad/job apply jobs/app.nomad.hcl
./tools/nomad/job apply jobs/app.nomad.hcl --auto-approve
./tools/nomad/job status
./tools/nomad/job stop web
```

## Docker Scaffold 支持

- `--env KEY=VALUE` 和 `--env-file FILE`
- `--port name:to` 或 `--port name:static:to`
- `--mount bind:/host:/container:ro`
- `--mount volume:name:/container:rw`
- `--mount tmpfs:/container`
- `--host-volume volume_name:/container:ro`
- `--cpu`、`--memory`、`--count`
- `--service-name`、`--check-http`、`--check-tcp`
- `--vault-role`、`--identity-aud`、`--template-file`

## Compose 转换策略

- 优先使用 `docker compose -f FILE config --format json` 获取规范化 Compose JSON。
- Docker Compose 不可用时，回退到 Python `yaml` 模块。
- 支持转换 `image`、`environment`、`env_file`、`ports`、`volumes`、`deploy.replicas`、`deploy.resources.limits`。
- `depends_on`、`build`、`healthcheck` 等不能完全等价转换的字段会写入 warning。
- 命名 volume 默认转 Docker volume mount；传 `--volume-root PATH` 时转为该目录下的 bind mount。

## 安全策略

- 输出文件默认不覆盖，必须传 `--force`。
- `apply` 默认先执行 `nomad job validate` 和 `nomad job plan`，再要求输入 `yes`。
- `apply --auto-approve` 才会跳过交互确认。
- 脚本不读取或打印 Vault token、Nomad token 等敏感环境变量。

## 验证情况

- `bash -n tools/nomad/job`
- `shellcheck tools/nomad/job`
- `./tools/nomad/job --help`
- `./tools/nomad/job scaffold docker ...`
- `nomad job validate /tmp/nomad-job-test/web.nomad.hcl`
- `./tools/nomad/job compose convert /tmp/nomad-job-test/compose.yml ...`
- `nomad job validate /tmp/nomad-job-test/compose.nomad.hcl`
- `./tools/nomad/job validate /tmp/nomad-job-test/web.nomad.hcl`
- 验证输出文件默认不覆盖。
- 验证未知命令按预期报错。
