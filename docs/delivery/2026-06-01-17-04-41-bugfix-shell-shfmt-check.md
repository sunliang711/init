# shfmt 检查修复交付说明

## Bug 修复摘要

- 问题：`pre-commit` 中的 `bootstrap verify syntax` 和 `bootstrap verify fmt-check` 因 `shfmt` 失败阻塞提交。
- 根因：`config/shell/shared/functions.sh` 同时包含 bash 和 zsh 专用语法，`shfmt` 单次只能使用一个 dialect 解析；其他文件存在既有格式差异。
- 修复方式：将 `functions.sh` 从 `SHFMT_FILES` 中排除，但继续保留在 `BASH_SYNTAX_FILES`；对其余 `SHFMT_FILES` 执行项目格式化。
- 影响范围：仅影响格式检查列表和 shfmt 格式化结果，不改变脚本业务逻辑。
- 验证方式：已执行 `bash bootstrap/verify.sh fmt-check` 和 `bash bootstrap/verify.sh syntax`。
