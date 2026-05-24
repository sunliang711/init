# acme-manager 证书任务管理改造交付说明

## 变更摘要

- 将 `acme_batch_issue.sh` 重命名为 `acme-manager`，不保留旧脚本兼容入口。
- 将原来的批量签发参数模式改为 ID-first 子命令模式。
- 新增任务 registry：`${ACME_HOME}/acme-manager/tasks/<id>.task`。
- 新增任务运行目录：`${ACME_HOME}/acme-manager/runtime/<id>`，用于隔离同主域名、多任务证书。

## 新增命令

- `install`：安装 acme.sh、依赖命令和默认 reload hook。
- `issue --id <id>`：创建任务、签发证书并部署到证书目录。
- `list`：列出全部任务，支持按域名和状态过滤。
- `show <id>`：查看任务详情。
- `renew <id|--all>`：手动续期任务，支持 `--force`。
- `deploy <id>`：仅重新安装已有证书。
- `disable <id>` / `enable <id>`：控制任务是否参与 `renew --all`。
- `remove <id>`：删除任务记录和内部运行目录，默认保留已安装证书文件。
- `revoke <id>`：吊销证书，必须显式传入 `--yes-i-understand-revoke`。
- `import --id <id>`：导入已有 acme.sh 证书。
- `rename <old-id> <new-id>`：重命名任务 ID。
- `doctor`：检查基础环境和任务证书状态。

## 保护措施

- 所有任务管理命令都以 ID 为唯一主键，域名只作为任务属性和列表过滤条件。
- 任务 ID 和安装文件名前缀限制为安全字符，避免路径穿越。
- registry 使用制表符分隔的只读解析方式，不通过 `source` 执行任务文件内容。
- `remove` 默认不删除 `/etc/certs` 下已安装证书，只有显式 `--purge-installed-files` 才会删除。
- `revoke` 必须显式确认参数，避免误吊销证书。
- 删除路径经过空路径、根目录和关键系统目录保护。

## 验证情况

- 已执行 `bash -n acme-manager`，语法检查通过。
- 已执行 `shellcheck acme-manager`，静态检查通过。
- 已使用临时 `--acme-home` 验证 `--help`、`list`、`doctor`、`import`、`show`、`disable`、`enable`、`rename` 的基础分支。
- 由于当前工作机不是目标 Linux/root 运行环境，真实签发、续期、部署和删除流程未执行。
