# consul install 生成 gossip 密钥时 Permission denied

## 现象

目标机器上 `./consul-manager install` 在建完目录后失败：

```
[INFO] Creating Consul directories
[ERROR] [Errno 13] Permission denied: '/var/tmp/consul-install.qvnvdlo9/extract/consul'
```

前面的下载、校验、安装二进制、`consul version` 全部成功。

## 根因

`generate_gossip_key()` 优先执行**解压出来的**那份二进制：

```python
binary = tmpdir / "extract" / "consul"
source = str(binary) if binary.is_file() else str(BIN_PATH)
result = run([source, "keygen"], capture=True)
```

而 `zipfile.extractall()` **不保留归档里记录的权限位**。HashiCorp 发布包里
`consul` 是 0755，解压出来变成 0644 —— 不可执行，于是 `Permission denied`。

已用脚本复现确认：

```
zip 里记录的模式: 0755
解压后实际模式: 0644   可执行: False
```

`install_binary()` 之所以没受影响，是因为它走的是 `install -m 0755 <src> <dst>`：
源文件只需可读，目标权限由 `-m` 指定。所以 `consul version` 能跑通，
偏偏轮到 `keygen` 才炸。

## 改动

### 1. 直接原因

`generate_gossip_key()` 改为使用已安装的 `BIN_PATH`。`cmd_install` 里
`install_binary()` 在它之前执行，此时 `/opt/consul/bin/consul` 已经是 0755，
那个「优先用解压副本」的分支本来就没有意义。函数不再需要 `tmpdir` 参数。

### 2. 底下的陷阱

`extract_zip()` 改为逐个成员解压并还原归档记录的模式，三份 `common.py` 同步修改。
`zipfile` 丢弃可执行位是个通用陷阱，nomad 和 vault 目前只是碰巧没有执行解压产物
（都是 `install -m 0755` 之后再执行 `BIN_PATH`），但没有理由把这个雷留着。

`external_attr` 为 0 的归档（例如 Windows 上打的包）不做 chmod，避免把文件设成 0000。

nomad 的 CNI 解压走的是 `safe_extract_cni_archive()`（tar），不受影响；
它随后也是用 `install -m 0755` 拷贝插件。

## 验证结果

`tests/test_manager_extract_zip.py` 5 条用例，构造一个含 0755 成员的 zip：

- 三份 `common.py` 解压后可执行位都保留
- **解压出来的文件确实能执行**（`subprocess.run` 跑一遍，比对 stdout）
- 普通文件不会被误设为可执行
- 嵌套目录成员正常解压
- `external_attr` 为 0 的归档不报错

其余：

- 全部 8 份 Python 测试在 `-W error::ResourceWarning` 下通过
- `tests/cli-smoke.bats` 新增 1 条
- 复核了三个工具里所有引用 `extract/<binary>` 的位置，除 `is_file()` 判断外
  都只作为 `install -m 0755` 的源，不再有直接执行解压产物的地方
- 三套工具全量 `py_compile`、`bash bootstrap/verify.sh`、`git diff --check` 通过

## 未覆盖风险

- 未在目标 Linux 机器上重跑 `consul install` 验证修复。本机无法执行该路径，
  只能通过复现脚本证明权限位问题已消除。
- 修复后 `install` 会继续走到 `write_consul_config` 及之后的步骤，
  那些步骤此前从未在真机上跑到过，可能暴露新的问题。
