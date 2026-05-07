# GNS3 installation script

## 变更摘要

- 新增脚本：`installGns3.sh`
- 脚本目标：在 Debian / Ubuntu 上从源码安装 GNS3 相关组件
- 安装组件：
  - `ubridge`
  - `vpcs`
  - `dynamips`
  - `gns3-server`

## 入口参数

- `--workdir DIR`：源码下载和构建目录，默认 `${HOME}/gns3-build`
- `--vpcs-version VERSION`：VPCS 版本，默认 `0.8.3`
- `--skip-apt-update`：跳过 `apt-get update`
- `--run-server`：安装完成后启动 `gns3server`
- `--dry-run`：只打印计划执行的命令，不实际安装
- `-h, --help`：显示帮助

## 保护措施

- 仅支持 Debian / Ubuntu，非目标系统会退出
- 默认不启动 `gns3server`，避免安装脚本长期阻塞
- 系统写入动作统一通过 root / sudo 执行
- 构建目录禁止使用 `/`、`/usr`、`/usr/local`、`/etc`、`/var`
- 已存在的源码目录会复用；若目标路径存在但不是 Git 仓库则退出
- 不使用 `eval`、`bash -c`、`sh -c`
- 下载使用 HTTPS，未使用 `curl | sh`

## 验证情况

- 已执行：`bash -n installGns3.sh`
- 已执行：`shellcheck installGns3.sh`
- 已执行：`./installGns3.sh --help`
- 已执行：`./installGns3.sh --dry-run --workdir /tmp/gns3-build-test`
- 未执行真实安装，避免在当前 macOS 工作环境修改系统包和 `/usr/local/bin`
