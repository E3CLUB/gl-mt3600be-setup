# 简体中文完整菜单（菜单 10）

## 现象

管理页语言选「简体中文」时，左侧菜单比 English 少一截：VPN 整组、AdGuard Home、动态 DNS、Tor 都不见了。切回 English 它们又出现。这跟有没有做过菜单 1（固件地区代码）无关——地区改成 US 之后，中文界面照样缺。

## 原因

菜单不是写死在 JS 里的，而是一组普通 JSON：

```text
/usr/share/oui/menu.d/*.json
```

GL v4.9.0（MT3600BE）里有 7 个文件带着这样一段：

```json
"lang_hide": ["zh-cn"]
```

| 文件 | 菜单 |
|---|---|
| `vpndashboard.json` | VPN → VPN 面板 |
| `vpn-client.json` | VPN → VPN 客户端 |
| `ovpnserver.json` | VPN → OpenVPN 服务器 |
| `wgserver.json` | VPN → WireGuard 服务器 |
| `adguardhome.json` | 应用程序 → AdGuard Home |
| `dynamicdns.json` | 应用程序 → 动态 DNS |
| `torview.json` | 应用程序 → Tor |

前端 `app.*.js` 的菜单过滤函数里有两处用到它（节选，变量名是压缩后的）：

```js
// f = lang_hide，o = 当前语言，a = 地区代码
if (null != f && f.includes(o)) return !1;                       // ① 当前语言在名单里就隐藏
...
return !(a.toLowerCase().indexOf("cn") >= 0 && null != f && f.includes("zh-cn"))  // ② 地区是 CN 且名单含 zh-cn 也隐藏
```

所以把 `lang_hide` 里的 `"zh-cn"` 去掉，①不再命中，简体中文界面就能看到完整菜单。

**顺带的效果**：②也不再命中。也就是说，**即使没做菜单 1、地区代码仍是 CN**，这 7 个菜单在任何语言下也会显示出来。注意这只是**菜单可见性**，是读前端代码得出的结论：CN 地区下这些功能的后端是否完整可用、无线功率和频段限制是否解除，本项目**没有验证**，那些仍然是菜单 1 管的事。

Tailscale、ZeroTier 的菜单没有 `lang_hide`，本来就不受语言影响。`astrowarp.json` 用的是另一个字段（`country.exclude: ["cn"]`），本补丁不碰它。

## 执行

在**电脑本地**运行。先只读看一眼：

```sh
sh scripts/patch-zh-menu.sh status
```

确认列出来的就是想放开的菜单，再应用：

```sh
sh scripts/patch-zh-menu.sh apply
```

撤销：

```sh
sh scripts/patch-zh-menu.sh restore
```

`apply` 和 `restore` 之后**强制刷新浏览器缓存**（macOS `Command + Shift + R`）。刷新后还没变化就退出管理页重新登录一次。

## 脚本做了什么

1. 一次 SSH 把 `menu.d` 整个目录打包取回本地（不依赖 scp/sftp）。
2. 逐个解析 JSON，只挑出 `lang_hide` 数组里含 `"zh-cn"` 的文件——**不靠写死的文件名清单**，所以别的固件版本多几个少几个也能自动适应。
3. 文本层面只删掉数组里的 `"zh-cn"` 这一项，保留文件原有的缩进和其余内容；名单里若还有别的语言，原样保留。
4. 复核：补丁后必须仍是合法 JSON，且**除 `lang_hide` 少了 `zh-cn` 之外与原件完全等价**。不满足就整体拒绝，什么都不上传。
5. 一次 SSH 上传：首次修改前把原件存到路由器 `/root/gl-menu-zh-backup/<文件名>.original`，覆盖后回读 SHA256 与本地比对。

已经打过补丁再跑 `status` / `apply`，会报告「没有任何菜单对简体中文隐藏」并直接退出，不重复写入。

## 边界

- **风险低**：改的是 7 个几百字节的纯文本 JSON，不是压缩 JS。最坏情况是某个菜单项显示异常，`restore` 即可还原。
- **翻译**：VPN 客户端、OpenVPN 服务器、WireGuard 服务器这几个页面没有独立的简体中文语言包，页面内个别文字可能显示英文。前端在缺翻译时会回落到英文，不影响功能。
- **固件升级后失效**：`/usr/share/oui/menu.d` 不在保留清单里，升级固件会恢复原厂菜单，重新跑一次 `apply` 即可。**不要**把这些文件写进 `sysupgrade.conf`——新固件可能改了菜单结构，硬留旧文件会让菜单错位。
- 升级固件后如果要 `restore`，注意备份是旧固件的原件；此时更稳妥的做法是直接删掉路由器上的 `/root/gl-menu-zh-backup`，以新固件为准重新 `apply`。

## 依据

机制来自对 MT3600BE v4.9.0 官方固件镜像的直接解包（`/usr/share/oui/menu.d/` 与 `/www/js/app.*.js.gz`），不是社区教程转述。脚本的定位、替换、复核、还原全流程已对着该镜像里的真实菜单文件离线跑通。
