# Xray traffic watch current 交付说明

## 实现内容

- 新增 `xray-traffic watch current` 子命令，用于持续查看指定实例上次 reset 后的当前累计流量。
- 支持 `--instance`、`--scope`、`--name`、`--interval`、`--count` 和 `--no-clear`。
- 默认每秒刷新并清屏；`--no-clear` 时追加输出；`--count 0` 表示一直运行。
- 该命令只调用 Xray `statsquery` 的非 reset 路径，不写 SQLite，不重置 Xray 计数。
- 单轮查询失败会在视图中显示错误并继续；有限 `--count` 结束后如出现过查询错误则返回 1。
- `Ctrl+C` 会干净退出并返回 0。
- 无参数执行 `xray-traffic` 时输出完整帮助，和 `xray-traffic -h` 保持一致。
- 交互式终端中帮助内容超过屏幕高度时，会使用 `less` 分页；非交互输出、重定向、管道或无 `less` 时保持普通输出。

## Review 结果

- 实现代理完成初版后，独立 review 代理发现 `watch current` 有查询失败后返回 0 的问题。
- 已修复该问题，并补充 `watch current --help` 的命令说明。
- 第二轮 review 未发现明确问题，建议合并。

## 验证

```bash
python3 -m py_compile tools/xray/traffic/xray-traffic
python3 tools/xray/traffic/xray-traffic --help
python3 tools/xray/traffic/xray-traffic watch --help
python3 tools/xray/traffic/xray-traffic watch current --help
python3 tools/xray/traffic/xray-traffic
python3 tools/xray/traffic/xray-traffic -h
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --xray-bin /bin/echo --db "${tmp_dir}/traffic.db" watch current --instance default --count 1 --no-clear
XRAY_TRAFFIC_INSTANCES=default=127.0.0.1:18080 python3 tools/xray/traffic/xray-traffic --xray-bin "${tmp_dir}/missing-xray" --db "${tmp_dir}/traffic.db" watch current --instance default --count 1 --no-clear
git diff --check
```

已通过函数级模拟验证：TTY 且帮助内容超屏时会触发分页路径；管道输出时不会触发分页。

以上验证均符合预期。
