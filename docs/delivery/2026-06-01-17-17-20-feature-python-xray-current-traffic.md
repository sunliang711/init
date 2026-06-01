# Xray 当前累计流量子命令交付说明

## 变更摘要

- 新增 `xray_traffic.py current` 子命令，用于查询 Xray 从上次 reset 后的当前累计流量。
- `current` 调用无 reset 的 `statsquery`，不写入 SQLite，不影响小时和每日快照。
- 支持 `--scope` 和 `--name` 过滤用户、inbound tag 或 outbound tag。
- 更新 `tools/xray/traffic_snapshot/README.md`，补充当前累计流量查询示例。

## 使用示例

```bash
/opt/xray-traffic/bin/xray_traffic.py current
/opt/xray-traffic/bin/xray_traffic.py current --scope user --name alice
```

## 验证

- `PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic_snapshot/xray_traffic.py`
- `python3 tools/xray/traffic_snapshot/xray_traffic.py current --help`
- 使用临时 fake xray 命令验证 current 累计输出。
