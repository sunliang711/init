# Vault download progress

## 变更摘要

- 修改脚本：`vault/vault-manager`
- 修改函数：`curl_download`
- 目标：交互式安装时显示下载进度，非交互环境保持安静日志

## 实现方式

- 文件下载使用 curl 参数数组，避免命令字符串拼接
- 检测 stderr 是否为 TTY：
  - TTY 环境使用 `--progress-bar`
  - 非 TTY 环境继续使用 `--silent`
- `curl_stdout` 保持不变，避免污染版本解析输出

## 影响范围

- 影响 Vault zip 包和 SHA256SUMS 文件下载
- 不改变版本解析、checksum 校验、解压、安装和 systemd 流程

## 验证情况

- 已执行：`bash -n vault/vault-manager`
- 已执行：`shellcheck vault/vault-manager`
