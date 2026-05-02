# Vault Unseal Keys 权限错误提示修复

## 问题

普通用户执行以下命令时，如果没有权限访问 key 文件或其父目录：

```bash
vault-manager unseal --keys-file /opt/vault/init/vault-init.json
```

脚本会把权限问题提示为：

```text
[ERROR] Keys file not found: /opt/vault/init/vault-init.json
[ERROR] Vault is still sealed after applying keys
```

这会误导排查方向。

## 根因

- `test -f "$path"` 在父目录不可进入或文件不可读场景下可能返回 false，原逻辑直接当作文件不存在处理。
- `unseal_keys_from_file "$keys_file"` 位于 process substitution 中执行，读取失败不会阻止父流程继续进入 unseal 循环，最后又报出 sealed 状态错误。

## 修复方式

- 新增 `validate_unseal_keys_file`，区分父目录不可访问、文件不存在、非普通文件、文件不可读。
- `unseal_vault` 在执行 unseal 前先完成 key 文件访问校验。
- 改为先读取 key 输出并检查读取结果，读取 JSON 失败时立即报错，不再继续执行 unseal 循环。
- 当 key 文件可读但不包含 unseal key 时，明确提示文件内容缺少 unseal keys。

## 验证

- `bash -n vault/vault-manager`
- `shellcheck vault/vault-manager`
- 临时目录无执行权限场景：提示 `Keys file directory is not accessible`
- 临时文件无读权限场景：提示 `Keys file is not readable`
- 文件不存在场景：提示 `Keys file not found`
- JSON 解析失败场景：提示 `Failed to read keys file`，不再输出 `Vault is still sealed after applying keys`

## 影响范围

仅影响 `vault-manager unseal --keys-file` 的 key 文件读取和错误提示逻辑，不改变 Vault init、auth、policy 等其他命令行为。
