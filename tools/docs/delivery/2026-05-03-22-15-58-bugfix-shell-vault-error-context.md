# Vault error context

## 问题

`vault-manager install --tls-auto` 在目录创建阶段失败时仍只输出顶层命令：

```text
[ERROR] Failed vault-manager command (1): install --tls-auto
```

这会隐藏底层失败命令和失败行号。

## 修复方式

- 新增 `handle_unexpected_error` 统一处理全局 `ERR` trap
- 失败时输出：
  - 退出码
  - 失败行号
  - 失败的底层命令
  - 顶层 vault-manager 命令
- 目录创建失败改为 `fatal "Failed to create directory: ..."`，确保路径进入错误和审计记录

## 验证情况

- 已执行：`bash -n vault/vault-manager`
- 已执行：`shellcheck vault/vault-manager`
- 已执行：`vault/vault-manager --help`

## 使用提示

如果当前运行的是已安装快照 `/usr/local/bin/vault-manager`，需要先用源码脚本同步工具快照：

```bash
vault/vault-manager tools update
```

也可以直接运行源码脚本验证：

```bash
vault/vault-manager install --tls-auto
```
