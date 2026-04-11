## 重构摘要
- 目标：完成第二批复制脚本头脚本的迁移样板，改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`tools/backupDockerVolume.sh`、`tools/wireguard/wgclient.sh`、`tools/dns/install.sh`
- 保持不变的行为：三份业务脚本的命令入口和业务逻辑不变；`tools/dns/install.sh` 的进度条与自定义辅助函数原样保留，仅删除重复公共头并改为运行时复用
- 验证结果：已执行 `bash -n tools/backupDockerVolume.sh tools/wireguard/wgclient.sh tools/dns/install.sh`，通过；已执行 `shellcheck tools/backupDockerVolume.sh tools/wireguard/wgclient.sh tools/dns/install.sh`，迁移新增告警已消除，剩余为迁移前已存在的历史告警；其中 `tools/dns/install.sh` 的进度条相关解析错误已通过 `git show HEAD:tools/dns/install.sh | shellcheck -s bash -` 确认属于历史问题
- 残余风险：其它复制头脚本尚未迁移；历史 shellcheck 告警仍存在，后续宜单独做一次清理
