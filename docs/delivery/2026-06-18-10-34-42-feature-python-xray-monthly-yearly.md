# xray-traffic monthly/yearly 功能交付

## 变更摘要

- 新增 `xray-traffic collect monthly --instance ... [--month YYYY-MM]`，默认聚合上个月，从 `daily` 快照生成持久化 `monthly` 快照。
- 新增 `xray-traffic show monthly`，直接查询 `period='monthly'`，支持 `--month YYYY-MM` 和 `--months N`。
- 新增 `xray-traffic show yearly`，从 `monthly` 快照按配置时区聚合年度结果，不写入数据库，支持 `--year YYYY` 和 `--years N`。
- 调整 `cleanup records` 为按 period 清理：`hourly` 按 retention days，`daily` 至少 62 天，`monthly` 36 个月。
- `manage.sh` 新增 monthly service/timer，每月 1 日 00:30 执行 `collect monthly --instance ALL`。
- README 和 CLI help 已同步 monthly/yearly 用法。

## 修改文件

- `tools/xray/traffic/xray-traffic`
- `tools/xray/traffic/manage.sh`
- `tools/xray/traffic/README.md`
- `tests/test_xray_traffic_show_summary.py`
- `docs/delivery/2026-06-18-10-34-42-feature-python-xray-monthly-yearly.md`

## 验证情况

```bash
PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m py_compile tools/xray/traffic/xray-traffic tests/test_xray_traffic_show_summary.py
bash -n tools/xray/traffic/manage.sh
shellcheck tools/xray/traffic/manage.sh
PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 tests/test_xray_traffic_show_summary.py
PYTHONPYCACHEPREFIX=/tmp/xray-traffic-pyc python3 -m unittest discover tests
```

结果：全部通过，`tests/test_xray_traffic_show_summary.py` 共 9 个用例通过。
