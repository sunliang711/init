# consul-manager 自动配置 DNS token

## 背景

真实机器上的排查结果：服务已注册且健康，HTTP API 查得到，但

```
dig @127.0.0.1 -p 8600 postgres.service.consul   ->  NXDOMAIN
```

证据链：

```
带 token 查目录:   {"consul":[],"nomad":[...],"nomad-client":[...],"postgres":[]}
不带 token 查目录: {}
postgres passing 实例: 1 个 -> 10.2.176.127:5432
匿名 token 的 policy 列表: 空
配置里的 acl.tokens: 不存在
```

**DNS 协议没有携带 token 的地方。** Consul 处理 DNS 查询时用 `acl.tokens.dns`，
未配置时按匿名身份执行；在 `default_policy = deny` 且匿名 token 无任何 policy 的情况下，
每一次解析都看不到任何服务，于是 NXDOMAIN。

HTTP API 之所以正常，是因为请求里带了 `X-Consul-Token`。

这是典型的静默失败：`install` 开了 ACL、`nomad-jwt apply` 配好了工作负载身份，
服务注册一切正常，唯独 DNS 不通，而此前 `doctor` 一个字都不提。

## 改动

### install 自动创建

ACL bootstrap 成功后，用拿到的管理 token 创建：

- ACL policy `dns-read`：`node_prefix` / `service_prefix` / `query_prefix` 均为 read
- 一个绑定该 policy 的 token
- 托管片段 `60-dns-token.hcl`，内容为 `acl { tokens { dns = "..." } }`

bootstrap 被跳过或已 bootstrap 过（拿不到管理 token）时，告警并提示后续用
`consul-manager acl dns-token` 补。

### 新增 `acl dns-token`

给已经装好的节点补配，或 token 被吊销后重建。`--force` 强制重建。
ACL 关闭时是 no-op 并说明原因。

### doctor 新增检查

| 情况 | 结果 |
| --- | --- |
| ACL 关闭 | INFO，不需要 |
| ACL 状态未知（没装 Consul） | INFO 跳过 |
| ACL 开启但无 DNS token | **FAIL**，说明会 NXDOMAIN，给出修复命令 |
| 有 DNS token 但读不到目录 | **FAIL**，提示 `--force` 重建 |
| 有 DNS token 且能读目录 | OK |

第四条不是查文件存在，而是**拿这个 token 真去列一次服务目录** —— token 被吊销或
policy 被改窄时同样会 NXDOMAIN，只查文件存在是查不出来的。

`status` 增加一行 `dns token: configured / <absent>`，`tutor nomad` 与
`tutor troubleshoot` 补充说明。

## 验证结果

`tests/test_consul_manager_doctor.py` 新增 8 条（共 21 条）：

- ACL 开启无 token -> FAIL，输出含 NXDOMAIN 与修复命令
- token 存在但读不到目录 -> FAIL，提示 `--force`
- token 可用 -> 0 failure
- ACL 关闭 -> 0 failure，说明不需要
- ACL 状态未知 -> 0 failure，跳过（没装 Consul 的机器不该因此报错）
- token 能从托管片段读回
- **没有托管 marker 的片段不算数**，避免把手写配置当成自己写的
- **doctor 输出里不出现 token 值**

其余：8 份 Python 测试在 `-W error::ResourceWarning` 下通过；
`tests/cli-smoke.bats` 新增 1 条；29 个 subparser 全部 `format_help()` 通过；
5 个 consul tutor topic 渲染且行宽 <= 80；三套工具全量 `py_compile`；
`bash bootstrap/verify.sh`、`git diff --check` 通过。

## 未覆盖风险

- **未在目标机器上执行过。** `create_dns_token()` 会真的调用 `consul acl policy create`
  与 `consul acl token create`，并重启 consul.service，这条路径本机无法验证。
- `60-dns-token.hcl` 里存的是明文 token，权限随托管片段为 0640 consul:consul。
  这与 Consul 官方做法一致，但该文件确实是一个凭据文件。
