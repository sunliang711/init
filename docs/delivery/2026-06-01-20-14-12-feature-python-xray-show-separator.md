# Xray show 输出分割线交付说明

## 变更摘要

- 优化 `xray_traffic.py show` 输出。
- 当小时或天发生变化时，在不同时间段之间插入分割线。
- 不改变查询条件、数据存储和统计口径。

## 验证

- `PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic_snapshot/xray_traffic.py`
- 使用临时 SQLite 验证 `show hourly` 输出在不同小时之间有分割线。
