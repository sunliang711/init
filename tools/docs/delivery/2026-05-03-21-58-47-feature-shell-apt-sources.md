# Ubuntu/Debian apt source script

## 变更摘要

- 新增脚本：`aptSources.sh`
- 删除旧脚本：`ubuntuSources/ubuntuSources.sh`、`debianSources/debianSources.sh`、`debianSources.sh`、`setLinuxSystemSoftwareSource.sh`
- 脚本目标：统一生成 Ubuntu / Debian apt 官方源或常用镜像源配置

## 入口参数

- `--mirror NAME`：选择镜像预设，支持 `official`、`tuna`、`ustc`、`aliyun`、`163`，默认 `official`
- `--mirror-url URL`：使用自定义镜像站根地址或仓库地址
- `--mirror-security`：安全更新源也使用所选镜像
- `--format FORMAT`：选择 `auto`、`deb822`、`list`，默认 `auto`
- `--output FILE`：指定输出文件
- `--no-backports`：不生成 backports 源
- `--dry-run`：仅打印将写入内容，默认行为
- `--apply`：实际写入源文件
- `--update`：写入后执行 `apt-get update`

## 保护措施

- 默认 dry-run，不写入系统文件
- `--apply` 模式要求 root 权限
- 写入前检查系统类型、codename、目标路径和必要命令
- 写入前自动备份已有目标文件
- 只写目标源文件，不主动清理 `sources.list.d` 下的其他第三方源文件
- 临时文件使用 `mktemp`，写入后设置为 `0644`
- 不使用 `eval`、`bash -c`、`sh -c`

## 验证情况

- 已执行：`bash -n aptSources.sh`
- 已执行：`shellcheck aptSources.sh`
- 已执行：`./aptSources.sh --help`
- 未执行真实 `--apply` 换源，避免在当前非目标环境修改系统 apt 配置
