# nomad install 写入 job_gc_threshold

## 背景

Nomad 服务端默认在作业进入 dead 状态 4 小时后回收它，之后 `nomad job status` 和 UI 里
就查不到这次运行的记录了。对单节点自用场景，保留历史通常比及时回收更有价值。

## 改动

`write_nomad_config()` 在 `server` 块里写入 `job_gc_threshold`：

```hcl
server {
  enabled          = true
  bootstrap_expect = 1
  job_gc_threshold = "87600h"
}
```

- 新增 `install --job-gc-threshold`，默认 `87600h`（10 年，实际等于不回收）。
  help 里同时标出 Nomad 自身的默认值 4h，便于判断这是本工具的选择而非 Nomad 的行为。
- 新增 `validate_go_duration()`，在写文件之前校验格式。非法值（`forever`、裸数字 `87600`、
  空串）直接报错并说明应使用 Go duration，而不是等 `nomad config validate` 或服务启动失败。

## 验证结果

`tests/test_nomad_manager_install_config.py` 8 条用例：

- 默认值被写入
- **`job_gc_threshold` 落在 `server` 块内**，且不出现在 `client` 块里
  （写错块会被 Nomad 忽略或报错，用 `hcl_block_body()` 按块作用域断言）
- 自定义值生效
- 非法 duration 被拒，且**拒绝时一个字节都没写出去**
- 裸数字被拒
- 复合 duration（`1h30m`）被接受
- **`install --job-gc-threshold 72h` 能穿过解析器到达 `cmd_install`**
  （解析器与 `cmd_install` 之间有一层手写的 Namespace 转换，最容易漏字段）
- help 文本里标出了默认值

其余：全部 Python 测试在 `-W error::ResourceWarning` 下通过；
`tests/cli-smoke.bats` 新增 1 条；三套工具全量 `py_compile`；
`bash bootstrap/verify.sh`、`git diff --check` 通过。

## 未覆盖风险

- 未在目标机器上执行 install 验证。
- 该值只在 install 时写入基础配置 `nomad.hcl`。已装节点要修改需手工编辑并重启 nomad.service，
  工具没有提供修改入口。
- `status` 与 `doctor` 目前不报告基础配置的取值（consul-manager 有 `base_config_values()`，
  nomad-manager 没有对应实现），所以装完之后无法通过工具确认这一项的实际取值。
