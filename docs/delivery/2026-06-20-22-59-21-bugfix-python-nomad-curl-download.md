# nomad-manager curl 下载优化

## 问题

`nomad-manager install` 在配置 `http_proxy` / `https_proxy` 后，使用 Python `urllib` 下载 HashiCorp release 包速度较慢。

## 根因

`tools/nomad/nomad_tools/common.py` 中的 `download_file()` 默认使用 `urllib` 执行下载。`vault-manager` 已经通过 `curl` 参数数组下载 release 包，在代理环境下表现更稳定。

## 修复

- 新增 `download_file_with_curl()`，优先使用 `curl` 下载文件。
- `curl` 参数对齐 `vault-manager` 的下载策略：`--fail`、`--location`、`--show-error`、`--retry 3`、`--connect-timeout 10`、`--max-time`。
- 下载仍先写入同目录临时文件，成功后原子替换目标文件。
- 当系统没有 `curl` 时，保留原有 `urllib` 分块下载逻辑作为兜底。

## 影响范围

- Nomad release zip 与 SHA256SUMS 下载。
- CNI plugins tgz 与 sha256 下载。
- 本地 Nomad API 健康检查和 `no_proxy=True` 的内部请求逻辑不变。

## 验证

```bash
PYTHONPYCACHEPREFIX=/tmp/nomad-manager-pycache python3 -m py_compile tools/nomad/nomad_tools/common.py tools/nomad/nomad_tools/manager.py
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tools/nomad python3 -B -c 'from pathlib import Path; from nomad_tools.common import download_file; src=Path("/tmp/nomad-download-src.txt"); dst=Path("/tmp/nomad-download-dst.txt"); src.write_text("hello nomad\n", encoding="utf-8"); dst.unlink(missing_ok=True); download_file(src.resolve().as_uri(), dst, timeout=10); assert dst.read_text(encoding="utf-8") == "hello nomad\n"; print("download smoke ok")'
PATH=/nonexistent PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tools/nomad /usr/bin/python3 -B -c 'from pathlib import Path; from nomad_tools.common import download_file; src=Path("/tmp/nomad-download-src-fallback.txt"); dst=Path("/tmp/nomad-download-dst-fallback.txt"); src.write_text("fallback nomad\n", encoding="utf-8"); dst.unlink(missing_ok=True); download_file(src.resolve().as_uri(), dst, timeout=10); assert dst.read_text(encoding="utf-8") == "fallback nomad\n"; print("download fallback smoke ok")'
```
