# Vault 管理脚本交付说明

## 变更范围

- 新增 `tools/vault/manager.sh`。
- 支持 Vault 安装、卸载、状态检查、doctor、初始化、unseal、auth 管理和 policy 管理。
- 借鉴 `tools/installVault.sh` 的安装、systemd、初始化、unseal、KV/auth 启用思路，重新实现为严格模式和子命令结构。

## 主要命令

```bash
./tools/vault/manager.sh install
./tools/vault/manager.sh install --version 2.0.0
./tools/vault/manager.sh status
./tools/vault/manager.sh doctor
./tools/vault/manager.sh init --key-shares 1 --key-threshold 1 --out /opt/vault/init/vault-init.json
./tools/vault/manager.sh unseal --keys-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh auth list --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh auth enable userpass --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh auth disable userpass --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh policy list --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh policy write app-read policy.hcl --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh policy read app-read --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh policy delete app-read --token-file /opt/vault/init/vault-init.json
./tools/vault/manager.sh uninstall --purge-data
```

## 安装行为

- 默认版本为 `2.0.0`；未指定版本时先从 HashiCorp releases 页面解析最新版本，解析失败时回退到默认版本。
- 下载 `vault_${version}_linux_${arch}.zip` 和 `vault_${version}_SHA256SUMS`。
- 校验 SHA256 后安装二进制到 `/usr/local/bin/vault`。
- 创建 `vault` 系统用户和系统组。
- 写入 `/etc/vault.d/config.hcl`，使用单节点 raft storage，数据目录为 `/opt/vault/data`。
- 写入 `/etc/systemd/system/vault.service` 并启动服务。
- 默认 `tls_disable = true`，可通过 `--tls-disable false --tls-cert-file FILE --tls-key-file FILE` 使用已有证书。

## 安全策略

- 安装只管理首行为 `# Managed by tools/vault/manager.sh` 的配置文件。
- `init` 输出包含 unseal keys 和 root token，默认保存为 0600。
- 管理命令不会打印 token；需要 token 时使用 `VAULT_TOKEN` 或 `--token-file`。
- `uninstall` 默认保留 `/opt/vault`；只有显式传 `--purge-data` 才删除 Vault 数据和 init 文件。

## 官方文档核对

- Vault 下载源：`https://releases.hashicorp.com/vault/`
- Vault 配置：`https://developer.hashicorp.com/vault/docs/configuration`
- Vault operator init/unseal：`https://developer.hashicorp.com/vault/docs/commands/operator/init`
- Vault auth enable：`https://developer.hashicorp.com/vault/docs/commands/auth/enable`
- Vault policy write：`https://developer.hashicorp.com/vault/docs/commands/policy/write`

## 验证情况

- `bash -n tools/vault/manager.sh`
- `shellcheck tools/vault/manager.sh`
- `./tools/vault/manager.sh --help`
- `./tools/vault/manager.sh doctor`
- 已在 `10.2.37.64` 使用 `root/Chief1234` 实机验证，下载代理为 `http://10.2.1.107:7190`。
- 远端安装命令：`TMPDIR=/root http_proxy=http://10.2.1.107:7190 https_proxy=http://10.2.1.107:7190 /tmp/vault-manager.sh install --version 2.0.0`。
- 远端安装结果：`Vault v2.0.0` 安装成功，`vault.service` 启动成功，初始化前 health endpoint 返回 `501`。
- 远端初始化与 unseal：`init --key-shares 1 --key-threshold 1 --out /opt/vault/init/vault-init.json --force` 和 `unseal --keys-file /opt/vault/init/vault-init.json` 均通过，unseal 后 health endpoint 返回 `200`。
- 远端状态验证：Vault 已初始化、已 unseal，storage type 为 `raft`，HA mode 为 `active`。
- 远端管理验证：`policy write/read/list/delete app-read` 通过；`auth enable userpass` 重复执行具备幂等行为；`auth write userpass/users/test ...` 通过；`auth disable userpass` 重复执行具备幂等行为。
- 远端安全验证：`/opt/vault/init/vault-init.json` 权限为 `600`。
- 远端清理验证：`uninstall --purge-data` 后 `/usr/local/bin/vault`、`/etc/vault.d`、`/opt/vault` 已删除，`vault.service` 为 `inactive`，`vault` 用户已删除。
