# Xray traffic 安全与错误处理修复交付说明

## 修复内容

- 修复 `tools/xray/traffic/manage.sh` 的 `XRAY_TRAFFIC_HOME` 路径校验：先规范化 `APP_DIR`，再校验必须位于 `/opt` 子目录，并刷新所有派生路径。
- 修复 `xray-traffic collect hourly` 在非空 stats 输出无法解析时仍推进 metadata 的问题，避免 reset 后空入库导致流量丢失。
- 修复 `xray-traffic` 文件读写和参数边界错误：
  - `--input-file` 读取失败统一返回 `CliError`。
  - `export --output` 打开失败统一返回 `CliError`。
  - `show --limit` 必须大于 0。

## 验证

```bash
bash -n tools/xray/traffic/manage.sh
shellcheck tools/xray/traffic/manage.sh
python3 -m py_compile tools/xray/traffic/xray-traffic
XRAY_TRAFFIC_HOME=/opt/../../etc tools/xray/traffic/manage.sh status
XRAY_TRAFFIC_HOME=/opt/xray-traffic tools/xray/traffic/manage.sh status
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --db "${tmp_dir}/traffic.db" show hourly --instance default --limit -1
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --db "${tmp_dir}/traffic.db" collect hourly --instance default --input-file "${tmp_dir}/missing.json"
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --db "${tmp_dir}/traffic.db" collect hourly --instance default --input-file "${tmp_dir}/bad-stats.txt"
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --db "${tmp_dir}/traffic.db" export daily --instance default --output "${tmp_dir}/missing/out.csv"
```

以上验证均符合预期。
