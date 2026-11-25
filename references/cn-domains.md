# 国内域名清单自动更新（菜单 15）

在 GL-MT3600BE / 固件 4.9.0 上实测通过（2026-11-26）。

## 这项做什么

国内网站的 CDN 节点不一定落在国内 IP 段清单里。按域名补一层：国内域名交给国内解析器解析，解析出的地址实时填进一个 ipset，分流规则再按这个 ipset 走直连。

本项**只负责维护域名清单**：每周从 [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list) 下载 `accelerated-domains.china.conf` 与 `apple.china.conf`（约 11 万个域名），生成 `/etc/dnsmasq.d/cn-direct.conf`，每个域名两行：

```
server=/qq.com/223.5.5.5
ipset=/qq.com/cn_direct_dns
```

## 前提（安装脚本逐项检查，不满足就停）

| 条件 | 原因 |
|---|---|
| 内存 ≥ 1 GB | dnsmasq 载入 11 万条域名后约占 40 MB；512 MB 机型实测会 OOM |
| ipset 已存在（默认 `cn_direct_dns`） | 本项只填充它。**打标直连的分流规则要事先建好**，例如 `mangle` 里 `-m set --match-set cn_direct_dns dst -j MARK --set-mark 0x162` 加 `ip rule fwmark 0x162 lookup main`。没有这层规则，清单只改变解析器，不改变出口 |
| dnsmasq 带 ipset 支持 | GL 4.x 固件自带的 dnsmasq-full 满足 |
| `curl`、`flock` 可用 | 固件自带 |

建议的 ipset：`ipset create cn_direct_dns hash:ip family inet timeout 86400`。带 timeout 是为了让 CDN 换掉的旧地址一天内自然退出。dnsmasq 只在向上游取回答案时才写入集合，命中缓存不刷新计时。

## 安装

在电脑本地执行：

```sh
cd scripts/cn-domains
for f in ts-cn-domains.sh install.sh; do ssh root@192.168.8.1 "cat > /tmp/$f" < $f; done
# 可选：ipset 名、解析器、告警标签等要改的话，先放配置文件
# ssh root@192.168.8.1 'cat > /etc/ts-cn-domains.conf' < ts-cn-domains.conf.example
ssh root@192.168.8.1 'sh /tmp/install.sh install'          # 默认每周一 04:30
# ssh root@192.168.8.1 'sh /tmp/install.sh install 0 5 0'  # 改成每周日 05:00
```

安装脚本会：

1. 检查上面的前提；
2. `/etc/dnsmasq.conf` 里没有 `conf-dir=/etc/dnsmasq.d` 时补一行（原件存 `/etc/ts-cn-domains/dnsmasq.conf.orig`）；
3. 装 `/usr/sbin/ts-cn-domains.sh`，在 `/etc/crontabs/root` 加一行带 `# mt3600be-setup cn-domains` 标记的定时；
4. 把脚本、配置文件、状态目录登记进 `/etc/sysupgrade.conf`；
5. 后台跑第一次更新。

查看：`ssh root@192.168.8.1 'sh /tmp/install.sh status'`；卸载：`sh /tmp/install.sh remove`。

## 经境外 VPS 中转下载（推荐，有 VPS 时）

路由器自身流量走出口节点时，直接下载 GitHub 原始文件实测只有约 40 KB/s，4 MB 要几分钟。让 VPS 下载并压缩成 tar.gz 再经 SSH 拉回，实测压缩后约 520 KB，整次更新 26 秒。

**VPS 端**：给路由器一把专用密钥，在 `authorized_keys` 里用 `command=` 把它固定到一个受限脚本，脚本里加一个不接受任何参数、网址写死的分支：

```
command="/usr/local/sbin/vps-claw",restrict,from="100.64.0.0/10" ssh-ed25519 AAAA… 路由器专用
```

```sh
case "${SSH_ORIGINAL_COMMAND:-}" in
cnlist)
	d=$(mktemp -d) || exit 2
	for f in accelerated-domains.china.conf apple.china.conf; do
		curl -fsSL --max-time 120 -o "$d/$f" "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/$f" ||
			curl -fsSL --max-time 120 -o "$d/$f" "https://fastly.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/$f" ||
			{ rm -rf "$d"; exit 2; }
	done
	tar -C "$d" -czf - accelerated-domains.china.conf apple.china.conf; rc=$?; rm -rf "$d"; exit $rc ;;
*) echo denied; exit 1 ;;
esac
```

**路由器端**：在 `/etc/ts-cn-domains.conf` 里设

```sh
RELAY_CMD="ssh -i /path/to/专用私钥 -y root@<VPS 的 tailnet 地址> cnlist"
```

中转拿到的文件和直接下载的一样逐行校验，所以即使 VPS 被动了手脚，也只能让本次更新失败，不能把非国内格式的内容写进 dnsmasq。中转失败（超时、gzip 损坏、缺文件）会记一条日志并自动改为直接下载。

## 每次更新的流程

1. 单实例锁，避免两次运行共用临时目录互相干扰。
2. 下载：设了 `RELAY_CMD` 先走中转（超时 `RELAY_TIMEOUT`，默认 300 秒）；失败或未设时直接下载，先 `raw.githubusercontent.com`，失败换 `fastly.jsdelivr.net`，单文件超时 600 秒。
3. 校验，任一不过就整份作废、继续用旧清单并告警：
   - 非注释行必须全是 `server=/域名/114.114.114.114`；
   - 域名只含小写字母、数字、点和横线；
   - 域名数不低于上一版的 90%，且不低于 5 万；
   - 生成物逐行格式校验 + `dnsmasq --test`。
4. 与现有清单相同：只记成功时间，**不重启 dnsmasq**。
5. 有变化：持锁、旧版存 `/etc/ts-cn-domains/cn-direct.conf.prev`、同目录原子替换、重启 dnsmasq、解析冒烟域名；冒烟失败恢复上一版再重启。
6. 成功写 `/etc/ts-cn-domains/state.cn_domains_last_ok`（Unix 时间戳），可接入自己的看门狗做超期告警；失败以 `daemon.warn` 级别、`ALERT 国内域名清单：…` 记日志。

## 配置项（`/etc/ts-cn-domains.conf`，只写要改的）

| 变量 | 默认 | 说明 |
|---|---|---|
| `CN_DNS` | `223.5.5.5` | 国内解析器 |
| `CN_IPSET` | `cn_direct_dns` | 解析结果填入的 ipset |
| `DD` | `/etc/dnsmasq.d` | dnsmasq 的 conf-dir |
| `CONF_NAME` | `cn-direct.conf` | 生成物文件名 |
| `STATE_DIR` | `/etc/ts-cn-domains` | 上一版与成功时间戳 |
| `LOCK` | `/var/lock/ts-cn-domains-apply.lock` | 替换时持有；与其他改 dnsmasq 配置的脚本共用同一把锁可避免同时重启 |
| `ALERT_TAG` | `ts-cn-domains` | 告警的 syslog 标签，可改成你的告警转发程序在盯的标签 |
| `SMOKE_DOMAIN` | `www.taobao.com` | 替换后用来确认 dnsmasq 正常的域名 |
| `DL_TIMEOUT` | `600` | 单文件下载超时（秒） |
| `RELAY_CMD` | 空 | 输出两个源文件 tar.gz 的命令，见上文"经境外 VPS 中转下载" |
| `RELAY_TIMEOUT` | `300` | 中转命令超时（秒） |

## 踩过的坑

1. **经出口节点下载很慢。** 路由器自身的流量也走出口节点时，GitHub 原始文件实测只有约 40 KB/s，4 MB 要两三分钟。超时原先设 120 秒，下载到 3.5 MB 被切断，所以改成 600 秒。有境外 VPS 时用中转，见上文。
2. **不要在 SSH 前台跑长任务后被客户端超时切断。** 远端进程不会跟着退出，第二次运行会和它共用临时目录，一个失败时 `rm -rf` 掉另一个正在写的文件（`curl: (23) Failure writing output`）。脚本已加单实例锁；手动试跑请用 `start-stop-daemon -S -b -m -p … -x /bin/sh -- 脚本` 放后台。
3. **busybox 没有 `comm`**，增删数用 awk 算。
4. **非终端下 `[ -t 1 ] && echo` 会让函数返回假**，若它是脚本最后一条命令，成功时退出码也是 1，定时任务会误判。日志函数改用 `if`，脚本末尾显式 `exit 0`。
5. **清单无变化时不要重启 dnsmasq**：重启会清空 DNS 缓存，全屋有几秒解析中断。

## 回滚

```sh
cp -p /etc/ts-cn-domains/cn-direct.conf.prev /etc/dnsmasq.d/cn-direct.conf && /etc/init.d/dnsmasq restart
```
