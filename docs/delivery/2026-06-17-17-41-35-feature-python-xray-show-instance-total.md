# Xray show 多实例小计交付说明

## 变更摘要

- `xray-traffic show hourly` 和 `xray-traffic show daily` 在 `--instance ALL` 命中多个实例时，会在每个周期明细后追加 `Instance` 为 `ALL` 的跨实例小计行。
- 小计按 `period + scope + name` 聚合，分别累加原始 `up/down` bytes，再输出格式化后的 `Total`。
- 单实例查询保持原有输出，不追加小计行。
- 小计使用同一过滤条件下未被 `--limit` 截断的记录聚合，避免明细输出限制导致漏算。
- 更新 `tools/xray/traffic/README.md` 和 `show` 帮助说明。

## 影响范围

- 修改文件：`tools/xray/traffic/xray-traffic`
- 修改文档：`tools/xray/traffic/README.md`
- 新增测试：`tests/test_xray_traffic_show_summary.py`
- 不涉及数据库 schema、采集逻辑、daily 聚合逻辑和配置项变更。

## 验证

```bash
PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic/xray-traffic tests/test_xray_traffic_show_summary.py
PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 tests/test_xray_traffic_show_summary.py
```
