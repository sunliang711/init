# manager 记录并展示安装时的源码版本

## 背景

「我这台机器上装的到底是哪个版本的工具」此前无法回答。`VERSION` 里只有
`source_dir` 和时间戳，`install.json` 只有产品版本号（Nomad / Consul / Vault 的版本），
都不反映**工具自身**的代码版本。

后果是排查时只能靠 grep 某个功能的字符串反推，例如
`grep -c cni_plugin_version /opt/nomad/lib/nomad-init-tools/nomad_tools/manager.py`。
这个问题在两次排查里都出现过。

## 改动

三个工具各新增：

- `source_tool_revision(script_dir)` —— 取源码树的 git 短版本号，并判断工具目录是否有未提交改动
- `read_installed_tool_revision()` —— 从 `install.json` 回读，回退到 `VERSION`

写入位置：

```
# VERSION
tool=nomad-manager
nomad_version=2.0.0
tool_revision=1b180f0
tool_revision_dirty=false
installed_at=...
source_dir=...
```

`install.json` 同步新增 `tool_revision` 与 `tool_revision_dirty` 两个字段。

展示位置：`status` 增加一行 `tool revision`，`doctor` 的 Node runtime 段增加一行 INFO。
`install_tool_snapshot()` 的日志也会打印本次快照来自哪个版本。

源码树不是 git 仓库、或 git 不可用时返回 `unknown`，不报错。

## 一个实现上的坑

脏标记必须**限定在工具目录内**，否则仓库里任何无关文件的改动都会把工具标成 dirty。
第一版写成：

```python
run(["git", "-C", str(script_dir), "status", "--porcelain", "--", str(script_dir)])
```

`-C` 已经切到了 `script_dir`，pathspec 再给 `tools/nomad` 就被解析成
`tools/nomad/tools/nomad`，永远匹配不到 —— **dirty 恒为 False，且 git 会往 stderr 打
`could not open directory` 警告**。当时本地明明有未提交改动却返回 `False`，才发现。
正确写法是 pathspec 用 `.`。

顺带把 nomad 的 `read_installed_nomad_version()` 改为复用新增的 `read_install_metadata()`，
consul 与 vault 本来就有这个函数，nomad 是内联解析的。

## 验证结果

`tests/test_manager_tool_revision.py` 9 条用例，对三个工具各跑一遍。
用例在临时目录里真建一个 git 仓库，包含 `tools/thing` 和 `tools/other` 两个目录：

- 干净 checkout 返回合法短版本号且 dirty 为 false
- 工具目录内的文件被改 -> dirty 为 true
- **仓库内工具目录之外的文件被改 -> dirty 仍为 false**（就是上面那个坑）
- 工具目录内的未跟踪文件 -> dirty 为 true
- 非 git 目录返回 `("unknown", False)`
- 版本号优先从 `install.json` 读，dirty 时带 `-dirty` 后缀
- `install.json` 缺失时回退到 `VERSION`
- 两者都没有时返回 `unknown`

其余：

- 全部 7 份 Python 测试在 `-W error::ResourceWarning` 下通过
- `tests/cli-smoke.bats` 新增 2 条：Python 用例调用、三个工具的 `status` 都输出 `tool revision`
- 三套工具全量 `py_compile`、无未使用 import、`bash bootstrap/verify.sh`、`git diff --check` 通过

## 未覆盖风险

- 版本号在**安装时**记录。如果有人直接改了 `/opt/<product>/lib/` 下的文件，
  记录的版本号不会变，仍会显示成那次安装的版本。`MANIFEST.sha256` 本来可以检出这种情况，
  但目前没有任何命令校验它 —— 这仍是个待办。
- 未在目标 Linux 机器上执行过实际安装。
