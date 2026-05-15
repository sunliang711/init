# Shell 重构交付记录：proxy helpers

## 目标

- 优化 `dockerproxyon` / `dockerproxyoff` 的权限检查、运行环境检查和错误处理。
- 降低固定 `/tmp` 临时文件路径带来的冲突和符号链接风险。
- 顺手收口同一组 proxy helper 中的失败短路、变量引用和 `eval` 风险。
- 保持命令名、代理参数和 systemd 配置格式不变。

## 改动脚本

- `config/shell/shared/functions.sh`

## 改动内容

- `dockerproxyon` 先检查 Linux 环境，再检查 root/sudo 权限，避免非 Linux 环境触发不必要的 sudo 校验。
- `dockerproxyon` 使用 `mktemp` 创建临时配置文件，并在写入或移动失败时清理临时文件后返回失败。
- `dockerproxyon` 对目录创建和配置移动增加失败短路，避免无效重启 Docker。
- `dockerproxyoff` 补齐 Linux 环境检查、root/sudo 权限检查和配置文件存在性判断。
- `dockerproxyoff` 删除配置失败时直接返回失败，不再继续重启 Docker。
- `_restartDocker` 在 `daemon-reload` 失败时不再继续重启 Docker。
- `dockerproxyon` / `aptproxyon` 使用 `install -m 0644` 写入 root 配置文件，避免把用户属主的临时文件直接移动到系统目录。
- `aptproxyon` 固定 `/tmp/httpProxy` 改为 `mktemp`，并补齐写入和安装失败短路。
- `aptproxyoff` 删除单个配置文件时不再使用 `rm -rf`，并在文件不存在时直接跳过。
- `macproxyon` 去掉 `eval`，改为数组参数调用 `setMacProxy`。
- `parseProxy` 读取代理缓存文件时对 `${PROXY_FILE}` 加引号，并支持从 `http_proxy` 或 `https_proxy` 读取。
- `envProxyOn` / `envProxyOff` 保存或删除代理缓存文件前校验 `${PROXY_FILE}`。
- `gitproxyon` 对代理参数加引号，并在 `git config` 失败时返回失败。
- `proxyon` 在解析不到代理时直接返回失败，不再继续调用下游函数。

## 保持不变的行为

- `dockerproxyon <proxy>` 仍写入 `/etc/systemd/system/docker.service.d/proxy.conf`。
- 生成的配置仍包含 `HTTP_PROXY` 和 `HTTPS_PROXY` 两项。
- 配置写入或删除成功后仍执行 Docker daemon reload 和 Docker restart。
- 已存在配置时，`dockerproxyon` 仍直接提示并退出，不自动覆盖。
- `aptproxyon` / `aptproxyoff` 的命令名、配置路径和配置内容保持不变。
- `macproxyon` 仍同时设置 HTTP 和 HTTPS 系统代理。
- `proxyon` 仍按原顺序调用 `gitproxyon` 和 `envProxyOn -s`。

## 验证结果

- `zsh -n config/shell/shared/functions.sh`：通过。
- `sed -n '831,1188p' config/shell/shared/functions.sh | shellcheck --shell=bash -`：通过。
- `sed -n '1242,1277p' config/shell/shared/functions.sh | shellcheck --shell=bash -`：通过。
- `git diff --check`：通过。
- 当前 macOS 环境手工调用 `dockerproxyon` / `dockerproxyoff`：均先进入非 Linux 保护分支，未触发 sudo 或系统修改。
- 当前 macOS 环境用临时 `setMacProxy` 函数验证 `macproxyon` 参数调用：通过。
- 使用临时 `${PROXY_FILE}` 验证 `envProxyOn -s`、`parseProxy`、`envProxyOff -s`：通过。

## 残余风险

- 未在真实 Linux + systemd + Docker 环境执行实际启停验证。
- 未在真实 Debian/Ubuntu apt 环境执行 `/etc/apt/apt.conf.d/httpProxy` 写入和删除验证。
- 未实现 `--force` 覆盖已有 Docker 代理配置，仍沿用原来的存在即退出行为。
