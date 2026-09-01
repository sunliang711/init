# consul-manager doctor 配置可见性与 status 增强交付说明

## 目标

把上一轮给 nomad-manager 做的「doctor 报配置取值、status 展示全量配置」同样落到
consul-manager，消除两个工具在这一点上的不对称。

## 改动

### 1. doctor 输出配置取值

复用与 nomad-manager 相同的实现方式：新增 `INFO` 级别（不计入 failures）、
`doctor_info()`、`hcl_block_body()`（花括号配对取块）、`hcl_text_value()`。

新增三个段落：

- **Node runtime**：记录版本与二进制版本（不一致 WARN 提示 `tools update`）、
  数据目录是否存在（缺失 FAIL）、工具快照是否存在。
- **Base configuration**：`consul.hcl` 的 datacenter、bind_addr、client_addr、
  ports、connect、gossip 加密开关、ACL 开关与 default_policy。
- **Node configuration**：UI / Telemetry / DNS / TLS 的当前取值，
  TLS 的 ca/cert/key 文件不存在则 FAIL（consul.service 会起不来）。

### 2. 三条新的一致性检查

这三条是 nomad-manager 没有对应物、Consul 独有的错误组合：

- `connect = true` 但 gRPC 端口为 `-1` -> **FAIL**。`install --connect --grpc-port -1`
  这种组合会让 service mesh 静默失效。
- `bind_addr` 非本地且 ACL 关闭 -> **FAIL**。`install --no-acl --bind 0.0.0.0`
  会把无认证的 API 暴露到该网段。
- ACL 开启但 `default_policy = allow` -> WARN。发了 token 但什么都不拦。

### 3. status 重写

原来只有 members、raft peers 和两行元数据，且二进制缺失时直接抛错。现在：

- Install：记录版本、二进制版本、配置目录、数据目录、工具目录、服务状态、API、ACL token 文件
- Base configuration：基础配置全部取值
- Managed configuration：ui / tls / telemetry / dns 取值
- Nomad integration：ACL 关闭时说明无需配置；否则列出 agent token 文件与 auth method 名
- members / raft peers 保留，二进制缺失时降级为提示而不再抛错

### 4. 密钥不外泄

`base_config_values()` 对 `encrypt` 只返回 `true` / `false`，**不返回密钥本身**，
doctor 与 status 全部输出都不含 gossip 密钥。有专门的用例断言这一点。

## 验证结果

- `tests/test_consul_manager_doctor.py` 11 条用例，配置常量全部指向临时目录，不触碰真实 `/opt/consul`：
  - 基础配置写入后读回取值一致
  - **gossip 密钥不出现在 `base_config_values()` 的返回值和 doctor 输出中**
  - 未配置 gossip 加密时报告 false
  - connect 开启但 grpc 为 -1 报 FAIL
  - 非本地 bind 且 ACL 关闭报 FAIL；本地 bind 且 ACL 关闭不报错
  - `default_policy = allow` 只 WARN 不 FAIL
  - 基础配置缺失报 FAIL
  - TLS 证书缺失报 FAIL 且已存在的报 OK
  - UI / Telemetry / DNS 取值读回
  - 四个片段都未配置时不算失败
- 该用例在 `-W error::ResourceWarning` 下通过
- 手工渲染完整配置下的 doctor 与 status，逐项核对输出
- `tests/cli-smoke.bats` 新增 3 条：Python 用例调用、`status` 的段落、`doctor` 的新段落
- 两套工具全量 `py_compile`、三份 Python 测试、20 个 tutor topic、无未使用 import、
  `bash bootstrap/verify.sh`、`git diff --check` 均通过

## 未覆盖风险

- 未在目标 Linux 机器上执行，`consul version` 的输出格式按 `Consul v1.x.y` 解析，
  匹配不到时降级为不显示而非报错。
- `hcl_block_body()` 用花括号配对，只对本工具生成的配置成立。基础配置 `consul.hcl`
  由 install 写入且不带托管 marker，如果人工在其中写入含花括号的字符串会解析错位。
- 「非本地 bind 且 ACL 关闭」判定只识别 `127.0.0.1` 和 `localhost` 为本地，
  绑定到其他回环地址或仅内网可达的地址时会报 FAIL，属于偏保守的误报方向。
