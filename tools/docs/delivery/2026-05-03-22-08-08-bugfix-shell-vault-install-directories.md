# Vault install directory failure diagnostics

## 问题

`vault-manager install --tls-auto` 在日志 `Creating Vault directories` 之后失败，但最终只输出通用错误：

```text
[ERROR] Failed vault-manager command (1): install --tls-auto
```

该输出无法定位具体失败目录或路径冲突。

## 根因

`install_directories` 直接连续调用 `run_root install -d ...`。任意一步失败时，`set -e` 和全局 `ERR` trap 只报告顶层命令，缺少目录级上下文。

常见触发条件包括：

- 目标路径已存在但不是目录
- 目标路径权限异常
- `vault` 用户或组在系统命令层不可用
- `/opt/vault` 下存在历史残留文件冲突

## 修复方式

- 新增 `install_vault_dir` 包装函数
- 创建目录前检查目标路径是否为非目录文件
- `install -d` 失败时输出具体目录路径
- 保持原有目录权限、属主、属组不变

## 验证方式

- 已执行：`bash -n vault/vault-manager`
- 已执行：`shellcheck vault/vault-manager`

## 回归风险

低。修改仅影响 Vault 安装阶段的目录创建诊断和路径冲突保护，不改变安装目录、权限、服务配置或 Vault 参数。
