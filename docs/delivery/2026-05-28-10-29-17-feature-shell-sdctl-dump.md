# sdctl dump 子命令交付说明

## 变更摘要

- 在 `bin/sdctl` 新增 `dump SRC_NAME DST_NAME` 子命令。
- 源 unit 只从 `/etc/systemd/system`、`/lib/systemd/system`、`/usr/lib/systemd/system` 查找。
- 目标 unit 写入 `/etc/systemd/system`，复制后进入编辑器，编辑器成功退出后执行 `systemctl daemon-reload`。
- 目标未显式写 `.service` 或 `.timer` 后缀时，自动沿用源 unit 类型。
- 目标已存在时拒绝覆盖。

## 入口参数

```bash
sdctl dump SRC_NAME DST_NAME
```

示例：

```bash
sdctl dump ssh custom-ssh
sdctl dump apt-daily.timer custom-apt-daily.timer
```

## 保护措施

- 写入类命令纳入自动 sudo 重进逻辑。
- 复制前检查 systemd Linux 环境、root 权限、目标目录、目标文件不存在、源文件可读。
- 目标后缀必须与源 unit 类型一致，避免 timer 被复制成 service。

## 验证情况

- `bash -n bin/sdctl tests/cli-smoke.bats`
- `shellcheck bin/sdctl`
- `bash bin/sdctl help`
- `bash bootstrap/verify.sh smoke`

未运行 `bats tests/cli-smoke.bats`：当前本机未安装 `bats`。
