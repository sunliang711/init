## 重构摘要
- 目标：完成第五批复制脚本头脚本的迁移样板，改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`tools/extendLvm.sh`
- 保持不变的行为：脚本命令入口和业务逻辑不变；进度条与相关辅助函数原样保留；仅删除重复公共头并改为运行时复用，同时清理迁移后会残留的重复“available functions”注释块
- 验证结果：已执行 `bash -n tools/extendLvm.sh`，通过；已执行 `shellcheck tools/extendLvm.sh`，迁移新增告警未发现，剩余为迁移前已存在的历史告警；其中进度条相关解析错误已通过 `git show HEAD:tools/extendLvm.sh | shellcheck -s bash -` 确认为历史问题
- 残余风险：剩余未迁移脚本里，较多文件属于 `shelllib.sh` 兼容层，或依赖旧 `_root` / `_run` / `_runAsRoot` 的特定语义；后续宜按语义家族分组，而不是继续按文件名顺序推进
