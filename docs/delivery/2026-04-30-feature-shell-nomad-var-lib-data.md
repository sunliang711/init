# Nomad 数据目录标准布局调整交付说明

## 变更范围

- 将 `tools/nomad/manager.sh` 的默认 Nomad 数据目录从 `/opt/nomad` 调整为 `/var/lib/nomad`。
- Nomad agent 配置中的 `data_dir` 现在写为 `/var/lib/nomad/data`。
- 数据目录指针文件调整为 `/var/lib/nomad/.managed-by-nomad-init-tools`。
- help 和 tutor 中补充运行目录说明：
  - `/etc/nomad.d` 存放 Nomad 配置。
  - `/var/lib/nomad` 存放 Nomad 运行数据。
- 删除保护列表增加 `/var` 和 `/var/lib`，避免危险路径误删。
- 更新相关交付文档中的 Nomad 数据目录路径。

## 行为说明

- 新安装会使用 `/var/lib/nomad`。
- Vault 目录不变，仍使用 `/opt/vault` 和 `/opt/vault/data`。
- 本次不做已有 `/opt/nomad` 数据目录的自动迁移。

## 验证

已执行：

```bash
bash -n tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
shellcheck tools/nomad/manager.sh tools/vault/manager.sh tools/nomad/job
./tools/nomad/manager.sh help
./tools/nomad/manager.sh tutor install
```

结果：全部通过。
