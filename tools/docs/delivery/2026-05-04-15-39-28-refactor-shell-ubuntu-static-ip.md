# ubuntu-static-ip.sh 优化与迁移

## 目标

- 将旧版 `tools.old/ubuntu-static-ip.sh` 优化后迁移到 `tools/ubuntu-static-ip.sh`。
- 保持通过环境变量设置 Ubuntu 静态 IP 的使用方式。
- 降低远程修改 netplan 配置时的断网和错误配置残留风险。

## 改动脚本

- 新增：`ubuntu-static-ip.sh`
- 删除：`../tools.old/ubuntu-static-ip.sh`

## 保持不变的行为

- 子命令仍为 `set` 和 `help`。
- 仍通过 `IP_ADDRESS`、`GATEWAY`、`DNS_LIST`、`IFACE`、`RENDERER` 等环境变量传参。
- 仍写入专用 netplan 配置文件 `/etc/netplan/99-static-${IFACE}.yaml`。

## 主要优化

- 支持 `sudo ./ubuntu-static-ip.sh set 192.168.66.88/24` 形式调用，`IP_ADDRESS` 是唯一必填业务参数。
- 保留环境变量传参兼容，同时新增 `--ip`、`--gateway`、`--dns`、`--iface`、`--renderer`、`--mode`、`--timeout` 等长参数。
- `IFACE`、`GATEWAY`、`DNS_LIST`、`RENDERER` 缺省时自动推断。
- 只要存在任意推断值，就会打印完整配置摘要并要求输入 `yes`；非交互环境必须传 `--confirm`。
- 同接口已有 netplan 配置时，会在同一次确认摘要中列出冲突文件，避免确认后才报错。
- 默认 `APPLY_MODE` 改为 `try`，远程执行时优先使用 netplan 的确认窗口降低断网风险。
- 在临时 root 目录中预生成 netplan 配置，并先执行 `netplan generate --root-dir`，通过后才写入 `/etc/netplan`。
- 写入真实配置后再次执行 `netplan generate`，失败时自动恢复旧配置文件。
- `netplan apply` 或 `netplan try` 失败时恢复旧配置文件。
- 增加接口名校验，避免非法接口名破坏 YAML 结构。
- 对已有同接口 netplan 配置默认阻断，需显式设置 `ALLOW_EXISTING_IFACE_CONFIG=true` 才允许继续。
- 修正帮助文档中大小写变量说明，并为脚本设置可执行权限。

## 验证结果

- `bash -n ubuntu-static-ip.sh` 通过。
- `shellcheck ubuntu-static-ip.sh` 通过。
- `./ubuntu-static-ip.sh help` 可正常输出帮助信息。
- `./ubuntu-static-ip.sh set --help` 可在非 root 下正常输出帮助信息。
- 非 root 执行真实 `set` 会在修改系统配置前报错退出。

## 残余风险

- 脚本仍会修改系统网络配置，生产或远程机器上建议优先使用默认 `APPLY_MODE=try`。
- 如果目标 Ubuntu 的 netplan 版本不支持 `generate --root-dir`，脚本会拒绝执行，避免无法安全预检查。
