# fail2ban-manager 交付说明

## 文件说明

- 新增脚本：`tools/fail2ban-manager.sh`
- 用途：管理 fail2ban 的 service、jail、filter、ban/unban 和配置备份恢复。
- 配置说明：脚本支持通过 `F2B_CONFIG_DIR`、`F2B_JAIL_DIR`、`F2B_FILTER_DIR`、`F2B_BACKUP_DIR`、`F2B_CLIENT`、`F2B_REGEX` 覆盖默认路径和命令。

## 示例

```bash
tools/fail2ban-manager.sh filter add custom-nginx-404 \
  --failregex '^<HOST> - .* "(GET|POST) .*" 404 .*$'

tools/fail2ban-manager.sh jail add nginx-404 \
  --filter custom-nginx-404 \
  --logpath /var/log/nginx/access.log \
  --port http,https \
  --maxretry 20 \
  --findtime 10m \
  --bantime 1h

tools/fail2ban-manager.sh service reload
```

## 变更摘要

- 支持 `service status/reload`。
- 支持 `jail list/show/add/set/enable/disable/remove`。
- 支持 `filter list/show/add/import/test/remove`，内置 filter 只查看和引用，自定义 filter 使用 `custom-` 前缀。
- 支持 `ban list/add/remove`。
- 支持 `backup create/list/restore`，恢复前会再次备份当前状态。
- 支持 `doctor` 环境诊断。
- 所有脚本新建的 jail、filter、backup manifest 都包含管理标记、配置说明、示例和验证命令。

## 保护措施

- 写操作、reload、ban/unban 需要 root；`--dry-run` 不执行真实副作用。
- 写操作前自动备份，配置变更后执行 `fail2ban-client -t`。
- 不修改 `/etc/fail2ban/jail.conf`，不覆盖内置 filter。
- 只修改带 `Managed by fail2ban-manager.sh` 标记的脚本管理文件。
- 路径要求 jail/filter/backup 都位于 fail2ban 配置根目录的严格子目录内，且三者互不嵌套。
- 拒绝路径穿越、危险目录、已存在路径组件中的符号链接。
- 备份恢复使用严格快照恢复，恢复失败会回滚到恢复前快照。
- `backup_id` 限制为脚本生成格式：`YYYYMMDD-HHMMSS` 或 `YYYYMMDD-HHMMSS-N`。

## 验证方式

- `bash -n tools/fail2ban-manager.sh`
- `shellcheck tools/fail2ban-manager.sh`
- `tools/fail2ban-manager.sh doctor`
- 隔离临时目录下执行 `jail add --dry-run`
- 验证 `backup restore .. --yes --dry-run` 会被拒绝

## 已知限制

- 本地开发机没有 fail2ban，未做真实 `fail2ban-client reload` 集成验证。
- `fail2ban-client -t` 只能验证语法和加载能力，不能证明 failregex 策略一定符合业务预期。
