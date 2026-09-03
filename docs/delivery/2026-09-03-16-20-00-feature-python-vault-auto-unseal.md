# vault install 默认装上开机自动解封单元

## 背景

Vault 每次重启都会 seal，API 一律 503，直到有人拿 unseal key 手工解封。单机自用场景下这意味着
每次重启、每次 `vault-manager upgrade`、以后每次改配置重启，都要人到场敲一次 `unseal`——
否则依赖 Vault 的东西全部停摆，而且没有任何告警。

## 改动

### vault-unseal.service

```ini
[Unit]
Description=Unseal Vault after vault.service starts
Requires=vault.service
After=vault.service
PartOf=vault.service
ConditionPathExists=/opt/vault/init/vault-init.json
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
Group=root
ExecStart=/usr/local/bin/vault-manager unseal --wait --keys-file /opt/vault/init/vault-init.json
Restart=on-failure
RestartSec=5
TimeoutStartSec=180

[Install]
WantedBy=vault.service
```

四条指令是承重的，别的都可以商量：

- **`WantedBy=vault.service`**（不是 `multi-user.target`）：后者只在开机拉一次，
  `systemctl restart vault` 之后 Vault 会一直锁着——而 `upgrade` 每次都重启它。
  装到 `vault.service.wants/` 之后，vault 每次启动都会带上这个单元。
- **`PartOf=` + `RemainAfterExit=yes`**：`PartOf` 传播的是 try-restart，对已经退出的 oneshot
  是空操作；留在 active(exited) 状态才接得住重启。
- **`ConditionPathExists=`**：`install` 在 `init` 之前就 enable 了它，此时密钥文件还不存在。
  没有这个条件，`Restart=on-failure` + `RestartSec=5` 就是开机后每 5 秒起一个进程的无限循环。
  有了它，单元被静默跳过，`init` 写出文件之后自然生效。
- **`unseal --wait`**：`vault.service` 是 `Type=simple`，`After=` 只保证进程 fork 了，
  监听端口通常还没起来。新增的 `--wait` 复用 `wait_for_vault_api()` 先等 API，
  省掉每次开机必然失败一两次的重试和日志噪音。

`StartLimitBurst=10` 是有界的：密钥轮换过、文件对不上时会停下来变成 failed，doctor 会报，
而不是永远重试。

### 命令与开关

- `install` 默认装并 enable（只 enable 不 start，此时没有密钥），`--no-auto-unseal` 跳过。
- 装完之后仍可改：`vault-manager auto-unseal enable | disable | status`，
  按仓库里 `ui`/`tls` 那组子命令的惯例，归入 "Bring Vault online" 分组、排在 `unseal` 之后。
  `enable --keys-file` 可以指向别的文件，`unseal_service_keys_file()` 从已装的单元里读回它。
- `unseal --wait`：默认关，手工执行行为不变。

### 报告与清理

- `doctor` 新增 `Auto-unseal:` 段落：enabled 时报出 OK 加一行「密钥在本机，seal 不再提供静态保护」；
  装了没 enable → WARN；密钥文件不在 → WARN；单元 failed → FAIL 并指向 journalctl。
  这是状态报告不是故障判定，所以正常启用的情况不计入 failures。
- `status` 增加 `auto-unseal` 一行。
- `uninstall` 先 `disable --now` 再停 vault，单元文件进入清理路径与计划文本。
- `upgrade` 结尾原本无条件打印「Vault 已 sealed，去 unseal」，现在自动解封开着时改为提示会自解封；
  升级计划里也补一行。
- install 的 next steps、`unseal` 与 `install` 的 help、`tutor unseal`、`quickstart` 里
  「每次重启都要手工解封」的说法一并更新。

### 独立 review 之后补的四处

单元本身经查证没有问题（`Restart=on-failure` 对 oneshot 合法、`StartLimit*` 在 `[Unit]` 是对的、
`WantedBy` 指向一个 service 时 `systemctl enable` 会生成 `vault.service.wants/`、
`PartOf` + `RemainAfterExit` 确实能让重启传播到已退出的 oneshot）。改的是外围四处：

- **`Path.is_file()` 在 EACCES 时抛异常而不是返回 False**（pathlib 只吞 ENOENT/ENOTDIR/EBADF/ELOOP，
  3.14 才改）。`INIT_DIR` 是 0700 root，于是 sudoer 身份跑 `doctor` 会在 `Auto-unseal:` 段落直接中断，
  后面的 `Vault state:`（初始化、seal 状态）整段不会执行；`auto-unseal enable` 更糟，
  单元已经写好并 enable 了才报错退出。新增 `keys_file_present()` 返回三态，
  读不到时报「not readable from here」而不是崩掉，enable 则交给 systemd 的条件去判断。
  本机 Python 3.14 吞掉了这个异常，所以测试用桩对象复现，不依赖版本。
- **`upgrade` 只看 `systemctl is-enabled` 就宣称会自动解封**。工具自己建议把密钥备份到别处，
  文件一挪走单元就被条件跳过，而 upgrade 会打印「应该已经解封了」并省掉手工 unseal 那一步。
  改成 `auto_unseal_will_run()`：enabled 且密钥文件确实在，才这么说；enabled 但文件不在时明确告警。
- **`install --no-auto-unseal` 不会关掉已经装上的单元**，还打印「未安装」。install 是可以重复跑的，
  这是安全取舍上更要紧的那个方向（报告说关了、实际开着）。补上 else 分支。
- **`auto-unseal enable --keys-file` 不校验**，相对路径会被原样写进 unit，
  而单元以 `WorkingDirectory=/` 运行，永远指不到用户想的文件。改为要求绝对路径。

顺带把 `status` 的那行抽成 `print_auto_unseal_status_line()`（原来内联在 `cmd_status` 里没法测），
并让它在密钥文件缺失时标出来。

## 验证结果

`tests/test_vault_manager_auto_unseal.py` 38 条：

- unit 文本逐条断言：`WantedBy=vault.service` 且**不含** `multi-user.target`、`PartOf`、
  `Type=oneshot` + `RemainAfterExit`、`ConditionPathExists`、
  `ExecStart` 用 `TOOL_ENTRY` 且带 `--wait`、`User=root`、有界重试
- 从已安装的单元里读回密钥文件路径（round-trip）
- enable：写文件 + daemon-reload + enable；**密钥不存在时不 start**；install 时一律不 start；
  **打印那句「密钥在本机」的代价说明**
- disable：`disable --now` + 删文件 + daemon-reload
- install 参数穿过手写 Namespace：默认 `auto_unseal=True`，`--no-auto-unseal` 为 False
- `unseal --wait` 在查状态之前先等 API；不带 `--wait` 不等
- doctor 五种状态：启用、装了没启用、密钥缺失、单元 failed（唯一计入 failures 的）、未安装
- uninstall 计划与路径列表包含该单元

review 之后补的覆盖（这些位置之前改坏了测试也不会红）：

- `cmd_install` 的函数体本身：默认 enable 且 `start=False`、`--no-auto-unseal` 关掉已有单元、
  干净机器上加 flag 什么都不做
- `cmd_uninstall` 的函数体：`disable --now` 且**排在停 vault 之前**
- `cmd_status` 的那一行三种状态
- `upgrade` 的两个分支（会自解封 / enabled 但密钥不在）
- `keys_file_present()` 三态、doctor 与 enable 在读不到时的行为
- `--keys-file` 相对路径被拒且不会走到写单元
- uninstall 计划里那句「Stop and disable service」是独立断言的
  （原来的断言被路径列表里的同名子串顺带满足了，删掉那行也不会红）
- unit 里的 `Requires=`/`After=`/`RestartSec`/`TimeoutStartSec`/`StartLimitIntervalSec`

变异验证覆盖 `WantedBy`、`ConditionPathExists`、「密钥不存在不 start」，
以及 review 报的四个缺陷各自的修复——逐个改回旧写法，对应测试都会红。

其余：全部 Python 测试 221 条通过；`tests/cli-smoke.bats` 新增 3 条（install help 的
`--no-auto-unseal`、`auto-unseal --help`、跑这个新测试文件），断言逐条手工执行过。

## 未覆盖风险

- **没有在带 systemd 的机器上真实跑过**：`PartOf` + `RemainAfterExit` 的重启传播、
  `ConditionPathExists` 的跳过行为、`WantedBy=vault.service` 生成的 wants 链接
  都只对着 systemd 源码和 man page 核对过，没有真机验证。
- `RestartSec=5` + `StartLimitBurst=10` 意味着 Vault 如果在开机时反复起不来超过约 50 秒，
  重试额度就用完了，单元进入 failed 且不再重试，节点保持 sealed。
  doctor 会报 FAIL，vault.service 本身那时候也是坏的，所以不会无声无息。
- **这是一个明确的安全取舍**：unseal key 与 Vault 在同一台机器上，开机自动解封之后，
  seal 不再提供任何静态保护，只剩「重启要人动一下」这个操作性门槛，而这正是本改动去掉的东西。
  能读到 `/opt/vault/init/vault-init.json`（0600 root，父目录 0700）的人就能让 Vault 起来，
  而且同一个文件里还有 root token。默认开启是明确的选择，install、`auto-unseal enable`
  和 doctor 都会把这句话说出来。
- 单元读的就是 `vault-init.json` 本体。可以让 `init` 另写一份只含 `unseal_keys_b64` 的文件
  给单元用，这样自动解封链路上的文件泄露不等于 root token 泄露——本次没做。
- 不涉及 auto-unseal 的另一种含义（KMS/transit seal），这里始终是 shamir key + 本地文件。
