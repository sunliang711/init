# vault-manager Python 重写交付说明

## 目标

- 把 `tools/vault/vault-manager`（3260 行 Bash）重写为 Python，与 nomad-manager、
  consul-manager 同构。
- 原 Bash 版本移动到 `tools/vault-sh/vault-manager` 保留，作为参照与回退。
- 不考虑向后兼容，按使用链路重排命令、补齐 doctor 与 status。

## 布局

```
tools/vault-sh/vault-manager          原 Bash 版本，git mv 保留
tools/vault/vault-manager             Python 入口
tools/vault/vault_tools/__init__.py
tools/vault/vault_tools/common.py     从 consul_tools 复制，仅改 2 处产品字面量
tools/vault/vault_tools/manager.py
```

## 顶层分组

| 阶段 | 命令 |
| --- | --- |
| 1. Set up the node | install, doctor, status |
| 2. Bring Vault online | init, unseal |
| 3. Configure Vault | auth, policy |
| 4. Maintain and remove | tools, uninstall |
| 5. Learn | quickstart, tutor |

`init` / `unseal` 单独成一个阶段，是 Vault 独有的：装完之后 Vault 处于
uninitialized + sealed，不走这两步就不可用，而 Nomad/Consul 没有对应物。
分组说明里直接写明了这一点。

## doctor 补齐的内容

原 Bash 版 doctor 只有 4 项检查（binary、config 是否托管、service 是否 active、
health endpoint），不报任何配置取值。现在：

- **INFO 报出有效配置**：api_addr、cluster_addr、listener、storage 路径、node_id、
  client.env 里的 VAULT_ADDR / VAULT_CACERT
- **解码 501 / 503**。原来笼统报成 "reachable but not ready"，但 501 是未初始化、
  503 是已封印，处置完全不同。现在分别报错并直接打印对应的修复命令
- **seal 状态**：initialized、sealed、seal threshold、ha_enabled、server version。
  `vault_status_field` 这个能力原本就有，只是 doctor 没用
- **init 输出权限**：`/opt/vault/init/*.json` 装着全部 unseal key 和 root token，
  `init` 写的是 0600 root，但此前没有任何地方复查。现在模式不是 0600 或属主不是 root
  一律 **FAIL**
- **TLS**：报 tls_disable 取值；关闭时 WARN 说明 token 明文传输；开启时校验
  cert/key 文件存在（缺失 FAIL，vault.service 会起不来），并通过
  `openssl x509 -enddate` 检查证书有效期，30 天内 WARN、已过期 FAIL
- **Node runtime**：记录版本与二进制版本比对、raft 数据目录、工具快照
- 输出改用共用的 `doctor_check`，带颜色和 ✓，与另外两个工具一致。原 Bash 版
  `doctor_check_print` 是裸 `printf`，整个脚本没有一处颜色代码

## status 重塑

原来 `status` 就是 `vault status` 透传。现在先给出「有效配置」视图（版本、路径、
服务状态、配置取值、client.env、init 输出及其权限、ACL env 文件），再把
`vault status` 的输出接在后面，不丢信息。二进制缺失时降级为提示而不抛错。

## 其他改动

- 手写的 `parse_common_vault_option` / `parse_trailing_vault_options` /
  `parse_key_values_and_vault_options` 全部由 argparse 取代。
- `uninstall` 新增 `--dry-run` 与 `--yes`，与另外两个工具对齐；删除计划显式标注
  `--purge-data` 会销毁 raft store 和 unseal key。
- 新增 `quickstart`；`tutor` 从 1 个 overview 扩到 9 个 topic。
- 已安装副本护栏：`tools update` 拒绝、`install` 告警后继续。
- `init` 增加两道保护：Vault 返回的 JSON 无法解析、或不含 unseal key 时，
  拒绝写入输出文件，避免留下一个看起来成功但没有密钥的文件。

## 验证结果

- `tests/test_vault_manager.py` 25 条用例：
  - TLS 参数解析 9 条：默认 http、`--tls-auto` 自动切 https、TLS 下 http 地址被拒、
    `--no-tls` 与 TLS 选项冲突、`--tls-auto` 与自定义证书冲突、auto 专属选项缺
    `--tls-auto`、自定义证书必须成对、证书文件必须存在、SAN 始终覆盖
    localhost/127.0.0.1/::1
  - token 与密钥文件 6 条：init JSON 取 root_token、纯文本文件、文件缺失报错、
    unseal key 优先 b64 回退 hex、非法 JSON 报错
  - 配置回读 4 条：写入后逐字段读回、**listener 与 storage 块不串味**、
    托管 marker 可识别、非托管文件被拒
  - init 输出权限 2 条：0644 报 FAIL、无文件不算失败
  - TLS doctor 3 条：关闭时只 WARN、证书缺失 FAIL 2 项、开启但未配路径 FAIL
  - 501/503 提示映射 1 条
- `tests/test_manager_command_groups.py` 与 `tests/test_manager_tool_source.py`
  扩展为覆盖三个工具，各 6 条通过；vault 的注册顺序与分组表一致
- 全部 Python 测试在 `-W error::ResourceWarning` 下通过
- `tests/cli-smoke.bats` 新增 5 条，其中一条断言 `tools/vault-sh/vault-manager help`
  仍然可用
- 22 个 subparser 全部 `format_help()` 通过；9 个 tutor topic 散文行宽 <= 80；
  help description 无超宽行；无未使用 import
- `bash bootstrap/verify.sh`、`git diff --check` 通过

## 未覆盖风险

本机是 macOS，**没有真实 Vault 可供验收**，以下路径一次都没有实际执行过：

- `install`：下载、校验、建用户、写配置、**openssl 自签证书生成**、启动服务
- `init`：真实调用 `vault operator init`、写入 unseal key 文件
- `unseal`、`auth`、`policy`：真实调用 vault CLI
- `uninstall`：删除文件

其中 **`init` 风险最高** —— 它写的是 unseal key 的唯一副本。已加的保护是：JSON
解析失败或不含 unseal key 时拒绝写文件。但真实 `vault operator init -format=json`
的输出结构未在真机核对过。

**建议的验收方式**：先在一台可丢弃的机器上跑完整流程，与 `tools/vault-sh/vault-manager`
的行为逐项比对，确认无误后再用于任何持有真实数据的节点。Bash 版本保留在
`tools/vault-sh/` 正是为此。

其他：

- `certificate_expiry()` 解析 `openssl x509 -noout -enddate` 的输出格式，
  解析失败时降级为只显示原始字符串，不报错。
- `hcl_block_body()` 用花括号配对，只对本工具生成的配置成立。
