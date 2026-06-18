# Xray Traffic Snapshot

`xray-traffic` 用 Python 标准库实现 Xray 多实例流量小时快照、每日聚合、每月聚合、当前累计查询、历史展示、汇总、导出和清理。

运行环境要求 Python 3.9+，因为脚本使用标准库 `zoneinfo` 处理时区。

## 安装布局

安装后除 systemd 文件外，所有文件都集中在 `/opt/xray-traffic`：

```text
/opt/xray-traffic/
├── bin/
│   └── xray-traffic
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
/etc/systemd/system/xray-traffic-monthly.service
/etc/systemd/system/xray-traffic-monthly.timer
```

同时安装命令行软链接：

```text
/usr/local/bin/xray-traffic -> /opt/xray-traffic/bin/xray-traffic
```

## 安装、更新和卸载

```bash
sudo ./manage.sh install
sudo ./manage.sh update
sudo ./manage.sh update --py ./xray-traffic
sudo ./manage.sh status
sudo ./manage.sh uninstall
sudo ./manage.sh uninstall --purge
```

`uninstall` 默认保留 `/opt/xray-traffic/config`、`/opt/xray-traffic/data` 和 `/opt/xray-traffic/logs`。

`uninstall --purge` 会删除整个 `/opt/xray-traffic`，包括 SQLite 数据库。

卸载时会删除本脚本管理的 `/usr/local/bin/xray-traffic` 软链接；如果该路径是普通文件或指向其他目标的软链接，则会保留并输出警告。

## 配置

默认配置文件：

```text
/opt/xray-traffic/config/xray-traffic.env
```

默认内容：

```bash
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080
XRAY_BIN=/usr/local/bin/xray
XRAY_TRAFFIC_DB=/opt/xray-traffic/data/traffic.db
XRAY_TRAFFIC_RETENTION_DAYS=180
XRAY_TRAFFIC_TIMEZONE=Asia/Shanghai
XRAY_TRAFFIC_TIMEOUT_SECONDS=30
```

多实例配置示例：

```bash
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080,edge=127.0.0.1:18081
```

实例名只能使用字母、数字、下划线、点和横线。`ALL` 是保留值，表示所有配置实例，不能作为实例名。

配置优先级：

```text
命令行参数 > 环境变量 > 配置文件 > 默认值
```

安装后可以通过软链接执行：

```bash
xray-traffic check config
```

直接编辑配置文件：

```bash
xray-traffic edit config
```

`edit config` 会按 `$EDITOR -> vim -> vi -> nano` 选择编辑器。打开前会创建备份文件，例如：

```text
/opt/xray-traffic/config/xray-traffic.env.bak.20260604-153000
```

编辑结束后会自动执行配置校验。校验失败时会保留备份路径，方便手工恢复。

## 命令结构

所有子命令统一为：

```text
xray-traffic <action> <noun> [options]
```

核心命令：

```bash
xray-traffic collect hourly --instance ALL
xray-traffic collect daily --instance ALL
xray-traffic collect monthly --instance ALL
xray-traffic show hourly --instance default
xray-traffic show daily --instance default
xray-traffic show monthly --instance default
xray-traffic show yearly --instance default
xray-traffic summarize hourly --instance default
xray-traffic summarize daily --instance default
xray-traffic show current --instance default
xray-traffic watch current --instance default
xray-traffic list instances
xray-traffic export daily --instance default --output daily.csv
xray-traffic cleanup records
xray-traffic check health
xray-traffic check config
xray-traffic edit config
```

所有涉及 Xray 实例的命令都必须传 `--instance`。可传具体实例名，也可传 `ALL`：

```bash
xray-traffic show hourly --instance default
xray-traffic show hourly --instance ALL
```

未传 `--instance` 或传入未知实例时，工具会提示可用实例列表。

## 定时任务

小时任务：

```text
每小时 00 分执行 xray-traffic collect hourly --instance ALL
```

每日任务：

```text
每天 00:10 执行 xray-traffic collect daily --instance ALL
```

每月任务：

```text
每月 1 日 00:30 执行 xray-traffic collect monthly --instance ALL
```

`collect hourly` 会立即调用每个目标实例：

```bash
xray api statsquery --server=<instance-server> -reset=true
```

因此小时记录保存的是两次采集之间的增量。`collect daily` 不调用 Xray，只从 SQLite 中的 `hourly` 记录聚合。`collect monthly` 不调用 Xray，只从 SQLite 中的 `daily` 记录聚合。

## 查看示例

列出实例：

```bash
xray-traffic list instances
```

查看上次 reset 后的当前累计流量，不入库、不 reset：

```bash
xray-traffic show current --instance default
```

查看某个用户的当前累计流量：

```bash
xray-traffic show current --instance default --scope user --name alice
```

持续查看当前累计流量，不入库、不 reset：

```bash
xray-traffic watch current --instance default --interval 1
xray-traffic watch current --instance default --scope user --name alice --no-clear
```

按小时查看已存储流量：

```bash
xray-traffic show hourly --instance default
```

当 `show hourly`、`show daily`、`show monthly` 或 `show yearly` 使用 `--instance ALL` 命中多个实例时，每个周期的实例明细后会追加一行 `Instance` 为 `ALL` 的跨实例小计。

按天查看已存储流量：

```bash
xray-traffic show daily --instance default --days 7
```

按月查看已持久化的 monthly 快照：

```bash
xray-traffic show monthly --instance default --month 2026-05
xray-traffic show monthly --instance ALL --months 12
```

按年从 monthly 快照聚合查看，不额外落库：

```bash
xray-traffic show yearly --instance default --year 2026
xray-traffic show yearly --instance ALL --years 3
```

汇总最近 7 天每日用户流量：

```bash
xray-traffic summarize daily --instance default --scope user --days 7
```

`summarize` 会在汇总表格前显示 `Period`、`Range`、`Instance`、`Scope` 和 `Name`，便于确认统计范围。

导出 CSV：

```bash
xray-traffic export daily --instance default --scope user --from 2026-05-01 --to 2026-06-01 --output users.csv
```

手工清理超过保留期的数据：

```bash
xray-traffic cleanup records
```

清理策略按 `period` 分开执行：`hourly` 使用 `XRAY_TRAFFIC_RETENTION_DAYS`，`daily` 至少保留 `max(retention_days, 62)` 天，`monthly` 保留 36 个月。

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
instance    实例名
server      记录写入时的 Xray API 地址
period      hourly / daily / monthly
start_ts    统计开始 Unix 时间戳
end_ts      统计结束 Unix 时间戳
scope       user / inbound / outbound
name        用户名、inbound tag 或 outbound tag
direction   up / down
bytes       字节数
```

主键：

```text
instance, period, start_ts, scope, name, direction
```

这个版本不兼容旧数据库 schema。如果旧库没有 `instance` 和 `server` 字段，工具会报错提示先备份并删除旧的 `traffic.db`。

如果配置文件已经存在但缺少 `XRAY_TRAFFIC_INSTANCES`，工具会直接报错，不会回退到默认实例，避免旧配置被静默忽略后监控错端口。
