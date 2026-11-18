#!/bin/sh
exec >/tmp/install.log 2>&1
ts=$(date +%Y%m%d-%H%M%S)
cp -p /usr/sbin/wifi-gate.sh /root/wifi-gate.sh.bak-$ts; cp -p /etc/init.d/wifi-gate-boot /root/wifi-gate-boot.bak-$ts; cp -p /etc/firewall.user /root/firewall.user.bak-$ts
sh -n /tmp/wifi-gate.sh && sh -n /tmp/wifi-gate-boot.init && sh -n /tmp/firewall.user.add || { echo "语法错误，放弃"; exit 1; }
cp /tmp/wifi-gate.sh /usr/sbin/wifi-gate.sh; cp /tmp/wifi-gate-boot.init /etc/init.d/wifi-gate-boot; chmod 755 /usr/sbin/wifi-gate.sh /etc/init.d/wifi-gate-boot
grep -q wifi-gate-hold /etc/firewall.user || cat /tmp/firewall.user.add >> /etc/firewall.user
echo "已安装 $(md5sum /usr/sbin/wifi-gate.sh | cut -c1-8) $(wc -l < /usr/sbin/wifi-gate.sh) 行; firewall.user 含 hold: $(grep -c wifi-gate-hold /etc/firewall.user)"
/etc/init.d/wifi-gate enable; /etc/init.d/wifi-gate-boot enable
echo "--- 重启门控服务（stop 会 force-on 并解除暂扣，start 载入新代码）"; /etc/init.d/wifi-gate stop; sleep 3; /etc/init.d/wifi-gate start; sleep 25
/usr/sbin/wifi-gate.sh status; logread | grep wifi-gate | tail -3 | cut -c1-110
for k in ra0 rai0 wlanmld2g wlanmld5g mld0; do printf "%s=%s " $k $(uci get wireless.$k.disabled); done; echo "mlo=$(uci get mlo.mld0.disabled)"
rm -f /tmp/switch-v5.sh /tmp/switch-v5.log /tmp/gate-test.log
echo "== install done $(date +%T)"
