# Xray traffic 命令软链接交付说明

## 变更摘要

- `manage.sh install` 会创建 `/usr/local/bin/xray_traffic.py -> /opt/xray-traffic/bin/xray_traffic.py`。
- `manage.sh update` 也会创建或刷新该软链接，用于兼容旧版本安装后缺少软链接的情况。
- `manage.sh uninstall` 会删除本脚本管理的软链接。
- 如果 `/usr/local/bin/xray_traffic.py` 是普通文件，安装和更新会拒绝覆盖。
- 如果卸载时该软链接指向其他目标，会保留并输出警告，避免误删用户文件。

## 验证

- `bash -n tools/xray/traffic_snapshot/manage.sh`
- `shellcheck tools/xray/traffic_snapshot/manage.sh`
- `tools/xray/traffic_snapshot/manage.sh help`
- `tools/xray/traffic_snapshot/manage.sh status`
