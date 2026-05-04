# sshTunnel failure reason bugfix

## Bug 定位分析

- 问题现象：后台启动 SSH tunnel 失败时，脚本直接退出，终端没有说明认证失败、端口不可达等具体原因。
- 根因位置：`tools/sshTunnel` 执行 SSH 命令时直接依赖 `set -e` 退出，未捕获 SSH 退出码；后台模式默认使用 `-E <log>`，SSH 诊断信息可能写入日志文件而不是终端。
- 触发条件：`--background` 模式下 SSH 握手、认证、端口连接或 HostKey 校验失败。
- 修复思路：显式捕获 SSH 命令失败，打印退出码；如果存在 SSH 日志文件，输出日志尾部帮助定位原因。
- 影响评估：只增强失败路径可观测性，不改变 SSH 参数和隧道成功路径。

## Bug 修复摘要

- 问题：SSH 失败原因不可见。
- 根因：失败后由 `set -e` 直接退出，脚本没有输出错误上下文。
- 修复方式：新增失败报告逻辑，打印 SSH 退出码和日志尾部。
- 影响范围：`tools/sshTunnel` 的 local / remote 启动失败路径。
- 验证方式：执行 `bash -n tools/sshTunnel`、`shellcheck tools/sshTunnel`、`--dry-run`，并模拟后台 SSH 连接失败。
- 回归风险：低；成功路径不变，失败路径只增加错误输出。
