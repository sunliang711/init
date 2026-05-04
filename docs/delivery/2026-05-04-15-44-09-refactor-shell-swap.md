# swap.sh 重构交付说明

## 重构目标

- 提升 `tools.old/swap.sh` 的幂等性、错误处理和系统文件写入安全性。
- 保持默认行为：在 Linux root 环境下创建并启用 `/var/swap.img`，默认大小约 1000MiB。

## 改动范围

- 仅修改 `tools.old/swap.sh`。
- 新增本交付说明文件。

## 保持不变的行为

- 非 root 执行时退出。
- 非 Linux 环境不执行 swap 配置。
- 默认 swap 文件路径仍为 `/var/swap.img`。
- swap 文件默认大小仍为 1000MiB。

## 主要改动

- 增加 `set -euo pipefail`。
- 拆分 root 检查、Linux 检查、依赖检查、路径校验、创建 swap、启用 swap、写入 `fstab` 等函数。
- 在写入系统文件前校验 swap 路径、目标类型、符号链接和 `/etc/fstab` 可写性。
- 使用 `dd` 创建 swap 文件，避免不同文件系统上 `fallocate` 生成的文件无法启用 swap。
- 使用 `/proc/swaps` 判断 swap 是否已启用，避免重复 `swapon`。
- 使用 `awk` 按第一列判断 `/etc/fstab` 是否已有同一路径记录，避免重复追加。
- 写入 `/etc/fstab` 前生成时间戳备份。

## 验证结果

- `bash -n tools.old/swap.sh` 通过。
- `shellcheck tools.old/swap.sh` 通过。
- 普通用户执行验证通过，按预期返回 `Error: Need run as root.`。

## 残余风险

- 未在真实 Linux root 环境执行创建 swap 和写入 `/etc/fstab` 的完整流程。
