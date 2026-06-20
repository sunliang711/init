# nomad-manager 下载中断重试修复

## 问题

执行 `nomad-manager install` 下载 Nomad release 包时，网络连接中途断开会直接失败：

```text
IncompleteRead(56349601 bytes read, 2039086 more expected)
```

## 根因

`tools/nomad/nomad_tools/common.py` 中的 `download_file()` 通过 `response.read()` 一次性读取完整响应体。代理或远端连接提前断开时，脚本没有分块落盘、进度展示和重试能力。

## 修复

- 将 `download_file()` 改为分块下载到临时文件，下载完成后再原子替换目标文件。
- 交互式终端中展示单行下载进度。
- 对 HTTP 5xx、URL 读取错误、HTTP 协议异常和超时执行最多 3 次重试。
- 对 HTTP 4xx 直接返回明确错误，避免无意义重试。
- 对磁盘写入错误清理临时文件并返回明确错误。

## 影响范围

影响所有复用 `download_file()` 的下载流程：

- Nomad release zip 与 SHA256SUMS 下载。
- CNI plugins tgz 与 sha256 下载。

代理环境变量行为保持不变，仍由 Python `urllib` 默认读取 `http_proxy` / `https_proxy`。

## 验证

```bash
PYTHONPYCACHEPREFIX=/tmp/nomad-manager-pycache python3 -m py_compile tools/nomad/nomad_tools/common.py tools/nomad/nomad_tools/manager.py
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tools/nomad python3 -B -c 'from pathlib import Path; from nomad_tools.common import download_file; src=Path("/tmp/nomad-download-src.txt"); dst=Path("/tmp/nomad-download-dst.txt"); src.write_text("hello nomad\n", encoding="utf-8"); dst.unlink(missing_ok=True); download_file(src.resolve().as_uri(), dst, timeout=10); assert dst.read_text(encoding="utf-8") == "hello nomad\n"; print("download smoke ok")'
```

另外使用本地临时 HTTP 服务模拟 `Content-Length` 大于实际响应体的提前断连，确认下载会重试 3 次并返回明确错误。
