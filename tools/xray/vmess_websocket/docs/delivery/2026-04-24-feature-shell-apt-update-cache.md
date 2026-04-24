# 功能交付记录

## 变更
- 在 `vmessWebsocket.sh` 中新增 `aptUpdateStampFile` 时间戳文件路径。
- 修改 `update_apt()`：
  - 若最近 1 小时内已成功执行过 `apt-get update`，则跳过本次更新。
  - 若未执行过或已超过 1 小时，则正常执行 `apt-get update`。
  - 仅在 `apt-get update` 成功后更新时间戳。

## 入口参数
- 无新增参数。

## 依赖命令
- `date`
- `stat`
- `touch`

## 保护措施
- 仅使用本脚本自己的时间戳文件 `/var/tmp/vmess-websocket-apt-update.stamp` 做判断。
- 不修改 `apt` 系统配置，不影响其他安装逻辑。

## 验证情况
- `bash -n vmessWebsocket.sh`
- `shellcheck vmessWebsocket.sh`

## 说明
- 当前实现按“本脚本最近一次成功执行 `apt-get update`”判断是否跳过。
