# nomad-manager CNI 插件安装配置

## 背景

Nomad 的 `bridge` network mode 依赖 Linux client 节点上的 CNI reference plugins。原 `nomad-manager` 没有单独安装和配置 CNI 的入口。

## 变更内容

- 新增 `nomad-manager cni` 子命令：
  - `cni plan`：预览 CNI 下载、校验、安装、modules-load、sysctl 和 Nomad 配置变更。
  - `cni enable`：安装 CNI reference plugins，写入 Nomad client CNI 配置并重启 Nomad。
  - `cni disable`：移除托管的 Nomad CNI 配置、modules-load 配置和 sysctl 配置。
  - `cni status`：检查关键 CNI 插件、配置目录、Nomad 配置和 bridge sysctl 状态。
- 新增 `nomad-manager install --enable-cni [--cni-version v1.6.2]`，安装 Nomad 后复用同一套 CNI enable 逻辑。
- 默认 CNI 版本为 `v1.6.2`，同时接受 `1.6.2` 自动规范化为 `v1.6.2`。
- 下载 CNI release archive 后同步下载 `.sha256` 文件并校验。
- 安全解压 tar archive，拒绝路径逃逸和链接成员。
- 写入托管配置：
  - `/opt/nomad/etc/nomad.d/83-cni.hcl`
  - `/etc/modules-load.d/99-nomad-cni.conf`
  - `/etc/sysctl.d/99-nomad-cni-bridge.conf`
- `cni enable` 会加载 `bridge` 和 `br_netfilter`，并优先使用 `sysctl --system`；若失败则回退到 `sysctl -p /etc/sysctl.d/99-nomad-cni-bridge.conf`。
- 安装路径：
  - CNI plugin binaries：`/opt/cni/bin`
  - CNI config dir：`/opt/cni/config`

## 验证

- `env PYTHONPYCACHEPREFIX=/tmp/nomad-manager-pycache python3 -m py_compile nomad/nomad_tools/manager.py`
- `python3 nomad/nomad-manager cni --help`
- `python3 nomad/nomad-manager cni enable --help`
- `python3 nomad/nomad-manager cni disable --help`
- `python3 nomad/nomad-manager cni plan`
- `python3 nomad/nomad-manager cni plan --version 1.6.2`
- `python3 nomad/nomad-manager cni plan --version 1.9.1`
- `python3 nomad/nomad-manager cni status`
- `python3 nomad/nomad-manager install --help`
- `python3 nomad/nomad-manager doctor --help`
- `python3 nomad/nomad-manager tutor cni`
- `python3 nomad/nomad-manager quickstart`

## 影响范围

影响 `nomad-manager` 的 CLI、安装流程和 doctor 检查聚合逻辑。默认 `install` 行为不变，只有显式传入 `--enable-cni` 时才安装和配置 CNI。
