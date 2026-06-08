# Shell 网络限速脚本交付说明

## 变更摘要

- 新增脚本：`tools/netlimit.sh`
- 支持 Debian / Ubuntu 下基于 `tc` 的全局限速、端口限速和运行时 PID 限速
- 全局和端口规则持久化到 `/etc/netlimit/rules.conf`
- 通过 `install-service` 安装 `netlimit.service`，开机后自动执行持久化规则
- PID 规则仅运行时生效，不写入持久化配置

## 入口参数

```bash
sudo tools/netlimit.sh global --dev eth0 --upload 10mbit --download 20mbit
sudo tools/netlimit.sh port --dev eth0 --port 8080 --proto tcp --side local --upload 2mbit --download 5mbit
sudo tools/netlimit.sh pid --dev eth0 --pid 12345 --upload 1mbit --download 3mbit
sudo tools/netlimit.sh install-service
sudo tools/netlimit.sh status --dev eth0
sudo tools/netlimit.sh clear --dev eth0
sudo tools/netlimit.sh reset --dev eth0
```

## 依赖命令

- `tc`
- `ip`
- `modprobe`
- `ss`，仅 PID 下载限速需要
- `systemctl`，仅安装或卸载 systemd 服务需要

## 保护措施

- 限制只在 Linux 且 `/etc/os-release` 为 Debian / Ubuntu 时运行
- 需要 root 权限，避免半成功写入系统网络配置
- 对网卡、端口、速率、协议和端口匹配方向做前置校验
- `clear` 只清理当前活跃 `tc` 规则，不删除持久化配置
- `reset` 同时清理当前活跃规则和指定网卡的持久化配置

## 已知限制

- 脚本会接管目标网卡上的 root qdisc 和 ingress qdisc，不适合与其他手写 `tc` 规则混用
- 下载限速使用 `ifb` 重定向入口流量实现
- PID 上传限速依赖 cgroup v1 `net_cls`，如果内核或系统未启用该能力会失败
- PID 下载限速是 best-effort：脚本通过 `ss` 发现当前 PID 的本地端口，再对这些端口做下载限速；未来新建连接需要重新执行
- PID 规则按方案约定不持久化，重启或进程重启后需要重新设置

## 验证方式

- `bash -n tools/netlimit.sh`
- 如目标机安装了 `shellcheck`，建议补充执行：`shellcheck tools/netlimit.sh`
