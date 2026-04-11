## 重构摘要
- 目标：完成第四批复制脚本头脚本的迁移样板，改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`tools/dns/bin/dnsProxy.sh`、`tools/docker/useful-docker-compose/dns/install.sh`、`tools/docker/useful-docker-compose/qbittorrent/start.sh`
- 保持不变的行为：三份业务脚本的命令入口和业务逻辑不变；进度条与相关辅助函数原样保留；仅删除重复公共头并改为运行时复用，同时清理迁移后会残留的重复“available functions”注释块
- 验证结果：已执行 `bash -n tools/dns/bin/dnsProxy.sh tools/docker/useful-docker-compose/dns/install.sh tools/docker/useful-docker-compose/qbittorrent/start.sh`，通过；已执行 `shellcheck tools/dns/bin/dnsProxy.sh tools/docker/useful-docker-compose/dns/install.sh tools/docker/useful-docker-compose/qbittorrent/start.sh`，迁移新增告警未发现，剩余为迁移前已存在的历史告警；其中三份脚本的进度条相关解析错误已分别通过 `git show HEAD:tools/dns/bin/dnsProxy.sh | shellcheck -s bash -`、`git show HEAD:tools/docker/useful-docker-compose/dns/install.sh | shellcheck -s bash -`、`git show HEAD:tools/docker/useful-docker-compose/qbittorrent/start.sh | shellcheck -s bash -` 确认为历史问题
- 残余风险：仓库中仍有未迁移的复制头脚本；其中一部分属于 `shelllib.sh` 兼容层或自定义 `_run/_runAsRoot` 语义家族，后续需要单独分组评估再迁移
