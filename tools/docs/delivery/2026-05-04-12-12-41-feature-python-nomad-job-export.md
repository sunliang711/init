# Nomad job export

## 背景

需要通过 `nomad-manager export [job1] [job2] ...` 导出已提交到 Nomad 的 job HCL；不传 job 参数时导出所有 job。

## 实现方案

- 新增 `nomad-manager export` 子命令。
- 指定 job 时逐个执行 `nomad job inspect -hcl <job>`。
- 未指定 job 时优先执行 `nomad job status`，解析表格第一列的 job ID，再逐个导出。
- `nomad job status` 失败时直接返回 Nomad CLI 的真实错误，避免 ACL token 缺失或权限不足时误报无 job。
- 当文本输出成功但无法识别 job ID 且不像无 job 提示时，fallback 到 `nomad job status -json`。
- JSON 兜底解析兼容 `ID`、`JobID`、`Name` 字段、顶层 `Jobs/jobs/Items/items` 包装，以及 `Summary.JobID`、`LatestDeployment.JobID`、`Allocations/Evaluations[].JobID` 这类 Nomad 状态详情结构。
- 默认输出目录为 `jobs/exported`。
- 文件名使用 job ID 生成，包含路径或特殊字符时会转为安全文件名并追加短 hash。
- 默认不覆盖已有文件，使用 `--force` 才覆盖。

## 导入方案建议

导入不建议直接做单步 `import`，因为 `nomad job run` 会改变线上调度状态。建议后续做成两阶段：

1. `nomad-manager import plan <files...>`：对每个 HCL 先执行 `nomad job validate` 和 `nomad job plan`，只展示计划。
2. `nomad-manager import apply <files...>`：再次 validate/plan，要求 `--yes` 或交互确认后执行 `nomad job run`。

可选增强：

- 支持 `--dir jobs/exported` 批量导入目录。
- 支持 `--detach`、`--namespace`、`--nomad-arg` 透传 Nomad 参数。
- 默认拒绝导入空目录或非 `.hcl` 文件。
- 输出导入顺序和失败文件，失败时停止后续 apply。

## 验证结果

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=nomad python3 -B nomad/nomad-manager export --help`
- 使用 fake Nomad 输出验证无参数时优先通过 `nomad job status` 表格导出全部 job。
- 使用 fake Nomad 输出验证指定 job 时能生成安全文件名。
- 使用 fake Nomad 输出验证 `nomad job status` 返回错误时会暴露真实错误。
- 使用 fake Nomad 输出验证文本成功但无法解析时，会 fallback 到 JSON 的 `JobID/Name` 字段、顶层 `Jobs` 包装、嵌套 `Summary/LatestDeployment/Allocations/Evaluations` 字段兼容路径。
- 在 `service110` 上 source `/home/eagle/nomad.acl` 后验证远程 Nomad 有 11 个 job；远程现有安装版显式传入所有 job 可导出成功。
- 将 text-first 修复后的 `nomad_tools` 临时放到 `service110:/tmp/nomad-manager-patched` 后验证 `nomad-manager export --out-dir /tmp/nomad-export-test-codex-textfirst --force` 可无参数导出全部 11 个 job。

## 风险

导出只读 Nomad job 信息并写入本地文件，不会修改 Nomad 状态。导出的 HCL 可能包含 job 中已提交的敏感环境变量或模板内容，输出目录应按需保护。
