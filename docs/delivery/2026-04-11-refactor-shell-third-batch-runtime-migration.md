## 重构摘要
- 目标：完成第三批复制脚本头脚本的迁移样板，改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`tools/installLunarvim.sh`、`tools/installPortainer.sh`、`tools/clearSystemdLogCron.sh`
- 保持不变的行为：三份业务脚本的命令入口和业务逻辑不变；`tools/installLunarvim.sh` 与 `tools/installPortainer.sh` 的进度条及相关辅助函数原样保留；`tools/clearSystemdLogCron.sh` 仅删除重复公共头并改为运行时复用
- 验证结果：已执行 `bash -n tools/installLunarvim.sh tools/installPortainer.sh tools/clearSystemdLogCron.sh`，通过；已执行 `shellcheck tools/installLunarvim.sh tools/installPortainer.sh tools/clearSystemdLogCron.sh`，迁移新增告警未发现，剩余为迁移前已存在的历史告警；其中 `tools/installLunarvim.sh` 与 `tools/installPortainer.sh` 的进度条相关解析错误已分别通过 `git show HEAD:tools/installLunarvim.sh | shellcheck -s bash -`、`git show HEAD:tools/installPortainer.sh | shellcheck -s bash -` 确认为历史问题；`tools/clearSystemdLogCron.sh` 当前剩余 `shellcheck` 告警也已通过 `git show HEAD:tools/clearSystemdLogCron.sh | shellcheck -s bash -` 确认为历史问题
- 残余风险：其它复制头脚本尚未迁移；历史 `shellcheck` 告警仍存在，后续宜单独分批清理
