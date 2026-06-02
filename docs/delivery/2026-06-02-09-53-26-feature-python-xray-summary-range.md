# Xray summary 时间范围展示交付说明

## 变更摘要

- 优化 `xray_traffic.py summary` 输出。
- 在汇总表格前新增 `Period`、`Range`、`Scope`、`Name` 元信息。
- 无查询结果时同样显示查询上下文，便于确认实际查询范围。
- 不改变 SQL 聚合逻辑、存储结构和统计口径。

## 示例

```text
Period: hourly
Range:  2026-06-01 00:00:00 +08:00 -> 2026-06-02 00:00:00 +08:00
Scope:  user
Name:   all
```

## 验证

- `PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic_snapshot/xray_traffic.py`
- 使用临时 SQLite 验证 `summary` 输出包含时间范围。
