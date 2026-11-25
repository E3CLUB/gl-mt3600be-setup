#!/bin/sh
# ts-cn-domains：定期更新国内域名清单（dnsmasq 格式），让国内域名用国内解析器解析，
# 解析出的地址填进指定 ipset，供已有的"按 ipset 打标直连"分流使用。
# 来源 felixonmars/dnsmasq-china-list 的 accelerated-domains + apple，每个域名生成两行：
#   server=/域名/$CN_DNS
#   ipset=/域名/$CN_IPSET
# 用法：ts-cn-domains.sh update   下载、校验、替换、重启 dnsmasq、冒烟，失败恢复上一版
#       ts-cn-domains.sh check    只下载校验并报告差异，不替换
# 可选配置文件 /etc/ts-cn-domains.conf（shell 变量），可覆盖下面的默认值。
set -u
MODE=${1:-update}

CN_DNS=223.5.5.5                       # 国内解析器
CN_IPSET=cn_direct_dns                 # 解析结果填入的 ipset（须已存在）
DD=/etc/dnsmasq.d                      # dnsmasq 的 conf-dir
CONF_NAME=cn-direct.conf               # 生成物文件名
STATE_DIR=/etc/ts-cn-domains           # 上一版与成功时间戳
LOCK=/var/lock/ts-cn-domains-apply.lock  # 替换 dnsmasq 配置时持有的锁；与其他改 dnsmasq 的脚本共用同一把可避免撞车
ALERT_TAG=ts-cn-domains                # 失败告警的 syslog 标签
SMOKE_DOMAIN=www.taobao.com            # 替换后用来确认 dnsmasq 能解析的域名
MIN_ABS=50000                          # 域名数绝对下限
DL_TIMEOUT=600                         # 单个文件下载超时（秒）
RELAY_CMD=                             # 可选：一条输出两个源文件 tar.gz 的命令（例如经 SSH 让境外 VPS 代下载并压缩）；
                                       # 为空或失败时直接从 GitHub / jsDelivr 下载。拿到的文件照样逐行校验
RELAY_TIMEOUT=300                      # 中转命令超时（秒）
[ -r /etc/ts-cn-domains.conf ] && . /etc/ts-cn-domains.conf

CONF=$DD/$CONF_NAME
PREV=$STATE_DIR/$CONF_NAME.prev
STATE=$STATE_DIR/state.cn_domains_last_ok
TMP=/tmp/ts-cn-domains
SRC1=accelerated-domains.china.conf
SRC2=apple.china.conf
BASE1=https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master
BASE2=https://fastly.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master

log() { logger -t ts-cn-domains "$*"; if [ -t 1 ]; then echo "$*"; fi; }
alert() { logger -p daemon.warn -t "$ALERT_TAG" "ALERT 国内域名清单：$*"; if [ -t 1 ]; then echo "ALERT $*"; fi; }
fail() { alert "$*，沿用旧清单"; rm -rf "$TMP"; exit 1; }

fetch() { # $1=文件名
	for b in "$BASE1" "$BASE2"; do
		curl -fsSL --max-time "$DL_TIMEOUT" -o "$TMP/$1" "$b/$1" && [ -s "$TMP/$1" ] && return 0
	done
	return 1
}
dns_ok() {
	pidof dnsmasq >/dev/null || return 1
	nslookup "$SMOKE_DOMAIN" 127.0.0.1 2>/dev/null | sed -n '/^Name:/,$p' | grep -q Address
}

# 同时只允许一个实例（临时目录是共用的）
exec 8>/var/lock/ts-cn-domains.lock
flock -n 8 || { echo "已有实例在运行"; exit 0; }
mkdir -p "$STATE_DIR" || exit 1
rm -rf "$TMP"; mkdir -p "$TMP" || exit 1
relay() {
	[ -n "$RELAY_CMD" ] || return 1
	timeout "$RELAY_TIMEOUT" sh -c "$RELAY_CMD" >"$TMP/relay.tgz" 2>/dev/null || return 1
	gzip -t "$TMP/relay.tgz" 2>/dev/null || return 1
	tar -xzf "$TMP/relay.tgz" -C "$TMP" "$SRC1" "$SRC2" 2>/dev/null || return 1
	rm -f "$TMP/relay.tgz"
	[ -s "$TMP/$SRC1" ] && [ -s "$TMP/$SRC2" ]
}
if relay; then
	VIA=中转
else
	[ -n "$RELAY_CMD" ] && log "中转下载失败，改为直接下载"
	rm -f "$TMP/$SRC1" "$TMP/$SRC2" "$TMP/relay.tgz"
	fetch "$SRC1" || fail "下载 $SRC1 失败"
	fetch "$SRC2" || fail "下载 $SRC2 失败"
	VIA=直接下载
fi

# 非注释行必须全部是 server=/域名/114.114.114.114，否则整份作废
bad=$(cat "$TMP/$SRC1" "$TMP/$SRC2" | grep -v '^#' | grep -v '^[[:space:]]*$' | grep -vc '^server=/[^/][^/]*/114\.114\.114\.114$')
[ "$bad" = 0 ] || fail "源文件有 $bad 行格式不符"
cat "$TMP/$SRC1" "$TMP/$SRC2" | grep -v '^#' | sed -n 's#^server=/\([^/][^/]*\)/114\.114\.114\.114$#\1#p' |
	tr 'A-Z' 'a-z' | sort -u >"$TMP/domains"
bad=$(grep -vc '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' "$TMP/domains")
[ "$bad" = 0 ] || fail "有 $bad 个域名含非法字符"

n=$(grep -c . "$TMP/domains")
old=$(grep -c '^server=/' "$CONF" 2>/dev/null); old=${old:-0}
min=$((old * 9 / 10)); [ "$min" -lt "$MIN_ABS" ] && min=$MIN_ABS
[ "$n" -ge "$min" ] || fail "新清单只有 $n 个域名，低于下限 $min"

sed -n 's#^server=/\([^/]*\)/.*#\1#p' "$CONF" 2>/dev/null | sort -u >"$TMP/old.domains"
set -- $(awk 'NR==FNR {o[$0]=1; next} {if ($0 in o) delete o[$0]; else a++} END {d=0; for (k in o) d++; print a+0, d}' "$TMP/old.domains" "$TMP/domains")
add=${1:-0}; del=${2:-0}

ESC_DNS=$(echo "$CN_DNS" | sed 's/[.]/\\./g')
{
	echo "# cn_direct：生成于 $(date '+%Y-%m-%d %H:%M:%S')，来源 felixonmars accelerated-domains + apple，每域名两行（ts-cn-domains.sh）"
	awk -v dns="$CN_DNS" -v set="$CN_IPSET" '{print "server=/" $0 "/" dns; print "ipset=/" $0 "/" set}' "$TMP/domains"
} >"$TMP/$CONF_NAME"
bad=$(grep -vcE "^(#.*|server=/[a-z0-9.-]+/$ESC_DNS|ipset=/[a-z0-9.-]+/$CN_IPSET)\$" "$TMP/$CONF_NAME")
[ "$bad" = 0 ] || fail "生成物有 $bad 行格式不符"
dnsmasq --test --conf-file="$TMP/$CONF_NAME" 2>&1 | grep -q 'syntax check OK' || fail "dnsmasq 语法检查未通过"

if [ "$MODE" = check ]; then
	echo "校验通过（$VIA）：新 $n 个域名，旧 $old 个，新增 $add，删除 $del（未替换）"
	rm -rf "$TMP"; exit 0
fi

if [ "$add" = 0 ] && [ "$del" = 0 ]; then
	date +%s >"$STATE"
	log "域名清单无变化（$n 个，$VIA），不重启 dnsmasq"
	rm -rf "$TMP"; exit 0
fi

(
	flock -x 9
	cp -p "$CONF" "$PREV" 2>/dev/null
	# 临时文件放在同一目录保证 mv 原子；不以 .conf 结尾，dnsmasq 不会读到半成品
	cp "$TMP/$CONF_NAME" "$DD/.cn-direct.tmp" && chmod 644 "$DD/.cn-direct.tmp" && mv "$DD/.cn-direct.tmp" "$CONF" || exit 2
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 5
	dns_ok && exit 0
	if [ -s "$PREV" ]; then cp -p "$PREV" "$CONF"; else rm -f "$CONF"; fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 5
	exit 1
) 9>"$LOCK"
r=$?
rm -rf "$TMP"
case $r in
0) date +%s >"$STATE"; log "域名清单已更新：$n 个（新增 $add，删除 $del，$VIA）" ;;
2) alert "写入失败，未改动"; exit 1 ;;
*) alert "替换后 dnsmasq 不正常，已恢复上一版"; exit 1 ;;
esac
exit 0
