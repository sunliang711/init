# 三个 manager 支持升级 binary

## 背景

nomad-manager / consul-manager / vault-manager 只在 `install` 时落地 binary，之后没有换版本的入口。
`tools update` 只更新工具脚本本身，它的 `--<x>-version` 仅仅改写元数据里的记录值，不碰 binary——
但三个 doctor 在发现「binary 版本与记录版本不一致」时给出的建议恰恰是 `run tools update`，
这条路根本换不了 binary。

想升级只能重跑 `install`，而 `install` 会连带重写配置：consul 用 CLI 默认值重写 `consul.hcl`
并重新 bootstrap ACL，nomad 重写基础配置，vault 重写 config / TLS / client.env。
拿 `install` 当升级路径会顺手改掉节点上已经调好的东西，所以需要独立命令。

## 改动

### 版本化布局

binary 从「一个普通文件」改成「符号链接指向按版本命名的真文件」：

```
/opt/<x>/bin/versions/<x>-1.2.0   真文件（旧）
/opt/<x>/bin/versions/<x>-1.3.0   真文件（新）
/opt/<x>/bin/<x>                  -> versions/<x>-1.3.0，切换点
/usr/local/bin/<x>                -> /opt/<x>/bin/<x>，不变
```

systemd `ExecStart` 指向 `/opt/<x>/bin/<x>`，unit 文件不需要改。

切换走 `common.py` 新增的 `atomic_symlink()`：先建 `.<x>.new` 暂存链接，再 `mv -Tf` 原子 rename。
不用 `ln -sfn` 是因为它先删后建，systemd 恰好在那个窗口拉起服务就找不到文件。

`install` 也改成写这个布局。老节点第一次 `upgrade` 时由 `adopt_versioned_binary_layout()`
把普通文件搬进 `versions/` 再建链接——同一文件系统内的 `mv` 是 rename，正在执行的进程和
`ExecStart` 都不受影响；不先搬走就没有可回退的旧版本。

版本目录另起一层的原因：`/opt/<x>/bin/` 里还住着 `<x>-manager`、`<x>-job`，
按 `<x>-*` 前缀清理会把它们一起删掉。

### upgrade 命令

三个工具形态一致，归入 `COMMAND_GROUPS` 的 "Maintain and remove"：

```
<x>-manager upgrade [--version 1.21.5|latest] [--keep N] [--allow-downgrade] [--dry-run] [--yes]
```

流程：

1. **preflight**：未安装、`--keep < 1`、降级未加 `--allow-downgrade`——全部在下载之前失败。
2. **打印计划**，随后打印跨版本告警（跨 major、跳过 minor；consul 另有多 raft peer 告警）。
   `--dry-run` 在告警之后返回，预演能看到真跑会看到的全部内容。
3. **stage**：下载、校验 SHA256、解压，装进 `versions/<x>-<version>`，
   **跑一次新 binary 核对它自报的版本号**。此时链接还没动，坏包在这里就失败。
4. **切换链接 → 重启 → 等 API**（consul 还等 leader 选举，vault 接受 sealed 的 503）。
5. **失败自动回滚**：链接切回上一个版本并重启。回滚也失败时报出两次失败的原因。
6. **记录**：更新 `install.json` 的 `<x>_version`、`previous_<x>_version`、`upgraded_at`，
   同步 `TOOL_DIR/VERSION`，按 `--keep`（默认 2）清理旧版本。审计日志由既有的 `run_with_audit` 覆盖。

配置、数据目录、ACL/gossip/TLS 材料、已安装的工具文件都不动，计划里逐条写明。

各自的差异：

- **vault**：重启必然导致 sealed，计划里写明并要求手边有 unseal key，结束后打印 `unseal` 步骤。
- **consul**：正式执行前查 `operator raft list-peers`，多于一个 peer 时提示要逐台升级。
  这是纯提示，查不到不影响升级。
- **降级**：三家都额外提示 binary 能换回去、raft/存储里已经被新版本写过的状态换不回去。

### 顺带修掉的

- 三处 doctor 的错误指引 `run tools update` 改为 `run <x>-manager upgrade`。
  同时 `upgrade` 在「目标版本等于已装版本」这条空跑路径上，如果记录值与实际不符会把记录改正——
  否则 doctor 让人去跑的命令什么都不做，告警永远消不掉。
- `tools update --<x>-version` 的 help 注明它只改记录值，换 binary 请用 `upgrade`。
- `status` 增加 `binary release` 与 `kept releases` 两行。
- `uninstall` 的清理路径加入版本目录。

## 验证结果

`tests/test_manager_binary_upgrade.py` 34 条用例，三个 manager 全部参数化跑：

- 计划文本包含新旧版本、链接路径、重启对象、"Left untouched"；vault 含 sealed 提示；
  降级时含存储状态提示
- **`--dry-run` 能看到跨版本告警**（告警排在 dry-run 返回之前）
- 降级被拒且提示 `--allow-downgrade`；`--keep 0` 被拒；未安装时在下载前失败
- 同版本空跑不写记录；**记录与实际不符时空跑会把记录改正**
- 成功路径的事件序列：download → link 新版本 → restart → record → prune，
  且 prune 收到的 `current` 是刚装的那份
- **重启失败回滚**：链接切回旧版本、不写记录；`CLIError` 与 `CalledProcessError` 两种失败都覆盖
  （`restart_*_service` 第一步是 `run_root(systemctl restart)`，抛的是后者）
- 老布局在切换之前先被迁移
- `atomic_symlink` 的命令序列被逐字锁死，确保不出现 unlink
- `<x>-manager` / `<x>-job` 不会被当成 release 清理；`--keep 1` 只留正在跑的那份；
  正在跑的那份即使 mtime 最旧也不会被删
- 新 binary 自报版本与目标不符时拒绝，且链接未动
- 记录：其余字段不丢、`VERSION` 文件跟着走、state 目录只有 root 可读时改走 sudo 读取、
  两条路都读不到时只告警不写残缺记录
- `latest` 解析不到时报错而不是回落到内置默认版本（`install` 的回落行为保持不变）
- 确认提示：非 `yes` 取消、非交互时提示用 `--yes`、`--yes` 不弹提示

对「回滚只捕获 `CLIError`」和「告警排在 dry-run 之后」两处做了变异验证，改回旧写法测试会失败。

其余：全部 Python 测试 183 条通过；`tests/cli-smoke.bats` 新增 2 条（三个 `upgrade --help` 的
共同措辞、vault 的 seal 提示），断言逐条手工跑过；`bash bootstrap/verify.sh syntax` 与 `fmt-check` 通过。

## 未覆盖风险

- **没有在带 systemd 的机器上真实跑过**：下载、切换、重启、回滚整条链路只有桩测试。
- `mv -T` 是 GNU 扩展，busybox 环境不适用。这与工具已有的假设（`useradd`、`install -o/-g`）一致，
  不是新引入的可移植性问题。
- 多节点集群不在范围内：consul 只在检测到多个 raft peer 时告警，不做逐台编排；
  nomad 多 server、vault HA 同理。
- 不提供 `upgrade --rollback` 子命令。自动回滚只在「本次升级重启失败」时触发；
  事后想退回旧版本要手工改 `/opt/<x>/bin/<x>` 这个链接（旧版本按 `--keep` 留在 `versions/` 里）。
- 没有校验 HashiCorp 的 GPG 签名，只校验 SHA256SUMS，与 `install` 原有行为一致。
