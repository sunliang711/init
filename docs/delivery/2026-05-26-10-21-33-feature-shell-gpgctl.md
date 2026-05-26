# GPG 管理脚本交付说明

## 变更摘要

- 新增脚本：`bin/gpgctl`
- 脚本类型：Bash 本地管理脚本，兼容 macOS / Linux 常见 GnuPG 环境
- 主要用途：封装 GPG 密钥生成、导入导出、备份、加解密、签名验签、公钥服务器、ownertrust、YubiKey / smart card 入口等常用管理动作

## 入口参数

- 全局参数：
  - `--homedir <path>`：指定 GPG 工作目录
  - `--keyserver <url>`：指定 keyserver
  - `--local-user <uid>`：指定签名密钥
  - `--force`：允许覆盖输出文件
  - `--yes`：跳过脚本级危险操作确认
- 常用命令：
  - `gen`
  - `list-public`
  - `list-secret`
  - `export-public`
  - `export-secret`
  - `import`
  - `encrypt`
  - `decrypt`
  - `sign`
  - `verify`
  - `edit-key`
  - `card-status`
  - `card-edit`

## 依赖命令

- 必需：`gpg`
- 文件操作：`cp`、`mkdir`、`chmod`、`find`
- macOS 安装提示：`brew install gpg-suite`

## 保护措施

- 所有 GPG 操作执行前都会回显 `[GPG]` 底层命令。
- 输出文件默认不覆盖，必须显式传入 `--force`。
- 私钥、吊销证书等敏感输出使用 `umask 077`。
- 删除公钥、删除私钥、签名公钥等高风险操作需要交互确认，或显式传入 `--yes`。
- `backup-home` 不删除原目录，目标目录非空时默认拒绝继续。
- YubiKey 相关操作只提供 `card-status`、`card-edit`、`edit-key` 入口，不自动执行 `keytocard` 或 `delkey`。

## 验证情况

- 已通过：`bash -n bin/gpgctl`
- 已通过：`shellcheck bin/gpgctl`
- 已通过：`bin/gpgctl help`
- 已通过：`bin/gpgctl check`
- 已通过：`bin/gpgctl version`，确认会回显 `[GPG] gpg --version`
- 已验证错误路径：参数缺失、`--homedir` 指向不存在目录
