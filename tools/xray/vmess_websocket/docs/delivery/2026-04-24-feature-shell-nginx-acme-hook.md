# 功能交付记录

## 变更
- 为 `nginx` 模式新增 `install_acme_reload_hook_nginx_sh()`。
- `nginx` 模式安装流程中，签发证书前会先安装 `/usr/local/bin/acme_reload_hook.sh`。
- `issue_cert_nginx()` 中 `acme.sh --install-cert` 的 `--reloadcmd` 改为调用 `/usr/local/bin/acme_reload_hook.sh`。
- `uninstall_nginx_proxy()` 增加对 `/usr/local/bin/acme_reload_hook.sh` 的清理。

## 入口参数
- 无新增参数。

## 行为说明
- 续签回调会先执行 `nginx -t`。
- 若 `nginx` 已启动，则优先 `reload`，失败时回退到 `restart`。
- 若 `nginx` 未启动，则尝试 `start`。

## 保护措施
- 仅修改 `nginx` 模式证书续签回调行为。
- 不改变 `xray direct TLS` 模式原有 hook 内容。

## 验证情况
- `bash -n vmessWebsocket.sh`
- `shellcheck vmessWebsocket.sh`
