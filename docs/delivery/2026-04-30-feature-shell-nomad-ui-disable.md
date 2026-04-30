# Nomad UI disable 语义修正交付说明

## 变更范围

- 修改 `tools/nomad/manager.sh` 中 `ui disable` 的行为。
- 新增 `tools/nomad/manager.sh ui reset` 子命令。
- 更新 `ui --help` 和顶层 help 中的 UI 子命令说明。

## 行为变化

- `ui disable` 现在会写入托管配置文件 `/etc/nomad.d/35-ui.hcl`：

```hcl
ui {
  enabled = false
}
```

- 写入后仍沿用既有流程：
  - 校验 `nomad config validate /etc/nomad.d`
  - 重启 `nomad.service`
  - 失败时回滚托管配置

- `ui reset` 用于删除脚本托管的 UI 配置文件，恢复 Nomad 默认行为。
- 因为 Nomad 默认 `ui.enabled=true`，所以 `ui reset` 不等同于禁用 Web UI。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
./tools/nomad/manager.sh ui --help
./tools/nomad/manager.sh help
```

结果：全部通过。
