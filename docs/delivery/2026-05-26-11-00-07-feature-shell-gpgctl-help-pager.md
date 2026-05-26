# gpgctl 帮助分页交付说明

## 变更摘要

- 修改脚本：`bin/gpgctl`
- 新增能力：当帮助信息行数超过当前终端高度时，自动使用 `less` 分页显示
- 兼容行为：非交互输出、管道和重定向场景继续直接打印帮助文本

## 实现说明

- 将帮助内容拆分为 `usage_text` 和 `usage`
- `usage_text` 只负责生成帮助文本
- `usage` 负责检测 stdout 是否是终端、`less` 是否可用、帮助文本是否超过终端高度
- 分页时使用 `LESS="${LESS:-FRX}" less`，保留用户已有 `LESS` 配置

## 验证情况

- 已通过：`bash -n bin/gpgctl`
- 已通过：`shellcheck bin/gpgctl`
- 已通过：`bin/gpgctl help`
- 已通过：`bin/gpgctl help | rg encrypt`
- 已通过：`bin/gpgctl version`
