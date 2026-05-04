# swap.sh 帮助参数交付说明

## 变更目标

- 为 `tools.old/swap.sh` 增加帮助参数，便于执行前查看用途、默认值和副作用。

## 改动范围

- 仅修改 `tools.old/swap.sh`。
- 新增本交付说明文件。

## 入口参数

- `-h`：显示帮助信息并退出。
- `--help`：显示帮助信息并退出。
- 无参数：保持原有创建并启用 swap 的流程。

## 保护措施

- `-h` 和 `--help` 不要求 root，不会触发 Linux 检查、依赖检查、swap 创建或 `/etc/fstab` 写入。
- 非法参数会报错退出，避免传错参数时继续执行系统修改。
- 参数数量超过一个会报错退出。

## 验证结果

- `bash -n tools.old/swap.sh` 通过。
- `shellcheck tools.old/swap.sh` 通过。
- `bash tools.old/swap.sh --help` 通过，退出码为 0。
