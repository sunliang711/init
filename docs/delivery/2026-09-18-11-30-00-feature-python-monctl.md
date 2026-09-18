# monctl:把 grafana/prometheus/node_exporter 装机脚本重写成 Python manager

## 背景

`tools.old/grafana/install.sh` 是这套监控栈唯一的装机入口,它有几处是真的会咬人的:

- `installNodeExporter` 把版本写死在 `1.8.1`,`installPrometheus` 走 GitHub 的 `releases/latest`
  ——同一份脚本在两台机器上跑出的版本不一样,而且没有任何地方记下装的是哪个。
- `useradd -rs /bin/false node_exporter` 没有幂等判断,第二次执行直接报错退出,
  此时二进制已经覆盖、service 还没装完。
- 不支持的架构分支里写的是 `$(name -m)`(应为 `uname`),真走到那条分支会是 `command not found`。
- `installGrafana` 是空的,只打印一句「用 docker compose 跑」。
- `configNodeExporter` 交互式读一个 IP,然后 `cat >>` 往 `prometheus.yml` 末尾追加一段 job
  并重启 Prometheus。它只能加不能删、不能列,重复执行就重复追加,
  而且追加出来的 YAML 一旦有问题,Prometheus 是**起不来**而不是拒绝这次改动。

重写成 `tools/monitoring/`,形态对齐仓库里已有的 `consul-manager` / `nomad-manager` /
`vault-manager`:`install` / `doctor` / `status` / `upgrade` / `uninstall` / `tools update` /
`quickstart` / `tutor`,共用同一份 `common.py`(按惯例每个工具目录各存一份)。

## 为什么是一个入口

正常用法是两类机器:每台想看的机器上跑 node_exporter,一台监控机上跑 Prometheus + Grafana。
所以顶层按机器角色分组,组件各自带 `install` / `upgrade` / `uninstall`:

```
monctl node-exporter install|upgrade|uninstall
monctl prometheus    install|upgrade|uninstall|target add|remove|list|reload
monctl grafana       install|upgrade|uninstall
monctl doctor|status|tools update|uninstall|quickstart|tutor
```

采集机上只会用到第一行,监控机上用到后面两行,`doctor` 在两种机器上都能跑
——没装的组件报 `not installed`,不算失败。拆成三个独立 manager 会让 `common.py`
和整套 install/doctor/status 骨架复制三份,而它们要管的其实是同一台机器上的同一套东西。

命令叫 `monctl` 而不是 `<product>-manager`:这里没有单一产品可以往那个模式里填,
而且它是要在多台机器上反复敲的。`ctl` 后缀跟仓库里已有的 `bin/gpgctl`、`bin/sdctl`、
`bin/lctl` 一致。目录和包仍叫 `tools/monitoring/` 与 `monitoring_tools`,按领域命名。

## 就地用还是装到固定目录

两种都行,这是刻意的:

- **就地**:`tools/monitoring/` 自包含(入口脚本 + 纯标准库的 `monitoring_tools` 包),
  `rsync` 这一个目录到任意机器就能跑,不需要先部署整个 init 仓库。
- **装快照**:`install` 默认把这个目录复制到 `/opt/monitoring/lib/monctl`,
  并软链成 `/usr/local/bin/monctl`。这样那台机器以后自己就能 `doctor` / `upgrade`,
  不用再去找源码目录。`--no-install-tools` 跳过;从 checkout 刷新已装副本用 `tools update`,
  在已装副本里跑 `tools update` 会被拒绝(源目录即目标目录,拷贝是空操作)。

## 布局

```
/opt/monitoring/
  bin/{node_exporter,prometheus,promtool}     -> versions/<name>-<version>
  bin/versions/                               每个留在盘上的 release
  share/grafana/current                       -> versions/grafana-<version>
  etc/prometheus/prometheus.yml               生成的,带 managed marker
  etc/prometheus/targets/<job>.json           file_sd 目标文件
  etc/grafana/{grafana.ini,provisioning/}
  data/{prometheus,grafana}                   TSDB 与 Grafana 数据库
  log/{grafana,monctl}
  lib/monctl/                                 本工具的副本
```

三个组件各自一个系统用户;配置归 root 所有、服务只读,数据目录才归服务用户。

## 承重的几个决定

### 抓取目标走 file_sd,不再改 prometheus.yml

`prometheus.yml` 里每个 job 只有一条 `file_sd_configs`,指向 `targets/<job>.json`。
增删地址只动那个 JSON,**Prometheus 自己按 `refresh_interval` 重读**,不用 reload、不用重启。
这同时解决了老脚本的三个问题:可删、可列、重复执行幂等。

只有新建 job 才会改写 `prometheus.yml`,而这次改写是:生成 → `promtool check config` →
不通过就把旧文件放回去再报错。也就是说这条路径上不存在「配置写坏了导致服务起不来」。

删掉一个 job 的最后一个地址时,**保留空文件**,job 还在。这样下一次 add 不用再改
`prometheus.yml`,也就不用 reload。

`prometheus.yml` 是完全生成的,第一行是 managed marker;不是本工具写的文件一律拒绝接管
(`--force` 才覆盖)。JSON 放不下注释行,所以目标文件靠**结构**判断:形状不对就报错不改写。

### 升级切软链、留旧版本、失败回滚

复用 `common.py` 里 consul/nomad/vault 已经在用的版本化布局:新 release 装到
`versions/<name>-<version>`,**先自检再切软链**,重启失败就切回去再重启,两次都失败才放弃并明确报出来。
旧 release 留在盘上(`--keep`,默认 2),回滚才只是一次 rename 而不是再下一次 250 MB。

Grafana 不是单个二进制而是一棵目录树,所以版本化的是目录,`current` 软链指向在用的那个。
它的 systemd 单元里写的是 `current`,不是版本目录——否则每次升级都要改单元。
单元里的 server 命令按解压出来的树选(`bin/grafana server` 或老的 `bin/grafana-server`),
所以 Grafana 升级会重写一次单元。

重装同一个版本时,Grafana 先拷到 `.grafana-<version>.new` 再 rename 就位,
不会把正在跑的进程脚下的文件删掉。

### 校验分两种,自检也分两种

node_exporter / Prometheus 发的是 `sha256sums.txt`(多行,`hash  filename`),
Grafana 发的是 `.sha256`(裸 hash)。两种各有一个校验函数,都在解压之前跑。

装好的二进制自检又分成两种失败:

- **跑不起来**(架构不对、包损坏)→ 硬失败,此时软链还没切,正在跑的版本不受影响。
- **版本读不出来**(Grafana 各版本 `--version` 的格式变过)→ 只警告,按归档名继续。

这两种以前混在一起,前者会以一句裸 `OSError: Exec format error` 冒出来。

### 监听地址的默认值

- node_exporter:`0.0.0.0:9100`。Prometheus 在另一台机器上,这是必须的;
  但它**没有认证也没有 TLS**,所以 install 完会警告、doctor 每次都会 WARN,
  提示把端口限制到监控机。同机部署可以用 `--listen 127.0.0.1:9100`。
- Prometheus:`127.0.0.1:9090`。读它的通常是同机的 Grafana;它自己也没有认证,
  放开只应该发生在一个会做认证的反向代理后面。
- Grafana:`0.0.0.0:3000`,它自己有登录。

### 卸载默认不删数据

计划里分两张表:**Remove paths** 和 **Preserve paths**。默认删二进制、单元、生成的配置和系统用户,
但 Prometheus 的 TSDB 和 Grafana 的数据库(仪表盘、用户)留着,重装能接上。
`--purge` 是删它们的唯一方式,并且计划里会标出来。

### 老布局会挡住安装

老脚本装在 `/usr/local/bin` 和 `/etc/prometheus`,和这套完全不重叠。
两套并存会抢同一个端口,所以只要检测到那些路径或一个不是本工具写的同名 unit,
install 就拒绝并把冲突路径逐条列出来,`--force` 才继续。doctor 也会把它们报出来。

### systemd 硬化里的一处例外

node_exporter 的单元用 `ProtectHome=read-only` 而不是 `yes`:后者会让独立挂载的 `/home`
从 `node_filesystem_*` 里消失——服务是活的,监控是错的,而且不会有任何报错。
同理没有加 `PrivateTmp`,否则 `/tmp` 的用量指标量的是那个私有 tmp。

### 不碰 Grafana 的密码

Grafana 起来是 admin / admin 并强制首次改密。本工具不提供设置密码的参数,
所以密码不会进配置文件,也不会进审计日志(审计日志记录每一条命令行)。

### common.py 多了一个函数

`extract_tar_gz`:release 是从网上下来的,一个 `../` 成员就能写到目标目录之外。
Python 3.12 的 `extractall(filter="data")` 能挡,但这些工具也要在更老的解释器上跑,
所以成员是自己逐个校验的,行为不取决于机器上装的是哪个 Python。
现有三份 `common.py` 没有这个函数,可以以后同步。

### Grafana 启动时不再自己更新插件

Grafana 会在启动时把自带插件就地更新,写的是 release 树里的
`<homepath>/data/plugins-bundled/`。这棵树在这里是 root 的:一个 release 必须原样等于下载下来的
东西,回滚才只是换个软链。于是更新写不进去、失败在半路,**而它已经先把要更新的插件注销了**
——provision 好的 Prometheus 数据源直接返回 `Plugin not registered`,整个 Grafana 没用。

`grafana.ini` 里设 `[plugins] preinstall_disabled = true` 关掉它。代价是插件版本跟着 release 走,
换插件版本就得换 release ——这恰好是这套工具的版本模型。附带的好处:启动不再需要联网拉插件。

### 装过的 release 不再重下

改监听地址、改 retention、改 Grafana 配置的方式都是重跑 install。Grafana 的包 450 MB,
为了重写一个配置文件再下一遍不值。所以 install 先看 `versions/` 里有没有这个版本、
跑起来报的版本对不对,对就直接复用。真机上重装 Grafana 从 5 分钟变成 7.7 秒。

### 卸载留下的数据要能被新用户接管

uninstall 删系统用户但留数据。下一次 install 重新建用户,**没有任何保证它能拿回同一个 uid**
——中间装过别的东西就可能被占走。那样留下来的 TSDB 就属于一个不存在的 uid,
Prometheus 起得来但写不进去。install 因此在建目录前比对一次 uid,不一致就 `chown -R` 接管。
真机上把旧 uid 占掉验证过:新用户拿到 984,数据被接管,卸载前一小时的时间序列照常可查。

## 验证

`tests/test_monitoring_manager.py`,62 条;仓库全部 Python 测试 283 条通过。

- 目标文件:写入形状、幂等、改标签、删到空保留 job、删不存在的报 1、一个条目里多个地址时只删一个、
  形状不对拒绝改写、地址/job 名校验、非 job 文件被忽略、配置写失败时不留下孤儿 job 文件。
- 生成的配置:每个目标文件一个 file_sd job、监听 0.0.0.0 时自抓换回环地址、promtool 拒绝时回滚、
  内容没变不重写也不重载、非本工具写的配置拒绝接管。
- 单元文件:flag 落进 ExecStart、`ProtectHome=read-only`、`ExecReload` 是 SIGHUP、retention 非法拒绝、
  Grafana 单元指向 `current` 而不是版本目录、老版本回落到 `grafana-server`、带空白的值一律拒绝。
- staged 自检:跑不起来硬失败、版本不符失败、读不出来只警告;盘上已有的 release 复用与不复用的判定。
- 版本:只认 release 号、升级不允许退回内置 pin(安装可以)、升级计划文案、降级要显式 flag、
  `--dry-run` 全程零特权调用。
- 安装流程(打桩到临时目录):配置/单元/元数据三者一致、重跑 install 不抹掉已有目标、
  两个组件的元数据互不覆盖、**服务用户在建目录之前创建**、Grafana 关掉插件更新器、
  provisioning 六个子目录都建出来。
- 目标健康:按「当初加的那个地址」匹配而不是 `instance` 标签、doctor 报出 down 的目标和它的错误、
  Prometheus 连不上时不算目标失败。
- 卸载:默认保留数据、`--purge` 把数据挪进删除清单、工具文件默认保留、
  组件卸完之后仍能单独删工具文件、计划承认审计日志会被重建、purge 不留空目录。
- 老布局检测、两种 checksum 文件、解压保权限位、解压拒绝 `../` 成员、保留数据的 uid 接管。

### 真机验证

Debian 13 / systemd 257 / Python 3.13 / amd64,GitHub release 直连只有 2.5 KB/s,全程走 HTTP 代理
(健康检查走的是 `no_proxy`,没有被代理影响,这点也一并验证了)。

| 项 | 结果 |
|---|---|
| node_exporter install 1.9.1 → 升级到 1.12.1 | 8 秒;两个 release 都留在盘上 |
| **失败回滚** | 用 drop-in 让新版本必然起不来 → 自动切回旧版本、服务恢复、记录版本不变、退出码 1 |
| prometheus install | promtool 通过;自动把本机 node_exporter 加成目标,两个 target 都 up |
| target add(已有 job) | **PID 不变,无重启无 reload** |
| target add(新 job) | 改写配置 + SIGHUP reload,PID 仍不变 |
| prometheus 升级/降级 | prometheus 与 promtool 两个二进制一起切;`--keep 1` 把旧的一对都清掉 |
| grafana install | 450 MB / 约 5 分钟;数据源 provision 后 `Successfully queried the Prometheus API` |
| grafana 重装 | 复用盘上 release,7.7 秒 |
| uninstall(默认) | 服务/用户/二进制/配置全删,**数据保留**;重装后卸载前一小时的数据照常可查 |
| uninstall `--purge` | 数据一并删除,只剩审计记录 |
| 老布局拦截 | 0.06 秒失败,下载都没开始 |
| 手改过的配置 | 拒绝覆盖,文件原样保留 |
| 审计日志 | 每条命令连退出码都记下,失败的升级记的是 exit=1 |

### 真机上抓到的 bug

本地测试全部把特权操作打了桩,所以下面这些在本地一个都红不了:

1. **建用户排在建目录之后** —— `install -d -o prometheus` 直接 `invalid user`,
   prometheus 和 grafana 的安装根本跑不完。
2. **目标健康按 `instance` 标签匹配** —— 加了 `--label instance=xxx` 的目标,
   doctor 和 target list 永远显示「还没被 Prometheus 抓到」。改成按 API 的
   `discoveredLabels.__address__` 匹配。
3. **Grafana 的启动插件更新器**(见上)—— provision 好的数据源完全不可用。
4. **provisioning 少四个子目录** —— Grafana 每次启动报四条 `level=error`。
5. 组件全卸完之后 `uninstall --remove-tools` 报「没有已安装组件」,工具文件只能手工删。
6. 保留数据的 uid 接管(见上)。

每个都补了回归测试;「建用户顺序」那条做过变异验证:把 bug 放回去,测试会红。

## 未覆盖风险

- **单机验证**。所有真机验证都在同一台 Debian 13 上做的:一台机器同时当采集端和监控端。
  跨机抓取只用「本机 0.0.0.0:9100 + 另一个地址」的方式验证过,没有真的在两台机器之间跑。
  RHEL 系、更老的 systemd、非 amd64 都没碰过。
- Grafana 的 tarball 约 450 MB,解压后占约 1.4 GB;`--keep 2` 意味着两份 release 就是 2.8 GB。
  小盘的机器要留意,工具本身不检查剩余空间。
- 关掉 `preinstall` 之后,Grafana 自带插件的安全更新要靠升级 Grafana 本身来拿。
- 版本发现走 GitHub 的 `releases/latest`,未认证时 60 次/小时/IP。安装时取不到会退回内置 pin
  并警告;升级时取不到直接失败。
- `download_file` 用的是 `curl --retry 3 --max-time 300`(这是三个 manager 共用的
  `common.py` 里原有的行为):链路卡住时最坏会安静地挂满 20 分钟才报错。真机上撞到过一次。
- 进程被 SIGKILL/SIGTERM 打断时,`/var/tmp` 下的临时目录不会清理(`finally` 不执行)。
  目录名带固定前缀,认得出来。
- node_exporter 默认监听所有网卡且无认证,这是这套用法的前提;工具不会替你配防火墙,
  只在 install 和每次 doctor 提醒。
- **没有预置 Grafana 仪表盘**。数据源配好了、数据也在采,但 Grafana 不自带任何面向这些指标的
  面板,首页是空的 —— 真实反馈就是「装完看不到机器信息」。现在 `grafana install` 装完会打印
  导入步骤(1860,Node Exporter Full),`quickstart` 和 `tutor grafana` 里也都写了,
  tutor 还说明了按 ID 导入是 Grafana 服务端去 grafana.com 拉、连不上时怎么办。
  但这仍然是每台机器的手工动作,把 JSON 随工具发出去并 provision 掉才是真正的解法,本次没做。
- 只覆盖单机单副本:没有 Alertmanager、没有 recording/alerting rules、没有 TLS 与 basic auth、
  没有远端存储。
- 从 `tools.old/grafana/install.sh` 装出来的老机器没有自动迁移:install 会拒绝并列出冲突路径,
  停服务、删旧文件、决定 `/var/lib/prometheus` 里的数据怎么办,都还是人工动作。
- `tools.old/grafana/` 原样保留,没有删除。
