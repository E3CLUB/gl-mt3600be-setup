# Wi-Fi 门控：Tailscale 出口节点连通后才开放 Wi-Fi（菜单 14）

在 GL-MT3600BE / 固件 4.9.0 上实测通过（2026-11-18）。前提：Tailscale 已启用并配置了出口节点（`tailscale.settings.exit_node_ip`）。

## 行为

- 开机：S19 先把主 Wi-Fi 配置置为**开**并用防火墙暂扣 LAN 转发；S82 门控启动后，出口节点未就绪则关闭 Wi-Fi（蓝灯闪、白灯灭），就绪后用固件接口开放 Wi-Fi、解除暂扣、恢复默认灯光。通电到 Wi-Fi 可用约 4–5 分钟。
- 运行中：每 20 秒探测一次；连续 4 次不可用（≈80 秒）关 Wi-Fi，连续 2 次可用再开；开 Wi-Fi 后 3 分钟宽限期不判定。
- 出口节点一直连不上则 Wi-Fi 一直不开，只能用网线访问路由器。
- "出口节点可用" = `tailscale status --json` 的 `BackendState=Running` 且 `ExitNodeStatus.Online=true`，且 `ip route show table 52` 有 `default dev tailscale0`，且经 `tailscale0` 能取到 `generate_204`。
- 开关的是主 Wi-Fi 的六个键：`wireless.{ra0,rai0,wlanmld2g,wlanmld5g,mld0}.disabled` 和 `mlo.mld0.disabled`，即 MLO 与 2.4G/5G 主 SSID 一起开关；访客、IoT、中继不碰。

## 部署

```sh
cd scripts/wifi-gate
for f in wifi-gate.sh wifi-gate-boot.init firewall.user.add install.sh; do ssh root@192.168.8.1 "cat > /tmp/$f" < $f; done
ssh root@192.168.8.1 "cat > /etc/init.d/wifi-gate; chmod 755 /etc/init.d/wifi-gate" < wifi-gate.init
ssh root@192.168.8.1 'start-stop-daemon -S -b -m -p /var/run/inst.pid -x /bin/sh -- /tmp/install.sh'
```

约 1 分钟后 `ssh root@192.168.8.1 'cat /tmp/install.log; /usr/sbin/wifi-gate.sh status'`。`install.sh` 会把 `firewall.user.add` 追加到 `/etc/firewall.user`（幂等），启用 `wifi-gate` 与 `wifi-gate-boot`，并重启门控服务。之后请机主重启一次，`logread | grep wifi-gate` 核对开机顺序。

停用：`/etc/init.d/wifi-gate stop`（自动恢复 Wi-Fi、解除暂扣、恢复灯光）；`disable` 后开机不再门控。卸载再删三个文件和 `/etc/firewall.user` 里 `wifi-gate-hold` 那段。固件升级后需重新部署。

## 踩过的坑（都是实测结论，不要改回去）

1. **开机时 Wi-Fi 配置必须为开。** 若开机时 2.4G 的所有 BSS 都是关闭的，2.4G 射频在该次开机内永远不发射（`iwpriv ra2 stat` 的 `Tx success` 恒为 0，手机搜不到），之后 `wifi reload`/`wifi restart`/`wifi down;wifi up` 都救不回来，只能重启。所以 S19 预置是"置为开 + 防火墙暂扣"，而不是"置为关"。
2. **2.4G 射频要有主 BSS `ra0` 启用才发射。** 只开 MLO 子接口（`ra2`）而 `ra0` 关闭时 2.4G 同样静默。因此 `ra0`/`rai0` 随 MLO 一起开关，代价是多出 `GL-MT3600BE-xxx` 与 `-5G` 两个 SSID；对功耗没有可感知影响。
3. **开关 MLO 要走固件接口。** 直接改 uci 再 `wifi reload` 不会让固件真正启用 MLD（管理页仍显示 MLO 关闭、设备不是多链路）。门控调用 `/etc/gl-switch.d/wifi.sh on|off`（内部是 `gl-session` 的 `set_config`/`set_mlo_config`），和管理页、拨动开关同一条路径；若它未把六个键写到位则直接调同样的 ubus 接口兜底。
4. **判断"是否在广播"用 hostapd 状态**（`/var/run/hostapd/ra2`、`rai2` 存在且 `hostapd_cli status` 为 `ENABLED`）。`operstate` 在射频静默时仍显示 up；`iwpriv … stat` 的计数更新滞后，短窗口不可用。
5. **灯光**：等待期先 `/etc/init.d/gl_led stop`（固件灯光守护每 2 秒刷一次灯，不停会互相覆盖），再给 `blue:run` 设 `timer` 触发器；开放后恢复 `none` 并 `gl_led start`。
6. **`wifi reload` 会触发固件 hotplug 重启 `gl_tailscale`**，出口节点短暂不可用；因此开 Wi-Fi 后给宽限期，`FAIL_LIMIT` 取 4，避免"开→重启→判失败→关"振荡。
7. **经这台路由器 Wi-Fi 连接的电脑**，在无线重配置后新的 SSH 会话常常几秒内中断（HTTP 不受影响，与 dropbear、防火墙无关，重新关联 Wi-Fi 后短暂恢复）。部署和测试请走网线，或把动作放进路由器侧脱离会话的脚本（`start-stop-daemon -S -b -m -p <pid> -x /bin/sh -- <脚本>`；路由器没有 `nohup`/`setsid`）。
8. **模拟掉线**用 `iptables -I OUTPUT -o tailscale0 -j DROP`（测完 `-D` 删除），不要动 tailscale 配置。
