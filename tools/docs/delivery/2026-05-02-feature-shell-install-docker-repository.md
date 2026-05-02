# installDocker 官方仓库安装改造

## 背景

`installDocker` 原实现通过 `https://get.docker.com` 下载 convenience script 并以 root/sudo 执行。该方式适合开发和测试环境，不适合作为服务器初始化工具的默认安装路径。

## 变更内容

- 移除默认执行 `get.docker.com` convenience script 的安装流程。
- 新增按发行版分支安装 Docker：
  - Ubuntu / Debian：配置 Docker 官方 apt repository。
  - RHEL / Fedora：配置 Docker 官方 rpm repository。
  - CentOS / Rocky / AlmaLinux：使用 Docker CentOS rpm repository。
  - Arch：使用 `pacman` 安装发行版 Docker 包。
- 安装包统一包含：
  - `docker-ce`
  - `docker-ce-cli`
  - `containerd.io`
  - `docker-buildx-plugin`
  - `docker-compose-plugin`
- 安装完成后确保 `/etc/docker/daemon.json` 存在；若已存在则不覆盖。
- 已存在的 `daemon.json` 会在本机有 `python3` 时进行 JSON 合法性校验。
- systemd 环境下启用并启动：
  - `containerd.service`
  - `docker.service`
- 保留 `install --dry-run`，用于预览将执行的安装步骤。
- 新增 `install --replace-conflicts`，仅在显式传入时移除 Docker 官方文档列出的旧 Docker / Podman / runc / containerd 冲突包。
- 默认检测到冲突包时失败并提示使用 `--replace-conflicts`，不自动卸载已有包。
- 不默认把当前用户加入 `docker` 组，避免默认授予 root 级权限。

## 验证

- `bash -n installDocker`
- `shellcheck installDocker`
  - 本次新增代码未引入新的 shellcheck 问题。
  - 文件中仍存在历史模板告警，集中在 `_args` 和 `_help`。
- 函数级 dry-run 验证：
  - Ubuntu 分支
  - RHEL 分支
  - Arch 分支
  - 冲突包默认失败分支
  - `--replace-conflicts` 移除冲突包分支

## 影响范围

仅影响 `installDocker install` 的 Docker 安装方式、daemon 配置确保逻辑、服务启用和安装后验证逻辑。
