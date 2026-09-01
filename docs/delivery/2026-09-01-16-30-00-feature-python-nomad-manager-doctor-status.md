# nomad-manager doctor 配置可见性与 status 命令交付说明

## 背景

`doctor` 只回答「能不能跑」，不回答「现在配成什么样」。审计后发现 11 类托管配置里
doctor 只覆盖 4 类，其中 Docker 段落只查 docker CLI / daemon / socket / denylist，
完全不报 `allow_privileged`、`volumes`、`image gc` 这些真正决定 job 行为的取值。

## 审计结果

改动前的覆盖情况：

| 托管文件 | 写入命令 | 改动前 doctor |
| --- | --- | --- |
| `80-docker.hcl` | `docker enable` | 只查环境，不报任何配置取值 |
| `81-raw-exec.hcl` | `raw-exec enable` | 无 |
| `82-driver-denylist.hcl` | `driver deny` | 只在 docker 段落里查 docker 一项 |
| `70-host-volume-*.hcl` | `host-volume add` | 无 |
| `30-tls.hcl` | `tls enable` | 无 |
| `35-ui.hcl` | `ui enable` | 无 |
| `40-telemetry.hcl` | `telemetry enable` | 无 |
| `72-client-meta.hcl` | `meta set` | 无 |
| `60-vault.hcl` | `vault enable` / `vault jwt apply` | 只查托管状态与可达性 |
| `60-consul.hcl` | `consul enable` / `setup-local` | 只查托管状态、leader、ACL/WI 一致性 |
| `83-cni.hcl` | `cni enable` | 覆盖较好，缺已装插件版本 |

节点层面缺失：已装 Nomad 版本、ACL bootstrap 状态、节点是否可调度、二进制与记录版本是否一致。

## 改动

### 1. doctor 输出配置取值

新增 `INFO` 级别（`doctor_check` 的 labels 表补一项，无颜色，不计入 failures）与
`doctor_info()`。各集成段落先报当前取值，再做健康检查：

```
Docker checks:
INFO  allow_privileged = true
INFO  volumes.enabled  = true
INFO  gc.image         = true (delay 100h)
INFO  auth.config      = <unset>
[OK]  Docker config managed: /opt/nomad/etc/nomad.d/80-docker.hcl
```

Vault 段落补 address / auth path / namespace / ca_file / aud / ttl / env / file；
Consul 段落补 address / ssl / verify_ssl / grpc_address / workload identity。

配置读取由 `hcl_block_body()` 做花括号配对取块、`hcl_text_value()` 取键值实现，
按块作用域读取，避免 `enabled` 这类同名键在 `volumes` 与 `dangling_containers` 之间串味。

### 2. 三个新的 doctor 段落

- **Node runtime**：记录版本与二进制版本（不一致则 WARN 提示 `tools update`）、
  ACL token 文件或 `NOMAD_TOKEN` 是否存在、token 是否被 Nomad 接受、
  节点 `Status` / `SchedulingEligibility` / `Drain`。节点 drain 中时原先「一切正常」
  但 job 全排不上，现在直接 FAIL。
- **Node configuration**：UI / Telemetry / TLS 的当前取值；TLS 的 ca/cert/key
  文件不存在则 FAIL（nomad.service 会起不来）；`raw_exec` 启用时 WARN 提示无隔离；
  列出被禁用的驱动和 client meta。
- **Host volumes**：逐个校验宿主路径。不存在、不是目录、不可读均为 **FAIL**。

Docker 段落也补了 `auth.config` 指向的文件是否存在的检查。

### 3. 新增 `nomad-manager status`

对齐 consul-manager 已有的 `status`，集中展示「是什么」：版本、服务状态、API、
ACL token 文件、全部托管配置取值、host volume、client meta。
`status` 管「是什么」，`doctor` 管「对不对」，两者都不改动任何东西。

在 `COMMAND_GROUPS` 中归入第 1 阶段，排在 `doctor` 之后。

### 4. 记录 CNI 插件版本

`cni enable` 现在把版本写进 `83-cni.hcl` 的第二行注释（`# cni_plugin_version = ...`），
`installed_cni_version()` 读回，`cni doctor` 与 `status` 展示。
托管 marker 仍在第一行，`is_managed_file()` 不受影响；未记录版本时输出与改动前逐字节一致，
因此旧节点不会被误判为配置变更。

### 5. 顺带修复

`is_managed_file()` 和 `remove_acl_token_file()` 用 `path.open(...).readline()` 读首行，
文件句柄从未关闭。测试以 `-W error::ResourceWarning` 运行时暴露，两个工具各两处，已改为 `with`。

## 验证结果

- `tests/test_nomad_manager_doctor.py` 11 条用例，全部把托管配置常量指向临时目录，不触碰真实 `/opt/nomad`：
  - Docker / Vault / Consul 配置写入后读回取值一致
  - host volume 路径缺失、路径是普通文件、无 host volume 三种情况
  - TLS 证书缺失报 FAIL 且已存在的文件报 OK
  - `raw_exec` 启用被提示、denylist 与 meta 被列出
  - CNI 版本写入读回，且无版本时输出与改动前逐字节一致
  - 非托管配置文件报 FAIL
- 该用例在 `-W error::ResourceWarning` 下通过
- `tests/test_manager_command_groups.py` 6 条用例通过；`status` 注册位置与分组表顺序一致
  （最初放错位置，被顺序断言直接检出）
- `tests/cli-smoke.bats` 新增 4 条：两个 Python 用例的调用、`status` 的段落、`doctor` 的新段落
- 手工渲染完整配置下的 `doctor` 与 `status` 输出，确认缺失的 host volume 路径、
  缺失的 TLS key、缺失的 docker auth config 都报 FAIL
- 两套工具全量 `py_compile`、20 个 tutor topic 渲染、`bash bootstrap/verify.sh`、`git diff --check` 均通过

## 未覆盖风险

- 未在目标 Linux 机器上执行，`nomad node status -self -json` 的实际字段名
  （`Status` / `SchedulingEligibility` / `Drain`）按文档实现，未在真实 Nomad 上验证；
  解析失败时降级为 WARN 而不是 FAIL，不会造成误报失败。
- `hcl_block_body()` 用花括号配对，只对本工具生成的托管配置成立；
  若人工在托管文件的字符串里写入花括号会解析错位。托管文件本就拒绝人工修改，风险有限。
- consul-manager 的 `doctor` / `status` 未做同样的配置取值展示，两个工具在这一点上暂时不对称。
