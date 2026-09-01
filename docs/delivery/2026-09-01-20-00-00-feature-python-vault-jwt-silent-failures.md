# vault jwt 三类静默失败的检查

## 背景

`vault jwt apply` 之后有三种情况：所有检查全绿、job 部署成功，但运行时失败。
共同点是「每个对象都存在，链路却是断的」，而失败点离出错的那条命令隔了好几步。

## 1. secrets engine 未启用

`apply` 只做 auth 侧四步：`auth enable` / 写 auth config / 写 policy / 写 role。
**从不执行 `vault secrets enable`**，全仓库里这条命令只出现在 `tutor vault-secret-job`
的文档文本里，不在任何执行路径上。

而 Vault **写 policy 时不校验挂载是否存在** —— policy 里的路径只是字符串。
所以 `kv/` 没挂载时，apply 全绿、doctor 全绿、job 部署成功，template 渲染时才失败。

另外 `generate_policy()` 把 `/data/` 替换成 `/metadata/` 生成 metadata 规则，
这本身就假定了 KV v2；挂成 v1 时路径结构不对，同样无人检查。

**改动**：新增 `vault_secret_mounts()` 与 `doctor_secret_mounts()`，在 preflight
新增 `Secret paths:` 段落，doctor 的 policy 环节同步检查：

| 情况 | 结果 |
| --- | --- |
| 挂载不存在 | FAIL，并给出 `vault secrets enable -path=<mount> kv-v2` |
| kv-v2 且路径含 `/data/` | OK |
| kv-v2 但路径不含 `/data/` | FAIL，并说明正确写法 |
| kv v1 但路径含 `/data/` | FAIL |
| 其他引擎类型（database、pki 等） | INFO，不判断路径结构 |
| 使用 `--policy-file` | INFO 跳过，授权路径工具无从得知 |

## 2. job 读的路径不在 policy 授权范围内

`job-example` 的 `--secret` 是独立参数，**此前不与 profile 的 `--secret-path` 做任何比对**。
默认 `kv/data/*` 几乎匹配一切所以平时踩不到，恰恰是把 policy 收窄之后最容易撞上。

**改动**：`require_secret_is_granted()` 在生成前比对，不匹配直接报错并给出修复命令：

```
[ERROR] Secret kv/data/other/config is not granted by profile narrow.
  The policy grants: kv/data/app/*
  Either read a granted path, or widen the policy:
    nomad-manager vault jwt apply --profile narrow --secret-path kv/data/other/config
```

匹配按 **Vault 自己的 glob 语义**实现，不能用 `fnmatch`：

- `*` **只有作为最后一个字符**时才是通配符，出现在中间是字面量
- `+` 匹配恰好一个路径层级，可以出现在任意位置
- 无通配符时要求精确匹配

`fnmatch` 会把 `kv/*/config` 判定为匹配 `kv/data/config`，而 Vault 不会。

## 3. JWKS URL 的可达性是从本机探测的

preflight 里的 `wait_http(nomad_jwks_url)` 从运行 nomad-manager 的机器发起，
**而真正要取这个 URL 的是 Vault 服务器**。单机场景两者等价；Vault 与 Nomad 分开部署时，
本机通不代表 Vault 通，preflight 显示 OK 仍可能失败。

**改动**：`--nomad-jwks-url` 与由 `--nomad-addr` 推导的值不一致时（也就是确实存在分离部署的迹象），
preflight 额外打印两行说明，并给出在 Vault 机器上验证的命令。

## 验证结果

`tests/test_nomad_manager_vault_jwt.py` 从 16 条增至 33 条，新增 17 条：

- Vault glob 7 条：末尾 `*` 前缀匹配、末尾 `*` 不匹配前缀本身、
  **中间的 `*` 是字面量**（`fnmatch` 会判错的那条）、`+` 恰好一层、
  精确路径需精确匹配、文本后接 `*`、挂载点取首段
- job-example 守卫 4 条：授权路径通过、越权路径报错且提示含修复命令、
  多条授权路径命中其一即可、`--policy-file` 时跳过
- secrets engine 6 条：挂载缺失、kv-v2 带/不带 `/data/`、kv v1 带 `/data/`、
  其他引擎类型不判断、`--policy-file` 跳过

其余：

- 全部 6 份 Python 测试在 `-W error::ResourceWarning` 下通过
- `tests/cli-smoke.bats` 新增 1 条，用临时 profile 验证越权被拒、授权通过
- 手工核对 preflight 的 `Secret paths:` 段落与 JWKS 说明行的实际输出
- 三套工具全量 `py_compile`、15 个 tutor topic、无未使用 import、
  `bash bootstrap/verify.sh`、`git diff --check` 通过

## 未覆盖风险

- `vault secrets list -format=json` 的返回结构按文档实现（`{"kv/": {"type", "options": {"version"}}}`），
  **未在真实 Vault 上验证**。列举失败时降级为 WARN 跳过，不会误报为通过。
- `+` 被当作整段通配符处理。Vault 是否支持段内混用（如 `ab+cd`）未经确认，
  当前实现只把整段等于 `+` 的情况当通配符。
- JWKS 可达性仍然只能从本机探测，改动只是把这个局限说出来，没有真正从 Vault 侧验证。
  真正的验证仍然只有跑一个真实 job。
