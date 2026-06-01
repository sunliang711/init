# Xray Traffic Snapshot

`xray_traffic.py` 用 Python 标准库实现 Xray 流量小时快照、每日聚合、实时速率、查询、统计、导出和清理。

运行环境要求 Python 3.9+，因为脚本使用标准库 `zoneinfo` 处理时区。

## 安装布局

安装后除 systemd 文件外，所有文件都集中在 `/opt/xray-traffic`：

```text
/opt/xray-traffic/
├── bin/
│   └── xray_traffic.py
├── config/
│   └── xray-traffic.env
├── data/
│   └── traffic.db
├── logs/
└── manage.sh
```

systemd 文件安装到：

```text
/etc/systemd/system/xray-traffic-hourly.service
/etc/systemd/system/xray-traffic-hourly.timer
/etc/systemd/system/xray-traffic-daily.service
/etc/systemd/system/xray-traffic-daily.timer
```

## 安装、更新和卸载

```bash
sudo ./manage.sh install
sudo ./manage.sh update
sudo ./manage.sh update --py ./xray_traffic.py
sudo ./manage.sh status
sudo ./manage.sh uninstall
sudo ./manage.sh uninstall --purge
```

`uninstall` 默认保留 `/opt/xray-traffic/config`、`/opt/xray-traffic/data` 和 `/opt/xray-traffic/logs`。

`uninstall --purge` 会删除整个 `/opt/xray-traffic`，包括 SQLite 数据库。

## 配置

默认配置文件：

```text
/opt/xray-traffic/config/xray-traffic.env
```

默认内容：

```bash
XRAY_API_SERVER=127.0.0.1:18080
XRAY_BIN=/usr/local/bin/xray
XRAY_TRAFFIC_DB=/opt/xray-traffic/data/traffic.db
XRAY_TRAFFIC_RETENTION_DAYS=180
XRAY_TRAFFIC_TIMEZONE=Asia/Shanghai
XRAY_TRAFFIC_TIMEOUT_SECONDS=30
```

配置优先级：

```text
命令行参数 > 环境变量 > 配置文件 > 默认值
```

例如临时查询其他 Xray API 地址：

```bash
/opt/xray-traffic/bin/xray_traffic.py --server 127.0.0.1:18080 health
```

## 定时任务

小时任务：

```text
每小时 00 分执行 xray_traffic.py hourly
```

每日任务：

```text
每天 00:10 执行 xray_traffic.py daily
```

`hourly` 默认调用：

```bash
xray api statsquery --server=127.0.0.1:18080 -reset=true
```

因此小时记录保存的是两次采集之间的增量。`daily` 不再调用 Xray，只从 SQLite 中的 `hourly` 记录聚合。

## 查询示例

查看上次 reset 后的当前累计流量：

```bash
/opt/xray-traffic/bin/xray_traffic.py current
```

查看某个用户的当前累计流量：

```bash
/opt/xray-traffic/bin/xray_traffic.py current --scope user --name alice
```

查看当前实时速率：

```bash
/opt/xray-traffic/bin/xray_traffic.py realtime
```

连续查看 5 次用户实时速率：

```bash
/opt/xray-traffic/bin/xray_traffic.py realtime --scope user --interval 1 --count 5
```

查看最近 7 天每日用户汇总：

```bash
/opt/xray-traffic/bin/xray_traffic.py summary --period daily --scope user --days 7
```

按小时查看已存储流量：

```bash
/opt/xray-traffic/bin/xray_traffic.py show hourly
```

按天查看已存储流量：

```bash
/opt/xray-traffic/bin/xray_traffic.py show daily
```

只查看用户维度的小时流量：

```bash
/opt/xray-traffic/bin/xray_traffic.py show hourly --scope user
```

查看原始明细记录：

```bash
/opt/xray-traffic/bin/xray_traffic.py query --period hourly --days 1 --limit 200
```

导出 CSV：

```bash
/opt/xray-traffic/bin/xray_traffic.py export --period daily --scope user --from 2026-05-01 --to 2026-06-01 --output users.csv
```

手工清理超过保留期的数据：

```bash
/opt/xray-traffic/bin/xray_traffic.py cleanup
```

## 数据库

默认 SQLite 文件：

```text
/opt/xray-traffic/data/traffic.db
```

核心表：

```text
traffic_records
```

主要字段：

```text
period      hourly / daily
start_ts    统计开始 Unix 时间戳
end_ts      统计结束 Unix 时间戳
scope       user / inbound / outbound
name        用户名、inbound tag 或 outbound tag
direction   up / down
bytes       字节数
```
