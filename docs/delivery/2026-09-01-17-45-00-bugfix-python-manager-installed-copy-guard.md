# manager 拒绝从已安装副本更新工具文件

## 背景

两个 manager 都是自举安装：`install` 把工具自身拷到
`/opt/<product>/lib/<product>-init-tools`，并链接到 `/usr/local/bin/<product>-manager`。

拷贝的源目录来自 `current_script_dir(__file__).parent`，也就是**当前执行的那份脚本所在目录**。
因此从已安装的入口跑 `install` 或 `tools update` 时，源目录和目标目录是同一个，
拷贝是空操作：旧代码继续留在节点上，而输出里没有任何异常，看起来更新成功了。

这个坑此前只写在 `tools update` 的 `--help` 文字里，运行时没有任何拦截。

## 改动

两个工具各新增 `running_from_installed_copy(script_dir)`，判断脚本目录是否等于
`TOOL_DIR` 或位于其下：

- **`tools update`**：命中时 `CLIError` 退出。它在这种情况下百分之百是空操作，
  继续执行只会给出虚假的成功信息。
- **`install`**：命中时 `log_warn` 两行说明工具文件不会更新，**但继续执行**。
  因为 Nomad / Consul 本体的安装在这种情况下仍然是有效的，不该被拦下。

## 验证结果

`tests/test_manager_tool_source.py` 6 条用例，对两个工具各跑一遍：

- `TOOL_DIR` 本身被判定为已安装副本
- `TOOL_DIR` 的子目录被判定为已安装副本（入口脚本实际位于 `TOOL_DIR/<pkg>/`）
- 源码 checkout 路径不被判定
- **前缀相同但非子目录的兄弟路径不被误判**（`init-tools` 与 `init-tools-backup`）
- 从已安装副本跑 `tools update` 抛 `CLIError`，且 `install_tool_snapshot` 一次都没被调用
- 从 checkout 跑 `tools update` 正常返回 0，且 `install_tool_snapshot` 恰好被调用一次

其余：

- 该用例在 `-W error::ResourceWarning` 下通过
- 手工演示了三条路径的实际输出：已安装副本跑 `tools update` 报错、
  checkout 跑 `tools update` 正常、已安装副本跑 `install` 告警后继续
- `tests/cli-smoke.bats` 新增 1 条调用该用例
- 两套工具全量 `py_compile`、四份 Python 测试、20 个 tutor topic、
  `bash bootstrap/verify.sh`、`git diff --check` 均通过

## 未覆盖风险

- 判定基于路径包含关系。如果 `TOOL_DIR` 与源码 checkout 之间存在符号链接互指，
  `resolve()` 后仍可能判定为同一目录；这种布局本身就不该出现，未做额外处理。
- 未在目标 Linux 机器上验证。
