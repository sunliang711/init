# Shell 功能交付：domain-whitelist logs 子命令

## 变更摘要

- 更新 `tools/domain-whitelist/domain-whitelist`，新增 `logs` 子命令。
- 更新 `tools/domain-whitelist/README.md`，补充日志查看示例。

## 功能范围

- `domain-whitelist logs` 自动按当前调度器选择日志来源。
- 支持 `--systemd` 查看 `domain-whitelist.service` 和 `domain-whitelist.timer` 的 journal。
- 支持 `--cron` 从常见 cron 日志文件中筛选 `domain-whitelist` 记录。
- 支持 `--all` 同时查看 systemd 和 cron 历史日志。
- 支持 `--lines N` 指定日志行数。
- 支持 `--follow` 跟随日志输出。

## 保护措施

- `logs` 为只读命令，不写配置、不改防火墙、不启停服务。
- `--lines` 只允许正整数。
- 禁止 `--all --follow`，避免第一个跟随日志命令长期阻塞后续来源。

## 验证情况

- 已执行 `bash -n tools/domain-whitelist/domain-whitelist`。
- 已执行 `bash -n tools/domain-whitelist/install.sh`。
- 已执行 `shellcheck tools/domain-whitelist/domain-whitelist`。
- 已执行 `shellcheck tools/domain-whitelist/install.sh`。
- 已执行 `tools/domain-whitelist/domain-whitelist --help`。
- 已执行 `tools/domain-whitelist/domain-whitelist logs --help`。
- 已执行 `tools/domain-whitelist/domain-whitelist logs --all --follow` 错误路径。
- 已执行 `git diff --check`。

## 未执行项

- 当前工作机不是 Linux，未验证真实 systemd journal 或 cron 日志内容。
