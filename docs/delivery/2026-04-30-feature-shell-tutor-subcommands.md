# Nomad / Vault tutor 子命令交付说明

## 变更范围

- `tools/nomad/manager.sh`
  - 新增 `tutor [topic]` 子命令。
  - 顶层 help 增加 tutor 入口。
  - 场景覆盖：`install`、`docker`、`vault`、`vault-jwt`、`consul`、`ui`、`job`、`uninstall`、`troubleshoot`。

- `tools/vault/manager.sh`
  - 新增 `tutor [topic]` 子命令。
  - 顶层 help 增加 tutor 入口。
  - 场景覆盖：`install`、`init`、`auth`、`policy`、`nomad-jwt`、`uninstall`、`troubleshoot`。

- `tools/nomad/job`
  - 新增 `tutor [topic]` 子命令。
  - 顶层 help 增加 tutor 入口。
  - 场景覆盖：`docker`、`compose`、`vault`、`volume`、`lifecycle`。

## 行为说明

- `tutor` 只输出教程和示例命令，不执行安装、配置、删除或提交 job。
- `tutor` 输出走 stdout；执行开始/结束日志仍走 stderr。
- 未知 topic 会输出 tutor 总览并返回错误。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
./tools/nomad/manager.sh help
./tools/vault/manager.sh help
./tools/nomad/job help
./tools/nomad/manager.sh tutor
./tools/nomad/manager.sh tutor vault-jwt
./tools/vault/manager.sh tutor
./tools/vault/manager.sh tutor nomad-jwt
./tools/nomad/job tutor
./tools/nomad/job tutor lifecycle
```

并循环验证了所有已支持 topic。

结果：全部通过。
