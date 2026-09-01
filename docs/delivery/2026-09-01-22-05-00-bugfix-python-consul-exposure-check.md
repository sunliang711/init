# consul doctor 的暴露检查看错了地址字段

## 问题

`doctor_base_configuration()` 里判断「无认证暴露」用的是 `bind_addr`：

```python
if values["bind_addr"] not in {"127.0.0.1", "", "localhost"} and values["acl_enabled"] != "true":
    doctor_check("FAIL", f"Consul binds {values['bind_addr']} with ACL disabled; the API is open to that network")
```

但两个字段管的是不同的东西：

| 字段 | 管什么 |
| --- | --- |
| `bind_addr` | 集群内部通信：Serf LAN/WAN、Server RPC |
| `client_addr` | 客户端接口：HTTP API（**Web UI 由它提供**）、HTTPS、gRPC、DNS |

消息里说的「API 暴露」发生在 `client_addr` 上，检查却盯着 `bind_addr`。后果是两头都错：

- **漏报**：`--client 0.0.0.0 --no-acl` —— 真正把无认证 API 暴露到网络上的组合，不告警
- **误报**：`--bind 10.0.0.5` 配 ACL 关闭 —— 多节点集群里的正常配置，被判 FAIL

## 改动

- 暴露判定改用 `client_addr`，命中时 FAIL，并补一行说明后果
- `bind_addr` 非本地且 ACL 关闭降级为 WARN：集群通信在无认证下跨网也值得提，但严重程度不同
- 本地地址集合提取为 `LOCAL_ADDRESSES` 常量，补上 `::1` 与 `[::1]`

## 验证结果

`tests/test_consul_manager_doctor.py` 相关用例重写，共 13 条通过：

- `--client 0.0.0.0` + ACL 关 -> FAIL，消息指明 HTTP API 和 UI
- `--client 0.0.0.0` + ACL 开 -> 0 failure（开放 UI 的正确做法）
- `--bind 10.0.0.5` + ACL 关 -> 0 failure，只 WARN
- 本地地址 + ACL 关 -> 0 failure

其余：8 份 Python 测试在 `-W error::ResourceWarning` 下通过；三套工具全量 `py_compile`；
5 个 consul tutor topic 渲染；`bash bootstrap/verify.sh`、`git diff --check` 通过。

## 未覆盖风险

- 未在目标机器上验证。
- 判定只识别字面量本地地址；绑定到某个仅内网可达的具体 IP 仍会被判为暴露，属偏保守方向。
