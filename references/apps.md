# Tailscale 与 AdGuard Home 升级到官方最新版（菜单 11 / 12）

GL 固件自带这两个程序，但版本跟着固件走，往往落后官方很多。两项用的是同一套工具：

- `scripts/manage-app-update.sh`：在**电脑本地**运行的入口。
- `scripts/gl-app-update.sh`：**路由器侧**脚本，由上面那个脚本送到路由器 `/usr/bin/gl-app-update` 后执行。**不要在本地直接跑它。**

## 共同的安全设计

| 环节 | 做法 |
|---|---|
| 下载源 | 只用官方源：`pkgs.tailscale.com`、`static.adguard.com`。不经第三方镜像或社区脚本 |
| 完整性 | 强制 SHA256 校验，校验值取自官方；不一致直接放弃 |
| 试运行 | 新二进制先在暂存目录里跑一次 `--version`，确认架构对、版本对，才动系统文件 |
| 自动回退 | 替换后服务起不来或版本不对，自动换回 `/rom` 里的固件原版 |
| 只升不降 | 已装版本高于官方稳定版时不动 |
| 互斥 | 同一时间只允许一个实例运行（`/tmp/gl-app-update.lock`） |
| 日志 | `/root/gl-app-update.log`，自动裁剪到最近约 300 行 |

**前提**：路由器自己要能访问上面两个官方域名。访问不了时 `status` 会显示「查询失败」，`install` 会在下载阶段报错退出，不会改动系统。

先看状态（只读，脚本只临时放进路由器内存盘，跑完即删）：

```sh
sh scripts/manage-app-update.sh tailscale status
sh scripts/manage-app-update.sh adguardhome status
```

---

## 菜单 11：完整安装 Tailscale 最新版 + 每天 04:00 自动升级

### 「完整」指什么

固件自带的是**合并精简版**：只有一个 `/usr/sbin/tailscaled`，`tailscale` 是指向它的软链接（v4.9.0 自带 1.92.5）。本项装的是官方发布的**两个独立二进制** `tailscale` + `tailscaled`，功能完整。

代价是体积：两个文件合计约 65–70 MB，写在 `/overlay`。MT3600BE 是 512 MB NAND，空间充裕；脚本要求 `/overlay` 至少剩 90 MB、`/tmp` 至少剩 60 MB，不够就拒绝。**小闪存机型（16/32 MB）不要用这一项。**

### 安装

```sh
sh scripts/manage-app-update.sh tailscale install
```

流程：查官方最新版本号 → 下载 `tailscale_<版本>_arm64.tgz` 和 `.sha256` → 校验 → 解压到 `/overlay` 上的暂存目录 → 试运行 → 停服务 → 替换 `/usr/sbin/tailscale{,d}` → 用固件自己的 `/usr/bin/gl_tailscale restart` 拉起 → 健康检查（版本号 + 管理页开关开着时确认 `tailscaled` 在跑、能返回状态）。

- **不改** `/usr/bin/gl_tailscale`、`/etc/config/tailscale`、`/etc/tailscale/`（登录状态）。管理页里的 Tailscale 开关、登录、子网路由设置照常使用。
- 管理页里 Tailscale 没开启时，只替换二进制、不启动服务。
- 安装期间 Tailscale 会断开几十秒。**如果你正是通过 Tailscale 连进路由器的，SSH 会断**——请在局域网内操作。

### 每天 04:00 自动升级

```sh
sh scripts/manage-app-update.sh tailscale cron-on
```

默认 04:00（凌晨 4 点）。要换时间就带上小时和分钟：

```sh
sh scripts/manage-app-update.sh tailscale cron-on 4 30
```

它会在 `/etc/crontabs/root` 里写入一行（行尾带 `# mt3600be-setup` 标记），并把 `/usr/bin/gl-app-update` 加进 `/etc/sysupgrade.conf`：

```text
0 4 * * * /usr/bin/gl-app-update tailscale run >/dev/null 2>&1 # mt3600be-setup
```

`run` 每天只做一次版本查询，没有新版就直接退出，不下载、不重启服务。

**时区**：cron 按路由器的系统时区计算。时区没设对（默认常是 UTC）的话，「04:00」会落在别的时刻。`status` 会打印路由器当前时间，对不上就先按 [system.md](system.md) 菜单 9 把时区改好。

取消定时：

```sh
sh scripts/manage-app-update.sh tailscale cron-off
```

### 开启定时升级前要告诉用户的事

- **无人值守升级有风险。** 社区里最常用的 GL Tailscale 更新脚本明确建议不要放进 cron。本项目的做法是加了校验、试运行和自动回退来兜底，但兜不住的情况仍然存在：比如新版本本身能正常启动、却与当前固件的防火墙规则或 `gl_tailscale` 的启动参数不兼容。
- 如果这台路由器是**异地唯一的远程入口**，自动升级翻车就意味着要人到现场。这种场景建议不开定时，改成有人在场时手动 `install`。
- 升级瞬间（凌晨 4 点）经过它的 Tailscale 连接会断开几十秒。
- 每次是否升级、结果如何，都记在 `/root/gl-app-update.log`。

### 恢复固件自带版本

```sh
sh scripts/manage-app-update.sh tailscale restore
```

从 `/rom` 拷回原版并重启服务，登录状态和配置不动。**记得同时 `cron-off`**，否则第二天凌晨又升上去了。

### 固件升级后

保留配置升级固件：`/usr/sbin/tailscale{,d}` 会被新固件的版本覆盖，但更新脚本和定时任务都还在，**当晚 04:00 会自动再升回最新版**。没开定时的话手动 `install` 一次。

恢复出厂：脚本、定时任务、日志全部清空，需要重新来过。

---

## 菜单 12：安装 AdGuard Home 最新版

固件自带 AdGuard Home（`/usr/bin/AdGuardHome`），本项把它换成官方最新稳定版。固件的启动脚本 `/etc/init.d/adguardhome` 用到的 `--glinet` 等参数官方版都支持，**启动脚本不需要改**。

> 简体中文界面下 AdGuard Home 的菜单默认是隐藏的，先做菜单 10 才能在管理页里看到它的开关。

### 安装

```sh
sh scripts/manage-app-update.sh adguardhome install
```

流程：读官方 `version.json` → 下载 `AdGuardHome_linux_arm64.tar.gz` 和 `checksums.txt` → 校验 → 试运行 → **备份配置** → 停服务 → 替换二进制 → 启动 → 健康检查（版本号 + 管理页开关开着时确认进程持续存活）。

要求 `/overlay` 至少剩 60 MB。

- 管理页里 AdGuard Home 没开启时，只替换二进制、不启动。启用仍然在管理页 **应用程序 → AdGuard Home** 里点开关。
- AdGuard Home 开着的话，安装期间全网 DNS 会中断十几秒。
- 默认**不设定时升级**（用户只要求安装）。确实想要的话同样支持 `cron-on`，但 DNS 是全网依赖，更不建议无人值守。

### 配置备份（为什么必须有）

新版 AdGuard Home 启动时会**就地迁移** `config.yaml` 的格式，迁移后旧版读不了。所以脚本每次升级前都会备份：

```text
/root/adguardhome-backup/config.yaml.stock            第一次升级前的配置，永久保留
/root/adguardhome-backup/config.yaml.<时间戳>          每次升级前的配置，保留最近 5 份
```

升级失败自动回退时，会把**二进制和本次升级前的配置一起**换回去。

这些备份里有管理员密码哈希和你的规则设置，目录权限是 700。**不要**拷进仓库或贴到聊天里。

### 恢复固件自带版本

```sh
sh scripts/manage-app-update.sh adguardhome restore
```

换回 `/rom` 里的原版，同时把配置换回 `config.yaml.stock`（当前配置另存为 `config.yaml.before-restore`）。**这意味着第一次升级之后在 AdGuard Home 里做的设置改动会丢**，需要的话从 `before-restore` 里手动找回。

### 内存提醒

MT3600BE 只有 512 MB 内存，规则加载得多容易被 OOM killer 干掉，症状是 AdGuard Home 自己停了。先做菜单 8（zram-swap），并且不要一次订阅几十万条规则。另外该机型的过滤规则存放在一个 10 MB 的镜像文件里（启动脚本里的 `mount_filter_img 5M 2`），规则太多会写满。

---

## 排错

```sh
tail -n 50 /root/gl-app-update.log
logread | grep -iE "tailscale|adguard" | tail -n 30
```

| 现象 | 处理 |
|---|---|
| 「已有另一个 gl-app-update 在运行」 | 先 `ps w \| grep '[g]l-app-update'` 确认没有残留进程，再 `rm -rf /tmp/gl-app-update.lock` |
| 「无法访问 pkgs.tailscale.com / static.adguard.com」 | 路由器自己的出站网络或 DNS 有问题，先在路由器上 `curl -I` 对应地址排查 |
| 「SHA256 不一致」 | 下载被截断或被劫持。重试一次；反复出现就不要继续，检查网络环境 |
| 「/overlay 剩余 … 不足」 | `df -h /overlay` 看占用，清理不用的插件后再试 |
| 「升级失败，已恢复固件原版」 | 系统已回到可用状态。看日志里失败前最后几行，不要急着 `reinstall` |

## 依据

- 固件侧的路径和启动方式（`/usr/sbin/tailscaled` 及软链接、`/usr/bin/gl_tailscale restart`、`tailscale.settings.enabled`、`/usr/bin/AdGuardHome --glinet …`、`adguardhome.config.enabled`）来自对 MT3600BE v4.9.0 官方固件镜像的直接解包。
- 「替换二进制 + 从 `/rom` 恢复」的思路参考了 Admonstrator 的 [glinet-tailscale-updater](https://github.com/Admonstrator/glinet-tailscale-updater) 与 [glinet-adguard-updater](https://github.com/Admonstrator/glinet-adguard-updater)。本项目没有调用这两个脚本：它们默认装的是作者自行构建的精简版，且明确不建议用于 cron；这里改为直接取官方完整版，并补上了 SHA256 校验、试运行和失败自动回退。
- **实机验证情况**：下载地址、索引格式、校验文件格式已对官方服务器实测；版本比较、参数解析在本地跑过。**替换二进制、重启服务、自动回退这几步尚未在真机上跑过**，第一次使用请在局域网内、有人在场时执行，并先做菜单 3 的配置备份。
