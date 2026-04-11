## 重构摘要
- 目标：完成第一批复制脚本头脚本的迁移样板，改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`bootstrap/lib/runtime.sh`、`tools/logrotate.sh`、`tools/stunnel.sh`、`tools/installTraffic.sh`
- 保持不变的行为：三份业务脚本的命令入口和业务逻辑不变，仅删除重复公共头并改为运行时复用；`runtime.sh` 新增兼容别名与兼容函数以承接旧头能力
- 验证结果：已执行 `bash -n bootstrap/lib/runtime.sh tools/logrotate.sh tools/stunnel.sh tools/installTraffic.sh`，通过；已执行 `shellcheck bootstrap/lib/runtime.sh tools/logrotate.sh tools/stunnel.sh tools/installTraffic.sh`，迁移新增告警已消除，剩余为迁移前已存在的历史告警；并已复查迁移脚本仍通过 `runtime.sh` 解析 `this`、`user`、`home` 与帮助入口
- 残余风险：其它复制头脚本尚未迁移；部分旧脚本如果依赖 `_run/_runAsRoot` 的高级选项，仍需单独评估后再迁移
