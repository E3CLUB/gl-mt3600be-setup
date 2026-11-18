#!/bin/sh
# wifi-gate v3：只有 Tailscale 出口节点真正可用时才开放主 Wi-Fi（MLO + 2.4G/5G 主 SSID）。
#   - 开机由 wifi-gate-boot(S19) 把 Wi-Fi 配置置为开（2.4G 射频必须在开机时初始化）并用防火墙暂扣 LAN 转发，消除启动空窗；
#     S82 本服务启动后：出口节点未就绪则关 Wi-Fi（暂扣保持），就绪后开 Wi-Fi 并解除暂扣；
#   - 本服务(S82)持续监测：连续 OK_LIMIT 次可用才开，连续 FAIL_LIMIT 次不可用才关；
#   - 出口节点一直连不上则 Wi-Fi 一直不开（只能用网线访问路由器）。
# 开关方式：调固件自带 /etc/gl-switch.d/wifi.sh（内部用 gl-session 的 set_config/set_mlo_config），与管理页一致，MLD 能被正确创建；
#   不用 uci+wifi reload：那样 MLO 不会真正启用，也不用整机 wifi down。
#   不用 set_mlo_config / wifi.sh；
#   不碰访客、IoT、中继。
# 用法： wifi-gate.sh run | status | check | preboot | force-on

INTERVAL=${INTERVAL:-20}            # 探测间隔（秒）
FAIL_LIMIT=${FAIL_LIMIT:-4}         # 连续失败几次才关（4 次 ≈ 80 秒）
OK_LIMIT=${OK_LIMIT:-2}             # 连续成功几次才开
RECLOSE_MIN=${RECLOSE_MIN:-300}     # “被手动打开后再次关闭”的最小间隔（秒）
RELOAD_WAIT=${RELOAD_WAIT:-45}      # 开关后等待生效（秒）
GRACE_AFTER_ON=${GRACE_AFTER_ON:-120}  # 开 Wi-Fi 后的宽限（秒）：reload 会触发 gl_tailscale 重启
PROBE1=https://www.gstatic.com/generate_204
PROBE2=https://cp.cloudflare.com/generate_204
STATE=/var/run/wifi-gate.state
MAIN_KEYS="wireless.ra0.disabled wireless.rai0.disabled wireless.wlanmld2g.disabled wireless.wlanmld5g.disabled wireless.mld0.disabled mlo.mld0.disabled"

log() { logger -t wifi-gate "$*"; }

# ---------- 探测 ----------
internet_ok() {   # 本机外网（不经隧道）是否通，仅供 status 显示
	for ip in $(uci -q get glconfig.general.track_ip) 223.5.5.5 119.29.29.29; do
		ping -c1 -W2 "$ip" >/dev/null 2>&1 && return 0
	done
	return 1
}

# 出口节点可用 = tailscaled Running + 出口节点在线 + table52 有默认路由 + 经 tailscale0 真能访问外网
exit_ok() {
	j=$(timeout 10 tailscale status --json 2>/dev/null) || return 1
	[ "$(echo "$j" | jsonfilter -e '@.BackendState' 2>/dev/null)" = "Running" ] || return 1
	[ "$(echo "$j" | jsonfilter -e '@.ExitNodeStatus.Online' 2>/dev/null)" = "true" ] || return 1
	ip route show table 52 2>/dev/null | grep -q '^default dev tailscale0' || return 1
	for u in $PROBE1 $PROBE2; do
		[ "$(curl -4 -s --interface tailscale0 --max-time 8 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)" = "204" ] && return 0
	done
	return 1
}

# ---------- Wi-Fi ----------
mld_ifaces() { uci -q get wireless.mld0.iface || echo "ra2 rai2"; }
tx_count() { iwpriv "$1" stat 2>/dev/null | grep "Tx success" | tr -dc 0-9; }

config_is_on() {   # 四个键全为 0 才算配置为开
	for k in $MAIN_KEYS; do [ "$(uci -q get "$k")" = "0" ] || return 1; done
	return 0
}

wifi_is_up() {   # 两个 MLO 链路的 hostapd 都处于 ENABLED 才算在广播（iwpriv 计数更新滞后，不可用于短窗口判断）
	for i in $(mld_ifaces); do
		[ -S "/var/run/hostapd/$i" ] || return 1
		hostapd_cli -i "$i" status 2>/dev/null | grep -q "^state=ENABLED" || return 1
	done
	return 0
}

wifi_set() {   # on | off ：走固件自带的开关路径（与拨动开关/管理页一致），MLD 由固件正确创建
	[ "$1" = on ] && e=true || e=false
	/etc/gl-switch.d/wifi.sh "$1" >/dev/null 2>&1   # 内部对 ra0/rai0 调 set_config、对 mld0 调 set_mlo_config
	sleep 5
	# 兜底：若固件脚本未把六个键写到位（拨动开关被改绑等），直接调同样的 ubus 接口
	if { [ "$1" = on ] && ! config_is_on; } || { [ "$1" = off ] && config_is_on; }; then
		log "wifi.sh $1 未生效，改为直接调用 gl-session 接口"
		ubus call gl-session call "{\"module\":\"wifi\",\"func\":\"set_mlo_config\",\"params\":{\"name\":\"mld0\",\"mlo_enable\":$e,\"init\":true}}" >/dev/null 2>&1
		for i in ra0 rai0; do ubus call gl-session call "{\"module\":\"wifi\",\"func\":\"set_config\",\"params\":{\"iface_name\":\"$i\",\"enabled\":$e,\"init\":true}}" >/dev/null 2>&1; done
		sleep 5
	fi
	echo "$1" > "$STATE"
	log "Wi-Fi 已设为 $1"
}

# ---------- LED ----------
# 等待出口节点期间：停掉固件 LED 守护（避免互相覆盖），蓝灯 0.5s 闪烁、白灯灭；开放后恢复固件默认（白灯常亮）。
BLUE=/sys/class/leds/blue:run; WHITE=/sys/class/leds/white:system
led_wait() {
	/etc/init.d/gl_led stop >/dev/null 2>&1
	[ "$(cat $BLUE/trigger 2>/dev/null | grep -o "\[timer\]")" = "[timer]" ] || { echo timer > $BLUE/trigger; echo 500 > $BLUE/delay_on; echo 500 > $BLUE/delay_off; } 2>/dev/null
	echo 0 > $WHITE/brightness 2>/dev/null
}
led_normal() {
	echo none > $BLUE/trigger 2>/dev/null; echo 0 > $BLUE/brightness 2>/dev/null
	/etc/init.d/gl_led start >/dev/null 2>&1
}

HOLD=/var/run/wifi-gate.hold
hold_rule() { "$1" FORWARD -i br-lan -m comment --comment wifi-gate-hold -j DROP 2>/dev/null; }
hold_on() {   # 暂扣：LAN 侧转发全部丢弃（开机到出口节点就绪之间的空窗），规则同时写在 /etc/firewall.user 里以挺过防火墙重载
	touch "$HOLD"
	for t in iptables ip6tables; do $t -C FORWARD -i br-lan -m comment --comment wifi-gate-hold -j DROP 2>/dev/null || $t -I FORWARD -i br-lan -m comment --comment wifi-gate-hold -j DROP 2>/dev/null; done
}
hold_off() {
	rm -f "$HOLD"
	for t in iptables ip6tables; do while $t -D FORWARD -i br-lan -m comment --comment wifi-gate-hold -j DROP 2>/dev/null; do :; done; done
}
preboot() {   # 开机早期（network 起来前）：Wi-Fi 配置必须为“开”，否则 2.4G 射频在本次开机内无法发射；空窗用防火墙暂扣堵住
	for k in $MAIN_KEYS; do uci -q set "$k=0"; done
	uci commit wireless; uci commit mlo
	hold_on
	echo off > "$STATE"
	log "开机预置：Wi-Fi 配置置为开（射频需完整初始化），LAN 转发暂扣，等待出口节点"
}

case "${1:-run}" in
check)
	if exit_ok; then echo "出口节点可用"; exit 0; else echo "出口节点不可用"; exit 1; fi ;;
status)
	echo "门控状态: $(cat $STATE 2>/dev/null || echo 未知)"
	echo "LAN 转发暂扣: $([ -f $HOLD ] && echo 是 || echo 否)（规则 $(iptables -S FORWARD | grep -c wifi-gate-hold) 条）"
	echo "主 Wi-Fi 配置: $(config_is_on && echo 开 || echo 关)（链路 $(mld_ifaces)）"
	echo "主 Wi-Fi 实际: $(wifi_is_up && echo 在广播 || echo 未广播)"
	echo "外网: $(internet_ok && echo 通 || echo 不通)"
	echo "出口节点: $(exit_ok && echo 可用 || echo 不可用)"
	echo "蓝灯: $(cat $BLUE/trigger 2>/dev/null | grep -o "\[[a-z_-]*\]")  gl_led 守护: $(ps w | grep -c "[/]usr/bin/gl_led")" ;;
preboot|preboot-off)
	preboot ;;
force-on)
	wifi_set on; hold_off; led_normal ;;
run)
	sleep 10
	fail=0; ok=0; last_close=0; grace_until=0
	if exit_ok && exit_ok; then
		cur=on
		if config_is_on && wifi_is_up; then
			echo on > "$STATE"; log "启动时出口节点已可用且 Wi-Fi 在广播，保持"
			hold_off
			led_normal
		else
			log "启动时出口节点已可用，开放 Wi-Fi"; wifi_set on
			hold_off
			led_normal
			grace_until=$(( $(date +%s) + RELOAD_WAIT + GRACE_AFTER_ON ))
		fi
	else
		cur=off
		if config_is_on; then log "启动时出口节点不可用，关闭 Wi-Fi"; wifi_set off
		else echo off > "$STATE"; log "启动时出口节点不可用，Wi-Fi 保持关闭"; fi
		led_wait
	fi
	while :; do
		if [ "$(date +%s)" -lt "$grace_until" ]; then sleep "$INTERVAL"; continue; fi
		if exit_ok; then
			ok=$((ok+1)); fail=0
			if [ "$cur" != on ] && [ "$ok" -ge "$OK_LIMIT" ]; then
				log "出口节点连续 $ok 次可用，开放 Wi-Fi"; wifi_set on; cur=on
				hold_off
				led_normal
				grace_until=$(( $(date +%s) + RELOAD_WAIT + GRACE_AFTER_ON ))
			fi
		else
			fail=$((fail+1)); ok=0
			if [ "$cur" != off ] && [ "$fail" -ge "$FAIL_LIMIT" ]; then
				log "出口节点连续 $fail 次不可用，关闭 Wi-Fi"; wifi_set off; cur=off; last_close=$(date +%s)
				led_wait
			fi
			# 出口节点不可用期间若配置被手动改为开（管理页），限频后再关
			if [ "$cur" = off ] && [ "$fail" -ge "$FAIL_LIMIT" ] && config_is_on \
				&& [ $(( $(date +%s) - last_close )) -ge "$RECLOSE_MIN" ]; then
				log "Wi-Fi 被手动打开但出口节点不可用，再次关闭"; wifi_set off; last_close=$(date +%s)
			fi
		fi
		[ "$cur" = off ] && led_wait
		sleep "$INTERVAL"
	done ;;
*)
	echo "用法: $0 run|status|check|preboot|force-on" >&2; exit 2 ;;
esac
