# Xray 实时流量子命令交付说明

## 变更摘要

- 新增 `xray_traffic.py realtime` 子命令，用于查看 Xray 当前实时流量速率。
- `realtime` 通过两次无 reset 的 `statsquery` 采样计算 bytes/s，不写入 SQLite，不影响小时和每日快照。
- 支持 `--interval`、`--count`、`--scope`、`--name` 参数。
- 更新 `tools/xray/traffic_snapshot/README.md`，补充实时速率查询示例。

## 使用示例

```bash
/opt/xray-traffic/bin/xray_traffic.py realtime
/opt/xray-traffic/bin/xray_traffic.py realtime --scope user --interval 1 --count 5
```

## 验证

- `PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic_snapshot/xray_traffic.py`
- `python3 tools/xray/traffic_snapshot/xray_traffic.py realtime --help`
- 使用临时 fake xray 命令验证 realtime 采样输出。
