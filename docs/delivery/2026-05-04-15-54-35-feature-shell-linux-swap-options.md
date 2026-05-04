# linuxSwap.sh 参数补充交付说明

## 变更目标

- 为 `tools/linuxSwap.sh` 增加可指定 swap 文件位置和大小的入口参数。
- 更新 `--help`，明确默认值、示例和大小参数生效条件。

## 改动范围

- 仅修改 `tools/linuxSwap.sh`。
- 新增本交付说明文件。

## 入口参数

- `-f PATH` / `--file PATH` / `--file=PATH`：指定 swap 文件绝对路径。
- `-s SIZE` / `--size SIZE` / `--size=SIZE`：指定 swap 大小。
- `-h` / `--help`：显示帮助信息并退出。

## 大小格式

- 裸数字按 MiB 处理，例如 `2048`。
- 支持 `M` 后缀，例如 `2048M`。
- 支持 `G` 后缀，例如 `2G`。

## 保护措施

- swap 文件路径必须是绝对路径，且不能是 `/`。
- swap 大小必须是正整数，可带 `M` 或 `G` 后缀。
- `--help` 不要求 root，不会触发任何系统修改。
- 指定大小只在 swap 文件不存在、需要创建时生效；已有 swap 文件不会被重建或调整大小。

## 验证结果

- `bash -n tools/linuxSwap.sh` 通过。
- `shellcheck tools/linuxSwap.sh` 通过。
- `bash tools/linuxSwap.sh --help` 通过。
- `bash tools/linuxSwap.sh --size 2G` 在非 root 环境按预期返回 root 权限错误。
- `bash tools/linuxSwap.sh --file relative --size 2G` 按预期拒绝相对路径。
- `bash tools/linuxSwap.sh --size 0` 按预期拒绝非法大小。
