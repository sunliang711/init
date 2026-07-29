# Shell Bug 修复：domain-whitelist enable 状态不同步

## 问题现象

- 执行 `sudo domain-whitelist enable` 后，再执行 `domain-whitelist status`，可能显示 `enabled=0`。

## 根因

- `enable` 原流程为：刷新防火墙规则、安装调度器、写入 `state.env`。
- 如果调度器安装步骤失败，或 systemd timer 在状态写入前触发刷新，状态文件可能仍保持 `ENABLED=0`。

## 修复方式

- 将 `save_state "1"` 提前到防火墙刷新成功之后、安装调度器之前。
- `status` 增加运行时检测字段：
  - `enabled`：状态文件或运行时规则任一显示启用即为 `1`。
  - `state_enabled`：`state.env` 中记录的原始状态。
  - `runtime_backend`：检测到的运行时后端，可能为 `nft`、`iptables` 或 `none`。

## 影响范围

- 仅影响 `tools/domain-whitelist/domain-whitelist` 的 `enable` 和 `status` 行为。
- 不改变白名单规则语义，不扩大防火墙管理范围。

## 验证情况

- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `bash -n tools/domain-whitelist/install.sh`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/install.sh`。
- 已执行 `tools/domain-whitelist/domain-whitelist status`。
- 已执行 `git diff --check`。

## 未执行项

- 当前工作机不是 Linux，未实际执行 `enable` 写入防火墙规则。
