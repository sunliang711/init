# 2026-04-20 Shell Feature：批量安装并签发 ACME 证书脚本

## 变更摘要

- 新增脚本：`tools/acme_batch_issue.sh`
- 入口参数：
  - `--email`
  - `--challenge dns01|http01`
  - `--dns-provider`
  - `--http-mode standalone|webroot`
  - `--webroot`
  - `-d/--domain`
  - `--cert-dir`
  - `--acme-home`
  - `--key-length`
  - `--install-only`
- 依赖命令：
  - `curl`
  - `apt-get`
  - `socat`（仅 `http01 + standalone` 时自动安装）
- 保护措施：
  - 仅允许 root 在 Linux 下执行
  - 参数必填项前置校验
  - `dns01` 模式会校验常见 DNS Provider 的必填环境变量
  - DNS Provider 凭据仍由环境变量提供，脚本不记录敏感值
  - 下载 `acme.sh` 时先保存到临时文件，再执行，不直接使用管道执行

## 使用示例

```bash
# dns01，一次签发两张证书
./tools/acme_batch_issue.sh \
  --email admin@example.com \
  --challenge dns01 \
  --dns-provider dns_cf \
  -d example.com,www.example.com \
  -d api.example.com

# http01 standalone，一次签发两张证书
./tools/acme_batch_issue.sh \
  --email admin@example.com \
  --challenge http01 \
  --http-mode standalone \
  -d example.com \
  -d api.example.com,ws.api.example.com

# http01 webroot
./tools/acme_batch_issue.sh \
  --email admin@example.com \
  --challenge http01 \
  --http-mode webroot \
  --webroot /var/www/acme-challenge \
  -d example.com,www.example.com
```

## 证书输出

- 默认安装目录：`/etc/certs`
- 每张证书按主域名落地：
  - `{primary}.cer`
  - `{primary}.key`
  - `{primary}.pem`
