# Xray 流量快照功能交付说明

## 变更摘要

- 新增 `tools/xray/traffic_snapshot/xray_traffic.py`：使用 Python 标准库实现小时采集、每日聚合、查询、汇总、CSV 导出和保留期清理。
- 新增 `tools/xray/traffic_snapshot/manage.sh`：提供安装、更新、卸载、状态查看能力。
- 新增 `tools/xray/traffic_snapshot/README.md`：记录安装布局、配置项、systemd 定时任务和查询示例。

## 运行方式

安装：

```bash
sudo tools/xray/traffic_snapshot/manage.sh install
```

更新 Python 文件：

```bash
sudo tools/xray/traffic_snapshot/manage.sh update
sudo tools/xray/traffic_snapshot/manage.sh update --py tools/xray/traffic_snapshot/xray_traffic.py
```

卸载：

```bash
sudo /opt/xray-traffic/manage.sh uninstall
sudo /opt/xray-traffic/manage.sh uninstall --purge
```

## 默认路径

- 安装目录：`/opt/xray-traffic`
- 配置文件：`/opt/xray-traffic/config/xray-traffic.env`
- SQLite：`/opt/xray-traffic/data/traffic.db`
- systemd：`/etc/systemd/system/xray-traffic-*.service` 和 `/etc/systemd/system/xray-traffic-*.timer`

## 运行环境

- Python 3.9+
- systemd
- Xray 已启用 `StatsService`

## 配置项

- `XRAY_API_SERVER`：默认 `127.0.0.1:18080`
- `XRAY_BIN`：默认 `/usr/local/bin/xray`
- `XRAY_TRAFFIC_DB`：默认 `/opt/xray-traffic/data/traffic.db`
- `XRAY_TRAFFIC_RETENTION_DAYS`：默认 `180`
- `XRAY_TRAFFIC_TIMEZONE`：默认 `Asia/Shanghai`
- `XRAY_TRAFFIC_TIMEOUT_SECONDS`：默认 `30`

## 验证

已执行 Python 编译检查、CLI help、fake stats 入库/聚合/查询、Shell 语法检查。
