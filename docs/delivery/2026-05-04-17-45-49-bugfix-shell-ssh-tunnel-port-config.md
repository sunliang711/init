# sshTunnel SSH port config bugfix

## Bug 定位分析

- 问题现象：`sshTunnel local --ssh shros ...` 会让 SSH 连接 `shros` 的 22 端口，而直接执行 `ssh shros` 实际使用 SSH config 中的 2000 端口。
- 根因位置：`tools/sshTunnel` 在构造 SSH 命令时默认加入 `-p 22`，覆盖了 `~/.ssh/config` 的 Host 端口配置。
- 触发条件：使用 SSH Host alias，且 alias 在 SSH config 中配置了非 22 端口，同时未显式传入 `--ssh-port`。
- 修复思路：不再默认传递 `-p 22`；仅当用户显式传入 `--ssh-port` 时才向 SSH 命令添加 `-p <port>`。
- 影响评估：默认行为恢复为 OpenSSH 原生解析逻辑；显式 `--ssh-port` 仍保持覆盖能力。

## Bug 修复摘要

- 问题：默认 SSH 端口参数覆盖了 SSH config。
- 根因：`DEFAULT_SSH_PORT=22` 且 `build_common_ssh_args` 无条件追加 `-p "$SSH_PORT"`。
- 修复方式：将默认端口改为空值，并在构造普通连接、status、stop 控制命令时仅在端口非空时追加 `-p`。
- 影响范围：`tools/sshTunnel` 的 local / remote 启动，以及后台隧道的 status / stop。
- 验证方式：执行 `bash -n tools/sshTunnel`、`shellcheck tools/sshTunnel`、默认和显式端口的 `--dry-run`。
- 回归风险：低；显式传入 `--ssh-port` 的行为保持不变。
