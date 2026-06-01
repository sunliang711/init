# Xray 存储流量简化查看命令交付说明

## 变更摘要

- 新增 `xray_traffic.py show` 子命令，用于按小时或天查看已存储流量。
- `show` 默认等价于 `show hourly`，查询最近 1 天小时记录。
- `show daily` 默认查询最近 7 天每日记录。
- 输出会合并同一时间段、scope、name 的 up/down，展示人类可读的 `Up / Down / Total`。
- 保留 `query` 作为原始明细排查命令。

## 使用示例

```bash
/opt/xray-traffic/bin/xray_traffic.py show
/opt/xray-traffic/bin/xray_traffic.py show hourly
/opt/xray-traffic/bin/xray_traffic.py show daily
/opt/xray-traffic/bin/xray_traffic.py show hourly --scope user
```

## 验证

- `PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic_snapshot/xray_traffic.py`
- `python3 tools/xray/traffic_snapshot/xray_traffic.py show --help`
- 使用临时 SQLite 验证 `show hourly` 和 `show daily` 输出。
