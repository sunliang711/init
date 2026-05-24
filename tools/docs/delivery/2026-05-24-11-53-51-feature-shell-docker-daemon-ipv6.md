# installDocker daemon IPv6 配置

## 变更摘要

- 修改脚本：`installDocker`
- 脚本目标：安装 Docker 后确保 `/etc/docker/daemon.json` 写入 Docker IPv6 配置
- 新增配置：
  - `"ipv6": true`
  - `"fixed-cidr-v6": "fd00::/80"`
  - `"ip6tables": true`

## 入口参数

- 沿用原有 `install` 命令入口
- 沿用原有 `--dry-run`
- 沿用原有 `--replace-conflicts`

## 保护措施

- 首次创建 `daemon.json` 时直接写入完整 IPv6 配置
- 已存在 `daemon.json` 时使用 JSON 解析合并，只覆盖 Docker IPv6 相关键
- 合并时保留已有其他 daemon 配置
- 已存在配置文件但不是普通文件时直接失败
- 已存在配置文件需要 `python3` 解析，缺失时直接失败，避免字符串拼接破坏 JSON
- 不改变 Docker 安装仓库、冲突包处理和服务启用流程

## 验证情况

- 已执行：`bash -n installDocker`
- 已执行：`shellcheck installDocker`
  - 本次新增代码未引入新的 shellcheck 问题
  - 文件中仍存在历史模板告警，集中在 `_args`

## 影响范围

仅影响 `installDocker install` 调用中的 `/etc/docker/daemon.json` 配置确保逻辑。
