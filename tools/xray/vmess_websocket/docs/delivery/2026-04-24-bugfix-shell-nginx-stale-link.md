# Bug 修复交付记录

## 问题
- `install-nginx` 流程中执行 `systemctl start nginx` 失败。
- `nginx` 报错：`/etc/nginx/sites-enabled/vmess-websocket.conf` 指向的配置文件不存在。

## 根因
- 系统中残留了当前站点的悬空符号链接。
- 启动 `nginx` 前未清理该坏链接，导致 `nginx -t` 失败，服务无法启动。

## 修复方式
- 在 `install_nginx()` 开头增加坏链接清理逻辑。
- 仅当 `nginxSiteLink` 是符号链接且目标不存在时，删除该链接。
- 保留后续 `systemctl start nginx` 和 `systemctl enable nginx` 行为不变。

## 影响范围
- 仅影响 `vmess-websocket` 站点在 `nginx` 模式下的安装/重试流程。
- 不改变其他站点配置，也不改变证书签发逻辑。

## 验证
- `bash -n vmessWebsocket.sh`

## 回归风险
- 当前修复只清理 `vmess-websocket` 对应的坏链接。
- 若系统中存在其他站点的坏链接，`nginx` 仍可能因其他无关配置失败。
