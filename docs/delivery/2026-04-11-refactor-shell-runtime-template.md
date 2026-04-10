## 重构摘要
- 目标：明确 `bootstrap/lib/runtime.sh` 与 `templates/scripts/shell-script.sh` 的职责边界，并把可复用的公共能力下沉到 `runtime.sh`
- 改动脚本：`bootstrap/lib/runtime.sh`、`templates/scripts/shell-script.sh`
- 保持不变的行为：`shell-script.sh` 继续作为 `newsh` 的单文件模板；`runtime.sh` 继续作为仓库内脚本的 source 型公共运行时；本次未迁移任何业务脚本
- 验证结果：已执行 `bash -n bootstrap/lib/runtime.sh`、`bash -n templates/scripts/shell-script.sh`、`shellcheck bootstrap/lib/runtime.sh`、`shellcheck templates/scripts/shell-script.sh`，均通过；并已复查差异确认只涉及公共能力收敛与角色说明
- 残余风险：仓库内仍存在大量旧脚本头副本；它们不会自动继承本次改动，后续仍需分批迁移到 `runtime.sh`
