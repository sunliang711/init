# Nomad Python 工具远端集成测试记录

## 测试目标

- 在 `10.2.138.99` 上验证 Python 化后的 `nomad-manager` 和 `nomad-job`。
- 覆盖 Nomad 安装、普通 Docker Job、Vault 安装、Vault secret 写入、Nomad Job 读取 Vault secret。

## 测试环境

- 远端系统：Debian 13，`x86_64`
- 远端用户：`root`
- 工具上传目录：`/tmp/init-tools-test`
- Nomad 安装版本：`2.0.0`
- Vault 安装版本：`2.0.0`
- 代理：`http://10.2.1.107:7390`

## 执行结果

- `nomad-manager install` 成功。
- `nomad.service` 状态为 `active`。
- `nomad server members` 显示 `debian13.global` 为 leader。
- `nomad node status` 显示节点 `debian13` 为 `ready`。
- `nomad-manager docker doctor` 全部通过。
- 普通 Job `web-py` 部署成功，状态为 `running`，deployment 为 `successful`。
- `curl http://10.2.138.99:18080/` 返回 `200`。
- `vault-manager install` 成功。
- `vault-manager init`、`vault-manager unseal` 成功。
- `vault-manager doctor` 通过。
- Vault KV v2 已启用在 `kv/`。
- 已写入测试 secret：`kv/app`。
- `nomad-manager vault-jwt apply --profile default ...` 成功。
- `nomad-manager vault-jwt doctor --profile default` 全部通过。
- Vault secret Job `vault-secret-py` 部署成功，状态为 `running`，deployment 为 `successful`。
- `nomad alloc logs` 中确认 Job 环境变量已读取到 Vault secret：
  - `SECRET_VALUE=nomad-secret-value`
  - `APP_USERNAME=nomad-user`
  - `APP_API_KEY=nomad-api-key`

## 修复记录

- 测试中发现 `vault-jwt doctor` 会输出 Vault policy/role 原始内容。
- 已修改 `tools/nomad/nomad_tools/manager.py`，对 doctor 内部的 `vault policy read` 和 `vault read role` 使用 stdout 捕获。
- 已同步修复到远端 `/opt/nomad/lib/nomad-init-tools/nomad_tools/manager.py` 并复测通过。

## 当前远端状态

- `nomad.service`：active
- `vault.service`：active
- `docker.service`：active
- Nomad jobs：
  - `web-py`：running
  - `vault-secret-py`：running

## 残余风险

- 测试机上两个测试 Job 当前保留运行，便于后续检查。
- 未执行卸载流程；如需清理，应显式执行 `nomad job stop`、`nomad-manager uninstall` 和 `vault-manager uninstall`。
