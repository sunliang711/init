# Shell 功能交付：domain-whitelist status 枚举字段展示候选值

## 变更摘要

- 更新 `tools/domain-whitelist/domain-whitelist`，`status` 输出中的枚举型字段列出全部候选值，当前值用中括号标记。
- 更新 `tools/domain-whitelist/README.md`，补充枚举字段的格式说明。

## 功能范围

- 新增 `format_enum` 辅助函数：按固定顺序输出候选值，当前值原位加中括号；当前值不在集合内时追加在末尾。
- `runtime_backend` 展示为 `nft/iptables/none` 中标记当前值，例如 `runtime_backend=nft/iptables/[none]`。
- `backend` 与 `configured_backend` 展示为 `auto/nft/iptables` 中标记当前值。
- `scheduler` 展示为 `systemd/cron/none` 中标记当前值；检测失败的 `unknown` 追加显示为 `systemd/cron/none/[unknown]`。
- `scheduler_state`、布尔字段（`enabled`、`state_enabled`）和数值、路径字段维持原有单值输出。

## 保护措施

- 仅改变 `status` 的展示格式，不写配置、不改防火墙、不启停服务。
- 候选集合与 `validate_backend`、`detect_scheduler`、`detect_runtime_backend` 的实际取值保持一致。

## 验证情况

- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已单独测试 `format_enum` 六种情况：命中集合首、中、尾位置，以及集合外兜底值追加显示。
- 已执行 `git diff --check`。

## 未执行项

- 当前工作机不是 Linux，未在真实环境执行 `domain-whitelist status` 端到端验证。
