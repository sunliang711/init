# fail2ban-manager Shell 代码评审

## 文件说明

- 审查脚本：`tools/fail2ban-manager.sh`
- 用途：fail2ban service、jail、filter、封禁和备份恢复管理。
- 配置说明：脚本通过 `F2B_CONFIG_DIR`、`F2B_JAIL_DIR`、`F2B_FILTER_DIR`、`F2B_BACKUP_DIR` 等变量控制目标目录，写操作前会执行路径安全检查。

## 示例

```bash
tools/fail2ban-manager.sh --dry-run ban add sshd 1.2.3.4
tools/fail2ban-manager.sh --dry-run backup restore 20260621-141913 --yes
```

## 审查过程

- 第一轮独立 review 发现路径保护、备份恢复、备份可信度、备份 ID、filter 引用扫描等问题。
- 第二轮独立 review 继续发现路径严格子目录、祖先 symlink、并发备份 ID、manifest 校验等问题。
- 第三轮独立 review 发现 `backup_id` 仍可使用 `.` / `..` 的阻断问题。
- 已逐项修复上述阻断问题。

## 当前结论

- `bash -n` 通过。
- `shellcheck` 通过。
- 日志输出为英文。
- 新建 jail、filter、backup manifest 模板包含注释、示例和配置说明。

## 残余风险

- 未在真实 Linux fail2ban 环境执行 reload 集成测试。
- filter 正则匹配质量仍需结合实际服务日志通过 `filter test` 验证。
