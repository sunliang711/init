# 2026-04-10 Shell Bugfix：修复 `sudo -i` 后误写原用户家目录

## 问题现象

- 普通用户 `eagle` 执行 `./install.sh install --all` 正常。
- 使用 `sudo -i` 切到 `root` 后，再执行 `./install.sh install --all`，会把 `/home/eagle/.zshrc` 链接到 `/root/.local/apps/init/config/zsh/zshrc`。

## 根因

- `bootstrap/lib/runtime.sh` 以前只要检测到 `SUDO_USER`，就直接把安装目标用户认定为提权前的用户。
- 这对 `sudo ./install.sh` 这种“临时提权帮原用户安装”的场景是合理的。
- 但对 `sudo -i` 进入 `root` 登录环境后再执行脚本的场景，目标用户应当跟随当前登录环境与仓库路径，而不是继续写回原用户家目录。

## 修复方式

- 新增目标用户推导逻辑：
  - 仓库位于当前 `HOME` 下时，优先认为是在给当前登录用户安装。
  - 仓库位于 `SUDO_USER` 家目录下时，继续认为是在给原用户安装。
  - 其他情况保持兼容，仍回退到 `SUDO_USER`。

## 验证

- 为 `bootstrap/verify.sh` 增加两条回归测试：
  - 模拟“以 root 身份执行用户仓库”时仍应写回原用户家目录。
  - 模拟“`sudo -i` 后在 root 仓库执行”时应写入当前 root 家目录。
