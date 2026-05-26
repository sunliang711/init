# gpgctl 空参数报错修复说明

## Bug 修复摘要

- 问题：直接执行 `bin/gpgctl` 时出现 `parsed_args[@]: unbound variable`
- 根因：脚本启用了 `set -u`，在 Bash 3.2 环境下空数组直接以 `"${parsed_args[@]}"` 展开会触发未绑定变量错误
- 修复方式：在主入口中先判断 `parsed_args` 数量；为空时分发到 `help`，非空时再展开参数数组
- 影响范围：仅影响无参数执行路径，不改变已有子命令参数和输出行为
- 验证方式：`bash -n bin/gpgctl`、`shellcheck bin/gpgctl`、`bin/gpgctl`、`bin/gpgctl help`、`bin/gpgctl version`
- 回归风险：低，修复点位于入口分发逻辑
