# nomad-manager / consul-manager 子命令按使用链路重构交付说明

## 目标

- 两个 manager 的顶层 usage 都按「实际使用顺序」分组，取代原来的扁平无序列表。
- 子命令列表同样按链路排序，推荐路径排在前面。
- 修掉结构错位与重复入口。
- 不考虑向后兼容，删掉的直接删，不留转发别名。

## nomad-manager 顶层分组

`COMMAND_GROUPS` 声明分组，帮助文本由它生成：

| 阶段 | 命令 |
| --- | --- |
| 1. Set up the node | install, doctor |
| 2. Enable capabilities | docker, cni, raw-exec, driver, vault, consul |
| 3. Provide resources to jobs | host-volume, meta |
| 4. Tune the node | ui, tls, telemetry |
| 5. Run jobs | export（并指向 nomad-job） |
| 6. Maintain and remove | tools, uninstall |
| 7. Learn | quickstart, tutor |

两处分组判断的理由：

- `meta` 归入第 3 阶段而非第 4。`ui` / `tls` / `telemetry` 改的是节点自身行为，
  `meta` 存在的唯一目的是让 job 拿去做 constraint，和 `host-volume` 同类。
- `raw-exec` / `driver` 归入第 2 阶段。它们和 `docker` 一样是任务驱动，属于启用能力而非调优。

## consul-manager 顶层分组

| 阶段 | 命令 |
| --- | --- |
| 1. Set up the node | install, acl, doctor, status |
| 2. Connect Nomad | nomad-jwt |
| 3. Tune the node | ui, dns, tls, telemetry |
| 4. Maintain and remove | tools, uninstall |
| 5. Learn | quickstart, tutor |

Consul 的对外集成只有 Nomad 一个，所以第 2 阶段直接叫 Connect Nomad 而不是套用
nomad-manager 的 Enable capabilities。`acl` 归入第 1 阶段，因为它是 install 没能自动完成
bootstrap 时的补救步骤。

## 结构性改动

nomad-manager：

| 原 | 现 | 理由 |
| --- | --- | --- |
| 顶层 `vault-jwt` | `vault jwt` | 它是 Vault 集成的一半，不应与 `vault` 平级 |
| `docker disable-driver` / `enable-driver` | 删除 | 与 `driver deny\|allow docker` 是同一操作，原实现就是直接转发 |
| `vault-jwt status` | 删除 | `cmd_vault_jwt_doctor` = `status` + 一行 Fix 提示，是严格超集 |
| `cni status` | `cni doctor` | 「检查」在全工具统一为 `doctor` |

顶层命令 19 -> 18，叶子命令 45 -> 42。

consul-manager：

| 原 | 现 | 理由 |
| --- | --- | --- |
| `nomad-jwt status` | `nomad-jwt doctor` | 与「检查统一叫 doctor」一致；对应函数同步改名为 `cmd_nomad_jwt_doctor` |

顶层命令数量不变（13），仅重排与改名。顶层 `status` 保留，它列出 members 和 raft peers，
属于信息展示而不是健康检查，与 `doctor` 职责不同。

## 子命令排序

改为「推荐路径在前」而不是 enable/disable 的惯性顺序：

- `nomad-manager vault`: jwt, enable, doctor, disable
- `nomad-manager consul`: setup-local, enable, token, doctor, disable
- `nomad-manager cni`: plan, enable, doctor, disable
- `nomad-manager docker`: enable, doctor, disable
- `consul-manager nomad-jwt`: plan, apply, doctor

## 防漂移

argparse 不支持给 subparser 分组，实现上给 `add_subparsers` 设了 `metavar`、去掉顶层
`add_parser` 的 `help=`，改由 `description` 输出由 `COMMAND_GROUPS` 生成的分组列表。
代价是分组表可能与实际注册的命令脱节，因此新增 `tests/test_manager_command_groups.py`，
对两个工具各跑一遍：

- 每个已注册命令都出现在分组表里
- 分组表里没有已不存在的命令
- 没有命令被分到两个组
- 分组顺序与 parser 的注册顺序完全一致
- root help 包含全部分组标题
- 全部 subparser 都能 `format_help()`

`tests/cli-smoke.bats` 增加一条用例调用它，因此 `bootstrap/verify.sh` 会执行到。

## 连带改动

- 两个工具的 `quickstart` 都重写为与各自分组同序的流程。
- 两个工具的 `tutor overview` topic 列表按同一链路重排。
- 两个工具根 parser 的 `epilog` 示例按链路顺序重排。
- 全部 `vault-jwt` 命令行改为 `vault jwt`，包括 tutor 文本、`cmd_vault_jwt_doctor` 的
  Fix 提示、`job-example` 生成文件的头注释、以及 `warn_on_vault_jwt_conflict` 的告警。
- `docker` 的 description 改为指向 `driver deny docker`。

## 验证结果

- `python3 -m py_compile` 覆盖 nomad 与 consul 两套工具的全部入口与模块
- `tests/test_manager_command_groups.py` 6 条用例通过，每条对两个工具各跑一遍
- 防漂移用例做了反向验证：注入一个未归组的命令后确实被检出，
  分组表残留一个已删除命令后也被检出
- 手工核对新命令树：`vault jwt` 可用、`vault-jwt` 已消失、
  `docker disable-driver` / `enable-driver` 已消失、`cni doctor` 生效、
  `consul-manager nomad-jwt doctor` 生效且 `status` 已消失
- nomad-manager 15 个、consul-manager 5 个 tutor topic 全部渲染，散文行宽 <= 80
- 无未使用的 import；`grouped_command_names` / `registered_command_names`
  仅被测试引用，属于有意保留的测试接口
- `bash bootstrap/verify.sh` 通过，`git diff --check` 无告警

## 未覆盖风险

- `export` 属于任务操作，结构上应迁到 `nomad-job`，本轮未做（跨工具改动）。
- `nomad-job` 自身仍是扁平命令列表，未做同样的分组处理。
- `tools/vault/vault-manager` 是 Bash 实现，它本来就有 `Command groups:` 段落，
  但分组名与这两个 Python 工具不一致，未统一。
- 未在目标 Linux 机器上执行任何实际安装或配置写入路径，本次改动仅涉及 CLI 结构与文案。
