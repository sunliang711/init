# nomad-manager / consul-manager 帮助文案与 vault 护栏交付说明

## 目标

- 修复 `vault-jwt apply` 已包含 `vault enable` 功能但文案未说明的问题。
- 给两个 manager 的子命令说明和 tutor 加上解释，而不只是给出裸命令。
- 加一条运行时护栏，防止裸 `vault enable` 静默覆盖 `vault-jwt apply` 写入的配置。

## 为什么保留 `vault enable`

评估过直接删除 `vault enable` 子命令，结论是会丢能力，因此保留并重新定位：

- `cmd_vault_jwt_apply` 内部调用 `cmd_vault_enable` 时把 `cert_file` / `key_file` / `ca_path`
  硬编码为空串，`env=False` / `file=True` 也是写死的。`vault enable` 是配置 mTLS 客户端证书
  和 env 模式 token 的唯一入口。
- `vault_jwt_preflight` 要求 vault CLI 可用、Vault 已初始化并解封、且 token 能创建
  auth mount / policy / role。Vault 由他人管理时该路径直接失败，但用户实际只需要写 Nomad 侧配置。
- `vault-jwt` 会写 profile 并做「已存在且值不同则报错」的校验，只想改 Nomad 侧一个字段的场景不应被卷入。

定位改为：自管 Vault 用 `vault-jwt apply`（两侧一次配好）；Vault 由他人管理、或需要 mTLS /
env token 时用 `vault enable`（只写 Nomad 侧）。

## 改动范围

### 护栏

- `tools/nomad/nomad_tools/manager.py`
  - 新增 `vault_jwt_profiles()` 与 `warn_on_vault_jwt_conflict()`，在 `cmd_vault_enable` 开头调用。
  - 命中两种情况时 WARN（不阻断）：
    1. 已存在的 vault-jwt profile 的 `auth_path` 与本次要写的 `jwt_auth_backend_path` 不一致，
       会导致 Nomad 找不到已配置的 JWT mount；
    2. 探测到 Vault CA 但本次调用没传 `--ca-file` / `--ca-path`，会导致 TLS 校验失败。
  - `vault-jwt apply` 的内部调用两条都不触发，因为它传的就是 profile 的 `auth_path` 和探测到的 CA。

### 文案

- `tools/nomad/nomad_tools/manager.py`
  - `vault` / `vault enable` / `vault disable` / `vault-jwt` / `vault-jwt plan` / `vault-jwt apply`：
    说明各自只写哪一侧、互相包含关系、以及顺序反了的后果。
  - `consul` / `consul enable`：说明本机 Consul 优先用 `setup-local`，以及 workload identity 的前置条件。
  - `install` / `uninstall` / `doctor` / `telemetry` / `tls` / `ui` / `docker` / `raw-exec` / `driver` /
    `meta` / `cni`：补 description，写明副作用（重写哪个文件、重启 nomad.service、删哪些目录）。
  - tutor 15 个 topic 全部重写：解释放在命令块上方，命令块保持连续可整块复制；
    `overview` 的 topic 列表改为「topic + 一句话」两列；未知 topic 的报错列出可用 topic。
- `tools/consul/consul_tools/manager.py`
  - 同步对齐：`install` / `uninstall` / `doctor` / `acl` / `ui` / `tls` / `telemetry` / `dns` /
    `nomad-jwt` 的 description，以及 tutor `overview` 的两列列表。

### 文案规则

- 解释写在命令上方，不插入命令块内部，保证命令块可整块复制。
- 只写命令本身没表达的内容：为什么用、什么时候用、副作用、前置条件；不复述 flag 含义，避免与 `--help` 双份维护。
- 副作用优先，因为它不可见：ACL 自动 bootstrap 并写 token 文件、每个 enable/disable 都会重启服务、
  `vault-jwt apply` 顺带写 Nomad 侧、`--purge` 会删数据。
- 每个 topic 控制在 3~5 行散文加一个命令块。

## 验证结果

- `python3 -m py_compile` 覆盖两个工具的全部入口与模块
- nomad-manager 15 个 tutor topic、consul-manager 5 个 topic 全部渲染成功
- 递归遍历两个工具的全部 subparser 执行 `format_help()`：nomad-manager 60 个、consul-manager 28 个，均无异常
- 未知 tutor topic 的报错会列出全部可用 topic
- tutor 散文行宽全部收敛到 80 列以内（命令行保持原样不折行，以免破坏复制）
- 护栏断言测试三种情况：
  - profile `auth_path` 不一致 + 探测到 CA 而未传 `--ca-file` -> 两组 WARN 均触发
  - `auth_path` 一致 + 显式传 `--ca-file`（即 `vault-jwt apply` 的内部调用）-> 静默
  - 无 profile + 无 TLS -> 静默
- `bash bootstrap/verify.sh` 通过
- `git diff --check` 无告警

## 未覆盖风险

- 本次仅改文案与新增 WARN，未改变任何配置写入行为，但护栏本身未在真实 Vault 上跑过。
- 未做的结构性改动：让 Vault 侧向 Consul 侧看齐（`vault-jwt apply` 只管 Vault 侧，
  Nomad 侧统一交给 `vault enable` 或新增 `vault setup-local`）。当前 `vault-jwt apply`
  仍然同时写两侧，这是「该跑哪个」歧义的根源，文案只是缓解而非消除。
