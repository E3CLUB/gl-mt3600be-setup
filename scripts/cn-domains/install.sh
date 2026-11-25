#!/bin/sh
# 国内域名清单自动更新：路由器端安装 / 卸载（菜单 15）
# 用法（在路由器上，先把 ts-cn-domains.sh 传到 /tmp/）：
#   sh /tmp/install.sh install [分钟 小时 星期]   默认每周一 04:30
#   sh /tmp/install.sh remove                     卸载：删定时、删脚本、删生成物并重启 dnsmasq
#   sh /tmp/install.sh status
# 可选：事先写好 /etc/ts-cn-domains.conf 覆盖默认参数（见 ts-cn-domains.sh 开头）。
set -u
ACT=${1:-status}
BIN=/usr/sbin/ts-cn-domains.sh
TAG="# mt3600be-setup cn-domains"
CN_IPSET=cn_direct_dns; DD=/etc/dnsmasq.d; CONF_NAME=cn-direct.conf; STATE_DIR=/etc/ts-cn-domains
[ -r /etc/ts-cn-domains.conf ] && . /etc/ts-cn-domains.conf

die() { echo "停止：$*"; exit 1; }

case "$ACT" in
install)
	MIN=${2:-30}; HOUR=${3:-4}; DOW=${4:-1}
	[ -s /tmp/ts-cn-domains.sh ] || die "/tmp/ts-cn-domains.sh 不存在，先上传"
	sh -n /tmp/ts-cn-domains.sh || die "脚本语法错误"
	mem=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
	[ "${mem:-0}" -ge 900000 ] || die "内存 ${mem} kB 不足 1 GB：11 万条域名会让 dnsmasq 占用约 40 MB，512 MB 机型曾因此 OOM"
	for c in curl flock ipset dnsmasq nslookup awk sort; do command -v $c >/dev/null || die "缺少命令 $c"; done
	dnsmasq -v 2>/dev/null | grep -q ' ipset' || die "dnsmasq 编译时未带 ipset 支持"
	ipset list -n 2>/dev/null | grep -qx "$CN_IPSET" ||
		die "ipset $CN_IPSET 不存在。本项只负责填充它，打标直连的分流要事先建好（或在 /etc/ts-cn-domains.conf 里把 CN_IPSET 改成你已有的集合）"
	mkdir -p "$DD" "$STATE_DIR"
	if ! grep -qE "^conf-dir=$DD/?(,|$)" /etc/dnsmasq.conf 2>/dev/null; then
		cp -p /etc/dnsmasq.conf "$STATE_DIR/dnsmasq.conf.orig" 2>/dev/null
		echo "conf-dir=$DD/,*.conf" >>/etc/dnsmasq.conf
		echo "已在 /etc/dnsmasq.conf 加 conf-dir=$DD/,*.conf（原件 $STATE_DIR/dnsmasq.conf.orig）"
	fi
	cp /tmp/ts-cn-domains.sh "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN"
	sed -i "/$TAG\$/d" /etc/crontabs/root 2>/dev/null
	echo "$MIN $HOUR * * $DOW $BIN update >/dev/null 2>&1 $TAG" >>/etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1
	for f in "$BIN" /etc/ts-cn-domains.conf "$STATE_DIR/"; do
		grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >>/etc/sysupgrade.conf
	done
	echo "已安装 $BIN，定时：$(grep -F "$TAG" /etc/crontabs/root)"
	echo "首次更新在后台运行（经出口节点下载 4 MB，可能要几分钟），结果看：logread | grep -E 'ts-cn-domains|ALERT'"
	start-stop-daemon -S -b -m -p /var/run/ts-cn-domains-first.pid -x /bin/sh -- "$BIN" update
	;;
remove)
	sed -i "/$TAG\$/d" /etc/crontabs/root 2>/dev/null; /etc/init.d/cron restart >/dev/null 2>&1
	rm -f "$BIN"
	[ -f "$DD/$CONF_NAME" ] && { mv "$DD/$CONF_NAME" "$STATE_DIR/$CONF_NAME.removed"; /etc/init.d/dnsmasq restart; }
	sed -i "\#^$BIN\$#d" /etc/sysupgrade.conf
	echo "已卸载。生成物移到 $STATE_DIR/$CONF_NAME.removed；/etc/dnsmasq.conf 的 conf-dir 行未删（原件在 $STATE_DIR/dnsmasq.conf.orig，如有）"
	;;
status)
	ls -la "$BIN" 2>/dev/null || echo "未安装"
	grep -F "$TAG" /etc/crontabs/root 2>/dev/null
	echo "清单域名数：$(grep -c '^server=/' "$DD/$CONF_NAME" 2>/dev/null || echo 0)"
	t=$(cat "$STATE_DIR/state.cn_domains_last_ok" 2>/dev/null); [ -n "$t" ] && echo "上次成功：$(date -d @"$t" '+%F %T' 2>/dev/null || echo "$t")"
	echo "ipset $CN_IPSET：$(ipset list "$CN_IPSET" -t 2>/dev/null | sed -n 's/^Number of entries: //p' || echo 不存在)"
	;;
*) echo "用法：$0 install [分钟 小时 星期] | remove | status" ;;
esac
