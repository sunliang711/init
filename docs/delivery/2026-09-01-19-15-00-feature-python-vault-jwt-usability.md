# vault jwt 参数可理解性改进交付说明

## 背景

`vault jwt apply` 有 13 个参数。`--vault-addr` / `--nomad-addr` 一看就懂，
其余的（`--auth-path` / `--role` / `--policy` / `--aud` / `--secret-path` /
`--nomad-jwks-url`）单看每一个都有说明，但**参数之间的关系**没有任何地方讲，
所以实际使用时仍然会迷糊。

排查后发现根因不在文档，而在工具自己：

- `plan` 的 `Next:` 行由 `vault_jwt_apply_command()` 生成，**把 13 个参数全部展开**，
  其中除 `--profile` / `--vault-addr` / `--nomad-addr` 外全是在复述默认值。
  用户照抄这行，于是每次都写一长串。
- 更糟的是**这行输出是坏的**：它写的是 `vault-jwt apply`，而上一轮命令链路重构
  已把该命令改名为 `vault jwt`，这个调用点漏改。照抄会直接 `invalid choice`。
- argparse 侧全部参数 `default=None`（默认值在 `prepare_profile` 里），
  所以 `--help` 印不出 "(default: ...)"，用户无从判断哪些可省，只能全写。

## 改动

### 1. 修复 `vault-jwt apply` 回归

`vault_jwt_apply_command()` 输出改为 `vault jwt apply`。新增用例断言输出的命令
**能被 parser 解析**，而不只是断言字符串内容，避免同类改名再次漏改。

### 2. `Next:` 只输出与默认值不同的参数

新增 `PROFILE_DEFAULTS` 作为唯一的默认值来源，`prepare_profile()`、help 文本、
命令生成三处共用，避免各写一份而漂移。派生值（由 `--nomad-addr` 推出的 JWKS URL）
同样省略。效果：

```
改动前  nomad-manager vault-jwt apply --profile default --vault-addr ... --nomad-addr ... --auth-path jwt-nomad --role nomad-workloads --policy nomad-workloads --aud vault.io --ttl 1h --nomad-jwks-url ... --secret-path 'kv/data/*'
改动后  nomad-manager vault jwt apply --profile default --vault-addr ... --nomad-addr ...
```

### 3. 链路图取代平铺清单

原 `profile_summary()` 是 13 行 `键: 值` 平铺输出，正是「13 个孤立参数」问题本身的
复述，已删除。改为 `jwt_wiring_diagram()`，用 profile 的真实取值渲染四段链路：

```
  Nomad signs a JWT for each task
      audience   vault.io                                   --aud
      published  http://127.0.0.1:4646/.well-known/jwks.json --nomad-addr
                            │
                            ▼
  Vault auth mount   auth/jwt-nomad
      validates  the JWT against that JWKS URL              --auth-path
                            │
                            ▼
  Vault role         nomad-workloads
      issues     tokens with TTL 1h                         --ttl
                            │
                            ▼
  Vault policy       nomad-workloads
      grants     read on kv/data/*                          --secret-path
```

在四处复用同一个函数：`plan`（取代平铺清单）、`apply`（成功后确认建成了什么）、
`doctor`（带每一环的状态）、`tutor vault-jwt`（用默认值渲染的静态版）。
`vault jwt --help` 不放图，只加一行指向 `tutor vault-jwt`，避免每次 `--help` 滚屏。

箭头字形复用已有的 `terminal_supports_checkmark()`，不支持时降级为 `|` 和 `v`。

### 4. doctor 做一致性检查

原来只逐项查「对象是否存在」，查不出两侧配置对不上。现在每一环额外比对邻接关系：

| 检查 | 抓的问题 |
|---|---|
| Vault 里的 `jwks_url` vs profile 的 JWKS URL | Nomad 换了地址，Vault 还指向旧的 |
| role 的 `bound_audiences` vs `--aud` | 两侧 audience 不一致，JWT 换不到 token |
| role 的 `token_policies` vs `--policy` | role 指向了别的 policy |
| Nomad 配置里的 `jwt_auth_backend_path` vs profile | Nomad 侧被 `vault enable` 覆盖过 |

这些情况下每个对象都存在、旧版 doctor 全绿，但链路实际是断的。

### 5. 参数分组与默认值

`add_common_vault_jwt_args()` 用 `add_argument_group` 拆成四组：connection /
what gets created in Vault / what the workloads may do / advanced，每组带一句说明，
help 文本标出默认值。

**注意**：默认值只写进 help 文本，**不能加到 argparse 的 `default=`**。
`prepare_profile()` 依赖「值为 None」来区分「用户没传」与「用户传了」，
以便回落到已存 profile；加了 argparse default 会让二次 `apply` 把 profile 里的
自定义值静默覆盖回默认。代码注释里写明了这一点。

### 6. preflight 去掉 early return，连通性前置

原来 `vault CLI not found` 会立即 `return`，后面全部检查（包括 Nomad JWKS）一条不跑，
用户只能一次修一个错。现在分成 Connectivity / Vault state / Vault permissions /
Local inputs 四段，连通性最先跑，缺 CLI 只记一个 FAIL 并把依赖 CLI 的段落标为 skipped。
地址类失败额外打印传入的地址值，因为最常见原因就是参数写错。

### 7. 说明 profile 只需设一次

`plan` 与 `apply` 结尾明确提示后续命令只需 `--profile`，并给出可直接复制的例子。

## 验证结果

- `tests/test_nomad_manager_vault_jwt.py` 13 条用例：
  - 最小命令 5 条：默认值被省略、非默认值保留、派生 JWKS URL 省略而覆盖值保留、
    **输出的命令能被 parser 解析**、命令名不含 `vault-jwt`
  - 链路图 3 条：各段与各 flag 都出现、**状态注记挂在正确的段落之间**、
    纯默认 profile 可渲染
  - 一致性检查 5 条：全部一致时 0 failure；Vault 里 JWKS 指向旧地址、
    audience 不一致、role 指向别的 policy、Nomad 配置 auth path 不一致，各报 1 failure
- 全部 6 份 Python 测试在 `-W error::ResourceWarning` 下通过
- `tests/cli-smoke.bats` 新增 3 条：Python 用例调用、help 分组与默认值、tutor 链路图
- 删除已无引用的 `profile_summary()`；无未使用 import
- 三套工具全量 `py_compile`、15 个 nomad tutor topic、`bash bootstrap/verify.sh`、
  `git diff --check` 均通过

## 未覆盖风险

- 一致性检查读取 Vault 的 `auth/<path>/config` 与 role，字段名按 Vault JWT auth 的
  文档实现（`jwks_url`、`bound_audiences`、`token_policies`），**未在真实 Vault 上验证**。
  读取失败时降级为「配置不可读」的 FAIL，不会误报为一致。
- 链路图的宽度按当前默认值排版；极长的 secret path 或 audience 会让右侧的 flag 列错开，
  不影响可读性但不再对齐。
