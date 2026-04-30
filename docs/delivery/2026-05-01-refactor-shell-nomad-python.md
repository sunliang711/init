# Nomad 工具 Python 化重构交付说明

## 目标

- 将 `tools/nomad/nomad-manager` 和 `tools/nomad/nomad-job` 从 Bash 脚本重构为 Python 入口。
- 保留两个独立入口文件，公共实现拆到 `tools/nomad/nomad_tools/` 子目录。
- 仅使用 Python 标准库，不引入第三方依赖。

## 改动范围

- `tools/nomad/nomad-job`
  - 改为 Python 入口文件。
  - 调用 `nomad_tools.job`。
- `tools/nomad/nomad-manager`
  - 改为 Python 入口文件。
  - 调用 `nomad_tools.manager`。
- `tools/nomad/nomad_tools/common.py`
  - 新增日志、审计、命令执行、HCL 转义、下载、checksum、root 执行、受保护删除等公共能力。
- `tools/nomad/nomad_tools/job.py`
  - 实现 Job HCL 生成、Compose JSON 转换、validate/plan/apply/status/stop、tutor。
- `tools/nomad/nomad_tools/manager.py`
  - 实现 install/uninstall、Vault/Consul/Telemetry/TLS/UI/Docker/raw_exec/driver/host-volume/meta、Vault JWT、doctor、tutor。

## 行为说明

- 本次按“完全 Python 化，不要求历史参数和输出完全兼容”的约束执行。
- Compose YAML 转换在标准库约束下依赖 `docker compose config --format json`，JSON Compose 输入可直接解析。
- Vault JWT profile 改为 JSON 文件：`/opt/nomad/data/vault-jwt/<profile>.json`。
- 配置写入仍使用托管 marker，非托管配置文件默认拒绝覆盖。
- Nomad 配置提交仍保留验证失败和服务重启失败后的回滚逻辑。

## 验证结果

- `PYTHONPYCACHEPREFIX=/tmp/nomad-tools-pycache python3 -m py_compile tools/nomad/nomad-job tools/nomad/nomad-manager tools/nomad/nomad_tools/*.py`
- `./tools/nomad/nomad-job --help`
- `./tools/nomad/nomad-manager --help`
- `./tools/nomad/nomad-job scaffold docker --job web --image nginx:1.27 --port http:8080:80 --check-http / --out -`
- `./tools/nomad/nomad-job compose convert /tmp/nomad-tools-compose.json --out -`
- `./tools/nomad/nomad-manager tutor install`
- `./tools/nomad/nomad-manager vault-jwt plan --profile default --vault-addr http://127.0.0.1:8200 --nomad-addr http://127.0.0.1:4646`
- `VAULT_JWT_PROFILE_DIR=/tmp/nomad-vault-jwt-test ./tools/nomad/nomad-manager vault-jwt job-example --profile default --job app --secret kv/data/app --out -`
- `./tools/nomad/nomad-manager docker doctor`
- `git diff --check -- tools/nomad/nomad-job tools/nomad/nomad-manager tools/nomad/nomad_tools`

## 未覆盖风险

- 本机不是目标 Linux/systemd/root 环境，未实际执行 `install`、`uninstall`、配置写入、Nomad service restart、Vault 写入等破坏性或外部依赖路径。
- YAML Compose 输入需要目标环境存在 Docker Compose。
- 新 CLI 允许调整参数和输出，但仍需要在目标机器上按真实运维流程做一次端到端验收。
