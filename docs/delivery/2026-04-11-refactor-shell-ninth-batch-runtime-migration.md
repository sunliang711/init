## 重构摘要
- 目标：完成第九批根目录安装/源配置脚本迁移，统一改为 source `bootstrap/lib/runtime.sh`
- 改动脚本：`tools/installNvm.sh`、`tools/installNodejs.sh`、`tools/installGolang.sh`、`tools/installRust.sh`、`tools/installBrew.sh`、`tools/cargoSource.sh`、`tools/dockerSource.sh`、`tools/debianSources.sh`
- 保持不变的行为：以上脚本的命令入口、帮助输出和业务逻辑保持不变；仅删除旧的 `shelllib.sh` 定位/下载/source 头，统一改为定位并 source `bootstrap/lib/runtime.sh`
- 验证结果：已执行 `bash -n tools/installNvm.sh tools/installNodejs.sh tools/installGolang.sh tools/installRust.sh tools/installBrew.sh tools/cargoSource.sh tools/dockerSource.sh tools/debianSources.sh`，通过；已执行 `shellcheck tools/installNvm.sh tools/installNodejs.sh tools/installGolang.sh tools/installRust.sh tools/installBrew.sh tools/cargoSource.sh tools/dockerSource.sh tools/debianSources.sh`，迁移新增告警未发现，剩余为迁移前已存在的历史告警；其中 `tools/installNvm.sh`、`tools/installNodejs.sh`、`tools/installGolang.sh`、`tools/installRust.sh`、`tools/installBrew.sh`、`tools/cargoSource.sh`、`tools/dockerSource.sh`、`tools/debianSources.sh` 的历史告警均已分别通过 `git show HEAD:<file> | shellcheck -s bash -` 确认
- 残余风险：仍有部分未迁移脚本依赖旧 `shelllib.sh` 或更复杂的 `_run` / `_runAsRoot` 旧语义；本批脚本中剩余的 quoting、`read`、`editor` 变量、`find` 循环等问题均为历史问题，本轮未顺手修复
