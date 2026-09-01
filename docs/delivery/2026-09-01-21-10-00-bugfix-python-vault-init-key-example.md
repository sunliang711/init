# vault init 示例改为 5 分片 / 3 阈值

## 背景

`init` 的 argparse 默认值本来就是 `--key-shares 5 --key-threshold 3`，
但**所有示例命令写的都是 `--key-shares 1 --key-threshold 1`**，两者各说各话。

照抄示例的人会得到单分片的 Vault：那一个 key 就是任何能读到该文件的人与全部 secret
之间的唯一屏障，而且丢了就等于丢掉整个 raft store。

## 改动

五处示例命令统一改为 `--key-shares 5 --key-threshold 3`：

| 位置 | 说明 |
| --- | --- |
| `print_install_next_steps()` | install 完成后的下一步 |
| `SEAL_HINTS[501]` | doctor 检测到未初始化时给出的修复命令 |
| `cmd_quickstart()` | quickstart 第 2 步 |
| `TUTOR_TOPICS["init"]` | tutor init 的示例 |
| 根 parser 的 `epilog` | `--help` 底部示例 |

`tutor init` 的说明文字重写，解释这个取舍：

- 默认 5 分片 3 阈值：五把钥匙分给不同的人，任何三把可解封。
  单个人无法独自解封，同时丢一两把也还能恢复。
- 保留 `--key-shares 1 --key-threshold 1` 作为**对照**，说明它适合可丢弃的实验环境，
  以及代价是什么。它不再出现在任何建议执行的命令里。

argparse 的默认值本来就是 5/3，未改动。

## 验证结果

`tests/test_vault_manager.py` 新增 3 条用例（共 28 条）：

- 解析器默认值确为 5 分片 3 阈值
- **五个来源里出现的每一条 `init --key-shares N --key-threshold M` 都与默认值一致**
  （来源：根 epilog、quickstart、tutor init、install next steps、SEAL_HINTS）
- 建议执行的命令里不再出现 1/1，同时 `tutor init` 中仍保留它作为对照

第二条做了反向验证：把 `tutor init` 的示例改回 1/1 后，用例确实失败并指出
`tutor init shows 1/1 but the default is 5/3`。这正是本次这个不一致能长期存在的原因 ——
此前没有任何东西把示例和默认值绑在一起。

其余：全部 7 份 Python 测试在 `-W error::ResourceWarning` 下通过；
9 个 vault tutor topic 渲染且散文行宽 <= 80；三套工具全量 `py_compile`；
`bash bootstrap/verify.sh`、`git diff --check` 通过。

## 未改动

`tools/vault-sh/vault-manager` 里还有 4 处 1/1 示例，**有意未改** ——
它是 Python 重写前的原始版本，保留作参照与回退，改它会让它偏离当初实际交付的形态。
如果希望回退路径也给出 5/3 的建议，需要单独确认。
