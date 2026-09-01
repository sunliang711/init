# consul-manager 单节点 Consul 工具交付说明

## 目标

- 新增 `tools/consul/consul-manager`，用与 `nomad-manager` 一致的结构管理单节点 Consul。
- Consul ACL 由 flag 控制（`--acl` / `--no-acl` / `--acl-default-policy`），两条路径都可用。
- 在 `nomad-manager` 侧补上与本机 Consul 打通所需的子命令。
- 仅使用 Python 标准库，不引入第三方依赖。

## 改动范围

- `tools/consul/consul-manager`
  - Python 入口文件，调用 `consul_tools.manager`。
- `tools/consul/consul_tools/common.py`
  - 从 `tools/nomad/nomad_tools/common.py` 复制，仅替换 `NOMAD_TOOLS_COLOR` -> `CONSUL_TOOLS_COLOR`、
    User-Agent `nomad-init-tools/1` -> `consul-init-tools/1`。按约定保持每个产品自带一份 lib 快照。
- `tools/consul/consul_tools/manager.py`
  - install / uninstall / doctor / status / tools update / acl bootstrap /
    ui / tls / telemetry / dns / nomad-jwt / quickstart / tutor。
- `tools/nomad/nomad_tools/manager.py`
  - `consul enable --address` 默认 `127.0.0.1:8500`，不再 required。
  - `consul enable` 新增 `--workload-identity` / `--no-workload-identity`。
  - 新增 `consul setup-local`、`consul token set|unset`。
  - `consul doctor` 增强：识别本机 consul-manager 安装、校验 ACL 与 workload identity 是否一致、检查 agent token。
- `tests/cli-smoke.bats`
  - 新增 4 条 help / dry-run 冒烟用例。

## 路径约定

与 `/opt/nomad`、`/opt/vault` 对齐：

| 项 | 路径 |
| --- | --- |
| 二进制 | `/opt/consul/bin/consul` -> `/usr/local/bin/consul` |
| 基础配置 | `/opt/consul/etc/consul.d/consul.hcl` |
| 托管片段 | `30-tls.hcl` / `35-ui.hcl` / `40-telemetry.hcl` / `50-dns.hcl` |
| 数据 | `/opt/consul/data/consul/agent` |
| service | `/etc/systemd/system/consul.service` |
| 工具快照 | `/opt/consul/lib/consul-init-tools` |
| 元数据 | `/opt/consul/data/consul-init-tools/install.json` |
| 审计日志 | `/opt/consul/log/consul-init-tools/manager.audit.log` |
| 管理入口 | `/usr/local/bin/consul-manager` |

## ACL 行为说明

`install` 写入的 ACL 状态同时落到 `consul.hcl` 和 `install.json` 的 `acl_enabled` 字段，
下游命令据此分支，因此两种模式下操作流程完全一致：

| 命令 | ACL 开 | ACL 关 |
| --- | --- | --- |
| `install` | 写 `acl` 块，自动 `consul acl bootstrap`，token 落 `~/consul.acl`(0600) | 不写 `acl` 块，跳过 bootstrap 并告警 |
| `nomad-jwt apply` | 建 JWT auth method + binding rule + `nomad-agent` policy/token | 打印说明后 **exit 0**（no-op，不是错误） |
| `doctor` | 检查 token 有效性、auth method、agent token 文件 | 跳过这些检查，不报 FAIL |
| `nomad-manager consul setup-local` | 装载 agent token，写带 workload identity 的配置 | 跳过 token，写不带 workload identity 的配置 |

其他行为：

- 配置写入沿用托管 marker，非托管文件默认拒绝覆盖；提交后执行 `consul validate` 与服务重启，失败自动回滚。
- `install` 会复用 `consul.hcl` 中已有的 `encrypt` gossip key，重复执行不会打断已有集群。
- `bind_addr` / `client_addr` 默认 `127.0.0.1`，需要跨主机访问时再显式放开。
- Nomad agent token 写入 `/opt/nomad/etc/consul.env`(0600) 并通过 systemd drop-in
  `/etc/systemd/system/nomad.service.d/10-consul-token.conf` 的 `EnvironmentFile` 引用，不写进 HCL 明文。
- `uninstall` 的删除计划会显式标注 `/opt/consul/data/consul` 会销毁 KV、服务目录和 ACL token，
  非 `--dry-run` 时需要输入 `yes` 确认。

## 验证结果

本机为 macOS，非目标 Linux/systemd/root 环境，已执行的验证：

- `python3 -m py_compile tools/consul/consul-manager tools/consul/consul_tools/*.py tools/nomad/nomad_tools/manager.py`
- `./tools/consul/consul-manager --help` / `install --help` / `consul --help`
- `./tools/consul/consul-manager quickstart`
- `./tools/consul/consul-manager tutor {overview,install,acl,nomad,troubleshoot}`
- `./tools/consul/consul-manager uninstall --dry-run`
- `./tools/consul/consul-manager doctor`、`acl bootstrap`、`nomad-jwt {plan,status}` 的未安装/缺 token 错误路径
- `./tools/nomad/nomad-manager consul {--help,doctor,setup-local,token set}` 的错误路径
- 配置渲染断言：`write_consul_config` 在 ACL 开/关、Connect 开/关下的输出，
  `acl_enabled_from_config` 与 `read_existing_encrypt_key` 对渲染结果的回读
- ACL bootstrap 输出的 `SecretID` 解析、`~/consul.acl` 的 token 回读
- 跨工具契约：用临时目录伪造 `install.json` 与 agent token 文件，验证
  `nomad-manager consul setup-local` 在 ACL 开/关下分别写出带/不带 workload identity 的配置，
  并在 ACL 开但 token 文件缺失时报错
- `nomad-manager consul doctor` 的 (ACL 开/关) x (workload identity 开/关) x (token 有/无) 组合矩阵，
  错配组合均报 FAIL

## 未覆盖风险

- 未在目标机执行 `install`、`uninstall`、配置写入、`consul acl bootstrap`、Consul/Nomad service restart 等
  破坏性或依赖外部环境的路径。
- `nomad-jwt` 封装 `nomad setup consul`。该子命令是否存在、是否支持 `-check`，代码在运行时探测并给出提示，
  但**未在真实 Nomad 上验证过实际输出**，需要在目标机上首次执行时确认。
- `nomad-agent` policy 目前给的是 `agent_prefix:read` + `node_prefix:read` + `service_prefix:write`，
  按 workload identity 下 Nomad agent 自注册与服务发现的最小集推导，需在目标机按实际报错校准。
- Nomad 在 Consul ACL 关闭时是否会跳过 `/v1/acl/login`，未实测。当前用
  `--workload-identity` / `--no-workload-identity` 让两种组合都可控，
  建议在目标机上把 (ACL 开/关) x (workload identity 开/关) 四种组合各跑一次并回填本文档。
- `DEFAULT_CONSUL_VERSION` 是 `resolve_version` 抓取 latest 失败时的兜底值，需要随上游发布更新。
