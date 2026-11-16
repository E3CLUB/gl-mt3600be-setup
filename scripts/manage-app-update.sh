#!/bin/sh
#
# 在电脑本地运行：把路由器上固件自带的 Tailscale / AdGuard Home 换成官方最新版，
# 并可设置每天定时自动升级。真正干活的是路由器侧的 gl-app-update.sh，
# 本脚本只负责把它送上去并调用。

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib-ssh.sh"

router_script="$script_dir/gl-app-update.sh"
remote_path="/usr/bin/gl-app-update"

usage() {
    cat <<'EOF'
用法：
  manage-app-update.sh <tailscale|adguardhome> status            只读：版本、定时任务、剩余空间
  manage-app-update.sh <tailscale|adguardhome> install           安装官方最新版（已是最新则跳过）
  manage-app-update.sh <tailscale|adguardhome> reinstall         同版本也重装
  manage-app-update.sh <tailscale|adguardhome> restore           恢复固件自带版本
  manage-app-update.sh <tailscale|adguardhome> cron-on [HH] [MM] 每天定时自动升级，默认 04:00
  manage-app-update.sh <tailscale|adguardhome> cron-off          取消定时升级

环境变量：
  MT3600BE_TARGET   默认 root@192.168.8.1
  MT3600BE_SSH_KEY  私钥路径；留空则用密码或 ssh-agent
EOF
}

case "${1:-}" in
    -h|--help|help|'') usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
    usage >&2
    exit 2
fi

app="$1"
action="$2"
hh="${3:-4}"
mm="${4:-0}"

case "$app" in
    tailscale|adguardhome) ;;
    *) usage >&2; exit 2 ;;
esac

case "$action" in
    status|install|reinstall|restore|cron-on|cron-off) ;;
    *) usage >&2; exit 2 ;;
esac

if [ "$action" = "cron-on" ]; then
    case "$hh$mm" in
        *[!0-9]*) echo "错误：小时和分钟必须是整数。" >&2; exit 2 ;;
    esac
    if [ "${hh#0}" -gt 23 ] 2>/dev/null || [ "${mm#0}" -gt 59 ] 2>/dev/null; then
        echo "错误：时间超出范围（小时 0-23，分钟 0-59）。" >&2
        exit 2
    fi
fi

[ -r "$router_script" ] || { echo "错误：找不到 $router_script" >&2; exit 1; }
sh -n "$router_script" || { echo "错误：$router_script 语法检查未通过。" >&2; exit 1; }

local_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# 把路由器侧脚本部署到 /usr/bin/gl-app-update，并回读哈希
deploy() {
    expected="$(local_sha256 "$router_script")"
    actual="$(rt_ssh "set -eu
        cat > '$remote_path.new'
        sh -n '$remote_path.new'
        chmod 755 '$remote_path.new'
        mv -f '$remote_path.new' '$remote_path'
        sha256sum '$remote_path' | awk '{print \$1}'" < "$router_script")"
    if [ "$expected" != "$actual" ]; then
        echo "错误：部署后哈希不一致（本地 $expected / 远端 ${actual:-无}）。" >&2
        exit 1
    fi
}

# 不部署到 /usr/bin：脚本只临时放进路由器内存盘 /tmp，跑完即删。
# （不用 sh -s 直接喂标准输入，是怕被调用的服务脚本把后半段脚本当输入吃掉。）
run_inline() {
    rt_ssh "set -u
        t=\"/tmp/gl-app-update.inline.\$\$\"
        cat > \"\$t\"
        sh \"\$t\" $* </dev/null
        rc=\$?
        rm -f \"\$t\"
        exit \$rc" < "$router_script"
}

case "$action" in
    status)
        run_inline "$app" status
        ;;
    install)
        deploy
        rt_ssh "$remote_path" "$app" run
        ;;
    reinstall)
        deploy
        rt_ssh "$remote_path" "$app" force
        ;;
    restore)
        run_inline "$app" restore
        ;;
    cron-on)
        deploy
        rt_ssh "$remote_path" "$app" cron-on "$hh" "$mm"
        ;;
    cron-off)
        run_inline "$app" cron-off
        ;;
esac
