# nomad-manager vault-jwt tls-auto health

## 问题背景

`vault-manager install --tls-auto` 安装 Vault 后，执行：

```bash
nomad-manager vault-jwt plan --profile default --vault-addr https://127.0.0.1:8200 --nomad-addr http://127.0.0.1:4646 --secret-path 'kv/data/app/*'
```

预检中 Vault CLI 相关检查可以通过，但健康检查失败：

```text
FAIL  Vault health endpoint not reachable: https://127.0.0.1:8200/v1/sys/health (0)
```

## 根因分析

`vault-jwt plan` 使用 Python `urllib` 直接访问 Vault health endpoint。`--tls-auto` 生成的是自签 CA，Vault CLI 可以通过 `VAULT_CACERT` 完成校验，但 `urllib` 健康检查没有使用该 CA，因此 HTTPS 握手失败并返回状态码 `0`。

## 修复方案

- `nomad/nomad_tools/common.py`：为 `http_status` 增加可选 `cafile` 参数，通过 `ssl.create_default_context(cafile=...)` 保持证书校验。
- `nomad/nomad_tools/manager.py`：Vault 检查优先读取环境变量 `VAULT_CACERT`，未设置时在 `VAULT_ADDR` 匹配本次 Vault 地址的情况下读取 `vault-manager` 生成的 `/opt/vault/etc/vault.d/client.env`。
- `vault-jwt plan` 和 `vault doctor` 的 Vault health endpoint 检查复用同一 CA 文件。
- Vault CLI 调用在当前环境未设置 `VAULT_CACERT` 时，也会复用 `client.env` 中的 CA 配置。

## 验证结果

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B -c 'from nomad_tools.common import http_status; print(http_status("https://127.0.0.1:1", cafile="/no/such/file"))'`
- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B nomad/nomad-manager vault-jwt plan --help`

## 风险与后续建议

修复未关闭 TLS 校验，只补齐自签 CA 信任链。若仍返回 `0`，优先检查 `VAULT_CACERT` 或 `/opt/vault/etc/vault.d/client.env` 是否指向可读的 CA 文件。
