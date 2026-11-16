#!/bin/sh
#
# 路由器侧脚本：把 GL.iNet 固件自带的 Tailscale / AdGuard Home 换成官方最新版。
# 由 manage-app-update.sh 部署为 /usr/bin/gl-app-update，不要在电脑本地执行。
#
#   gl-app-update <tailscale|adguardhome> status            只读
#   gl-app-update <tailscale|adguardhome> run               有新版才升级（cron 用）
#   gl-app-update <tailscale|adguardhome> force             同版本也重装
#   gl-app-update <tailscale|adguardhome> restore           恢复固件自带版本
#   gl-app-update <tailscale|adguardhome> cron-on [HH] [MM] 每天定时 run，默认 04:00
#   gl-app-update <tailscale|adguardhome> cron-off
#
# 安全设计：只从官方源下载（pkgs.tailscale.com / static.adguard.com）；
# 强制 SHA256 校验；新二进制先试运行再替换；替换后服务起不来就自动换回
# /rom 里的固件原版。只升不降。

set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin

SELF_PATH="/usr/bin/gl-app-update"
LOG_FILE="/root/gl-app-update.log"
CRON_FILE="/etc/crontabs/root"
CRON_TAG="# mt3600be-setup"
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
STAGE_ROOT="/root/.gl-app-update"
LOCK_DIR="/tmp/gl-app-update.lock"

TS_BIN_DIR="/usr/sbin"
TS_INDEX_URL="https://pkgs.tailscale.com/stable/?mode=json"
TS_BASE_URL="https://pkgs.tailscale.com/stable"
TS_MIN_OVERLAY_KB=90000

AGH_BIN="/usr/bin/AdGuardHome"
AGH_CONF="/etc/AdGuardHome/config.yaml"
AGH_BACKUP_DIR="/root/adguardhome-backup"
AGH_BASE_URL="https://static.adguard.com/adguardhome/release"
AGH_MIN_OVERLAY_KB=60000

MIN_TMP_KB=60000

APP="${1:-}"
ACTION="${2:-}"

usage() {
    cat <<'EOF'
用法：gl-app-update <tailscale|adguardhome> <动作>
  status              只读：已装版本、官方最新版、定时任务、剩余空间
  run                 有新版才升级（定时任务用）
  force               同版本也重装
  restore             恢复固件自带版本
  cron-on [HH] [MM]   每天定时执行 run，默认 04:00
  cron-off            取消定时
EOF
}

log() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [$APP] $*"
    echo "$_msg"
    echo "$_msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    log "错误：$*"
    exit 1
}

trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    if [ "$(wc -l < "$LOG_FILE")" -gt 400 ]; then
        tail -n 300 "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# fetch <url> <输出文件>
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 --max-time 900 --retry 2 -o "$2" "$1"
    else
        wget -q -T 30 -O "$2" "$1"
    fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

is_sha256() {
    case "$1" in
        *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

avail_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# ver_gt A B：A 的数字版本严格大于 B 时返回 0
ver_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            p = x[i] + 0; q = y[i] + 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

detect_arch() {
    case "$(uname -m)" in
        aarch64) TS_ARCH="arm64"; AGH_ARCH="arm64" ;;
        armv7l)  TS_ARCH="arm";   AGH_ARCH="armv7" ;;
        x86_64)  TS_ARCH="amd64"; AGH_ARCH="amd64" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
}

acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "已有另一个 gl-app-update 在运行（$LOCK_DIR）。确认没有残留进程后可手动删除该目录。"
    fi
    trap 'rm -rf "$LOCK_DIR" "$WORK_DIR" "$STAGE_DIR"' EXIT
    trap 'exit 1' HUP INT TERM
}

prepare_dirs() {
    WORK_DIR="/tmp/gl-app-update.$$"
    STAGE_DIR="$STAGE_ROOT/$APP.$$"
    rm -rf "$STAGE_ROOT"
    mkdir -p "$WORK_DIR" "$STAGE_DIR" || die "无法创建临时目录"
}

check_space() {
    _need_overlay="$1"
    _o="$(avail_kb /overlay)"; _t="$(avail_kb /tmp)"
    [ -n "$_o" ] && [ -n "$_t" ] || die "无法读取剩余空间"
    [ "$_o" -ge "$_need_overlay" ] || die "/overlay 剩余 ${_o}KB，不足 ${_need_overlay}KB"
    [ "$_t" -ge "$MIN_TMP_KB" ] || die "/tmp 剩余 ${_t}KB，不足 ${MIN_TMP_KB}KB"
}

wait_for_process() {
    _name="$1"; _secs="$2"; _i=0
    while [ "$_i" -lt "$_secs" ]; do
        pidof "$_name" >/dev/null 2>&1 && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# ---- Tailscale ------------------------------------------------------------

ts_current() {
    "$TS_BIN_DIR/tailscale" version 2>/dev/null | head -n 1 | sed 's/^\([0-9][0-9.]*\).*/\1/'
}

ts_enabled() { [ "$(uci -q get tailscale.settings.enabled)" = "1" ]; }

ts_lookup_latest() {
    fetch "$TS_INDEX_URL" "$WORK_DIR/ts-index.json" || die "无法访问 pkgs.tailscale.com"
    TS_VERSION="$(jsonfilter -i "$WORK_DIR/ts-index.json" -e '@.TarballsVersion' 2>/dev/null)"
    TS_TARBALL="$(jsonfilter -i "$WORK_DIR/ts-index.json" -e "@.Tarballs.$TS_ARCH" 2>/dev/null)"
    case "$TS_VERSION" in
        ''|*[!0-9.]*) die "官方索引里的版本号异常：'$TS_VERSION'" ;;
    esac
    [ "$TS_TARBALL" = "tailscale_${TS_VERSION}_${TS_ARCH}.tgz" ] || \
        die "官方索引里的文件名异常：'$TS_TARBALL'"
}

ts_service_restart() {
    if [ -x /usr/bin/gl_tailscale ]; then
        /usr/bin/gl_tailscale restart >/dev/null 2>&1
    else
        /etc/init.d/tailscale restart >/dev/null 2>&1
    fi
}

ts_put_rom() {
    [ -f /rom/usr/sbin/tailscaled ] || return 1
    /etc/init.d/tailscale stop >/dev/null 2>&1
    rm -f "$TS_BIN_DIR/tailscale" "$TS_BIN_DIR/tailscaled"
    cp -a /rom/usr/sbin/tailscaled "$TS_BIN_DIR/tailscaled" || return 1
    if [ -e /rom/usr/sbin/tailscale ] || [ -L /rom/usr/sbin/tailscale ]; then
        cp -a /rom/usr/sbin/tailscale "$TS_BIN_DIR/tailscale" || return 1
    else
        ln -s tailscaled "$TS_BIN_DIR/tailscale"
    fi
    ts_service_restart
}

ts_healthy() {
    [ "$(ts_current)" = "$1" ] || return 1
    ts_enabled || return 0
    wait_for_process tailscaled 40 || return 1
    _i=0
    while [ "$_i" -lt 20 ]; do
        _state="$(timeout 5 "$TS_BIN_DIR/tailscale" status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)"
        [ -n "$_state" ] && return 0
        sleep 2
        _i=$((_i + 1))
    done
    return 1
}

ts_status() {
    _cur="$(ts_current)"
    echo "Tailscale"
    echo "  已安装版本：${_cur:-未知}"
    if [ -L "$TS_BIN_DIR/tailscale" ]; then
        echo "  形态：固件自带的合并二进制（tailscale 是指向 tailscaled 的软链接）"
    else
        echo "  形态：官方完整版（tailscale 与 tailscaled 各自独立）"
    fi
    echo "  管理页开关：$(ts_enabled && echo 已启用 || echo 未启用)"
    echo "  进程：$(pidof tailscaled >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
    if fetch "$TS_INDEX_URL" "$WORK_DIR/ts-index.json" 2>/dev/null; then
        echo "  官方最新版：$(jsonfilter -i "$WORK_DIR/ts-index.json" -e '@.TarballsVersion' 2>/dev/null)"
    else
        echo "  官方最新版：查询失败（路由器无法访问 pkgs.tailscale.com）"
    fi
}

ts_install() {
    _force="$1"
    ts_lookup_latest
    _cur="$(ts_current)"
    if [ "$_force" != "1" ]; then
        if [ "$_cur" = "$TS_VERSION" ] && [ ! -L "$TS_BIN_DIR/tailscale" ]; then
            log "已是最新版 $TS_VERSION，无需升级。"
            return 0
        fi
        if [ -n "$_cur" ] && [ "$_cur" != "$TS_VERSION" ] && ! ver_gt "$TS_VERSION" "$_cur"; then
            log "已安装 $_cur 高于官方稳定版 $TS_VERSION，不降级。"
            return 0
        fi
    fi

    check_space "$TS_MIN_OVERLAY_KB"
    log "开始安装 Tailscale $TS_VERSION（当前 ${_cur:-未知}）"

    fetch "$TS_BASE_URL/$TS_TARBALL" "$WORK_DIR/ts.tgz" || die "下载 $TS_TARBALL 失败"
    fetch "$TS_BASE_URL/$TS_TARBALL.sha256" "$WORK_DIR/ts.sha256" || die "下载校验值失败"
    _want="$(awk 'NR==1 {print $1}' "$WORK_DIR/ts.sha256")"
    _got="$(sha256_of "$WORK_DIR/ts.tgz")"
    is_sha256 "$_want" || die "官方校验值格式异常"
    [ "$_want" = "$_got" ] || die "SHA256 不一致（期望 $_want / 实际 $_got），已放弃"

    tar -xzf "$WORK_DIR/ts.tgz" -C "$STAGE_DIR" || die "解压失败"
    rm -f "$WORK_DIR/ts.tgz"
    _src="$STAGE_DIR/tailscale_${TS_VERSION}_${TS_ARCH}"
    [ -f "$_src/tailscale" ] && [ -f "$_src/tailscaled" ] || die "压缩包里缺少 tailscale/tailscaled"
    chmod 755 "$_src/tailscale" "$_src/tailscaled"

    _probe="$("$_src/tailscaled" --version 2>/dev/null | head -n 1)"
    case "$_probe" in
        "$TS_VERSION"*) ;;
        *) die "新 tailscaled 试运行失败（输出：'$_probe'），未改动系统" ;;
    esac
    "$_src/tailscale" version >/dev/null 2>&1 || die "新 tailscale 试运行失败，未改动系统"

    /etc/init.d/tailscale stop >/dev/null 2>&1
    rm -f "$TS_BIN_DIR/tailscale"
    if mv -f "$_src/tailscaled" "$TS_BIN_DIR/tailscaled" && \
       mv -f "$_src/tailscale" "$TS_BIN_DIR/tailscale"; then
        ts_service_restart
    else
        log "替换二进制失败，恢复固件原版"
        ts_put_rom || die "恢复固件原版也失败，请手动检查 $TS_BIN_DIR"
        die "替换失败，已恢复固件原版"
    fi

    if ts_healthy "$TS_VERSION"; then
        log "Tailscale 已升级到 $TS_VERSION"
    else
        log "升级后健康检查未通过，恢复固件原版"
        ts_put_rom || die "恢复固件原版失败，请手动检查 $TS_BIN_DIR"
        die "升级失败，已恢复固件原版 $(ts_current)"
    fi
}

ts_restore() {
    [ -f /rom/usr/sbin/tailscaled ] || die "/rom 里没有固件原版 tailscaled"
    ts_put_rom || die "恢复失败"
    log "已恢复固件自带的 Tailscale $(ts_current)"
}

# ---- AdGuard Home ---------------------------------------------------------

agh_version_of() {
    "$1" --version 2>/dev/null | sed -n 's/.*\(v[0-9][0-9.]*[0-9]\).*/\1/p' | head -n 1
}

agh_current() { agh_version_of "$AGH_BIN"; }

agh_enabled() { [ "$(uci -q get adguardhome.config.enabled)" = "1" ]; }

agh_lookup_latest() {
    fetch "$AGH_BASE_URL/version.json" "$WORK_DIR/agh-version.json" || die "无法访问 static.adguard.com"
    AGH_VERSION="$(jsonfilter -i "$WORK_DIR/agh-version.json" -e '@.version' 2>/dev/null)"
    case "$AGH_VERSION" in
        v[0-9]*) ;;
        *) die "官方 version.json 里的版本号异常：'$AGH_VERSION'" ;;
    esac
    case "${AGH_VERSION#v}" in
        *[!0-9.]*) die "官方 version.json 里的版本号异常：'$AGH_VERSION'" ;;
    esac
    AGH_TARBALL="AdGuardHome_linux_${AGH_ARCH}.tar.gz"
}

agh_backup_config() {
    [ -f "$AGH_CONF" ] || return 0
    mkdir -p "$AGH_BACKUP_DIR" && chmod 700 "$AGH_BACKUP_DIR"
    # 第一次升级前的配置单独留一份：恢复固件原版时要靠它（新版会迁移配置格式）
    [ -e "$AGH_BACKUP_DIR/config.yaml.stock" ] || cp -p "$AGH_CONF" "$AGH_BACKUP_DIR/config.yaml.stock"
    AGH_CONF_BACKUP="$AGH_BACKUP_DIR/config.yaml.$(date +%Y%m%d-%H%M%S)"
    cp -p "$AGH_CONF" "$AGH_CONF_BACKUP"
    # 只保留最近 5 份带时间戳的备份
    ls -1t "$AGH_BACKUP_DIR"/config.yaml.2* 2>/dev/null | tail -n +6 | while read -r _old; do
        rm -f "$_old"
    done
}

agh_put_rom() {
    [ -f "/rom$AGH_BIN" ] || return 1
    /etc/init.d/adguardhome stop >/dev/null 2>&1
    rm -f "$AGH_BIN"
    cp -a "/rom$AGH_BIN" "$AGH_BIN" || return 1
    if [ -n "${1:-}" ] && [ -f "$1" ]; then
        cp -p "$1" "$AGH_CONF"
    fi
    /etc/init.d/adguardhome start >/dev/null 2>&1
}

agh_healthy() {
    [ "$(agh_current)" = "$1" ] || return 1
    agh_enabled || return 0
    wait_for_process AdGuardHome 30 || return 1
    # 配置迁移失败时进程会起来又退出，多看几秒确认它还活着
    sleep 8
    pidof AdGuardHome >/dev/null 2>&1
}

agh_status() {
    echo "AdGuard Home"
    _cur="$(agh_current)"
    echo "  已安装版本：${_cur:-未知}"
    echo "  管理页开关：$(agh_enabled && echo 已启用 || echo 未启用)"
    echo "  进程：$(pidof AdGuardHome >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
    if fetch "$AGH_BASE_URL/version.json" "$WORK_DIR/agh-version.json" 2>/dev/null; then
        echo "  官方最新版：$(jsonfilter -i "$WORK_DIR/agh-version.json" -e '@.version' 2>/dev/null)"
    else
        echo "  官方最新版：查询失败（路由器无法访问 static.adguard.com）"
    fi
    if [ -d "$AGH_BACKUP_DIR" ]; then
        echo "  配置备份：$AGH_BACKUP_DIR（$(ls -1 "$AGH_BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ') 份）"
    fi
}

agh_install() {
    _force="$1"
    [ -x "$AGH_BIN" ] || die "没有找到 $AGH_BIN，此固件不带 AdGuard Home"
    [ -x /etc/init.d/adguardhome ] || die "没有找到 /etc/init.d/adguardhome"
    agh_lookup_latest
    _cur="$(agh_current)"
    if [ "$_force" != "1" ] && [ -n "$_cur" ]; then
        if [ "$_cur" = "$AGH_VERSION" ]; then
            log "已是最新版 $AGH_VERSION，无需升级。"
            return 0
        fi
        if ! ver_gt "${AGH_VERSION#v}" "${_cur#v}"; then
            log "已安装 $_cur 高于官方稳定版 $AGH_VERSION，不降级。"
            return 0
        fi
    fi

    check_space "$AGH_MIN_OVERLAY_KB"
    log "开始安装 AdGuard Home $AGH_VERSION（当前 ${_cur:-未知}）"

    fetch "$AGH_BASE_URL/$AGH_TARBALL" "$WORK_DIR/agh.tgz" || die "下载 $AGH_TARBALL 失败"
    fetch "$AGH_BASE_URL/checksums.txt" "$WORK_DIR/agh.sums" || die "下载校验值失败"
    _want="$(awk -v f="./$AGH_TARBALL" '$2 == f {print $1}' "$WORK_DIR/agh.sums")"
    _got="$(sha256_of "$WORK_DIR/agh.tgz")"
    is_sha256 "$_want" || die "官方 checksums.txt 里找不到 $AGH_TARBALL"
    [ "$_want" = "$_got" ] || die "SHA256 不一致（期望 $_want / 实际 $_got），已放弃"

    tar -xzf "$WORK_DIR/agh.tgz" -C "$STAGE_DIR" || die "解压失败"
    rm -f "$WORK_DIR/agh.tgz"
    _new="$STAGE_DIR/AdGuardHome/AdGuardHome"
    [ -f "$_new" ] || die "压缩包里缺少 AdGuardHome 二进制"
    chmod 755 "$_new"
    [ "$(agh_version_of "$_new")" = "$AGH_VERSION" ] || die "新二进制试运行失败，未改动系统"

    AGH_CONF_BACKUP=""
    agh_backup_config

    /etc/init.d/adguardhome stop >/dev/null 2>&1
    if mv -f "$_new" "$AGH_BIN"; then
        /etc/init.d/adguardhome start >/dev/null 2>&1
    else
        log "替换二进制失败，恢复固件原版"
        agh_put_rom "$AGH_CONF_BACKUP" || die "恢复固件原版也失败，请手动检查 $AGH_BIN"
        die "替换失败，已恢复固件原版"
    fi

    if agh_healthy "$AGH_VERSION"; then
        log "AdGuard Home 已升级到 $AGH_VERSION"
        [ -n "$AGH_CONF_BACKUP" ] && log "升级前配置备份：$AGH_CONF_BACKUP"
    else
        log "升级后健康检查未通过，恢复固件原版与升级前配置"
        agh_put_rom "$AGH_CONF_BACKUP" || die "恢复固件原版失败，请手动检查 $AGH_BIN"
        die "升级失败，已恢复固件原版"
    fi
}

agh_restore() {
    [ -f "/rom$AGH_BIN" ] || die "/rom 里没有固件原版 AdGuardHome"
    _stock_conf="$AGH_BACKUP_DIR/config.yaml.stock"
    if [ -f "$_stock_conf" ] && [ -f "$AGH_CONF" ]; then
        cp -p "$AGH_CONF" "$AGH_BACKUP_DIR/config.yaml.before-restore"
        log "当前配置另存为 $AGH_BACKUP_DIR/config.yaml.before-restore"
    else
        _stock_conf=""
        log "提示：没有首次升级前的配置备份，保留当前配置；旧版若无法读取新格式配置将起不来"
    fi
    agh_put_rom "$_stock_conf" || die "恢复失败"
    log "已恢复固件自带的 AdGuard Home $(agh_current)"
}

# ---- 定时任务 -------------------------------------------------------------

cron_line_pattern() { echo "$SELF_PATH $APP run"; }

cron_show() {
    if [ -f "$CRON_FILE" ] && grep -F "$(cron_line_pattern)" "$CRON_FILE" >/dev/null 2>&1; then
        echo "  定时升级：$(grep -F "$(cron_line_pattern)" "$CRON_FILE" | head -n 1)"
    else
        echo "  定时升级：未设置"
    fi
    echo "  路由器当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')（定时任务按这个时区计算）"
}

cron_remove_line() {
    [ -f "$CRON_FILE" ] || return 0
    grep -vF "$(cron_line_pattern)" "$CRON_FILE" > "$CRON_FILE.tmp" || true
    cat "$CRON_FILE.tmp" > "$CRON_FILE"
    rm -f "$CRON_FILE.tmp"
}

cron_on() {
    _hh="${1:-4}"; _mm="${2:-0}"
    case "$_hh$_mm" in
        *[!0-9]*) die "小时和分钟必须是整数" ;;
    esac
    # 去掉前导 0，避免 04、08 被当成八进制
    _hh="$(echo "$_hh" | sed 's/^0*//')"; _hh="${_hh:-0}"
    _mm="$(echo "$_mm" | sed 's/^0*//')"; _mm="${_mm:-0}"
    [ "$_hh" -le 23 ] && [ "$_mm" -le 59 ] || die "时间超出范围（小时 0-23，分钟 0-59）"
    [ -x "$SELF_PATH" ] || die "$SELF_PATH 尚未部署，请通过 manage-app-update.sh 执行 cron-on"

    mkdir -p "$(dirname "$CRON_FILE")"
    touch "$CRON_FILE"
    cron_remove_line
    echo "$_mm $_hh * * * $SELF_PATH $APP run >/dev/null 2>&1 $CRON_TAG" >> "$CRON_FILE"
    /etc/init.d/cron enable >/dev/null 2>&1
    /etc/init.d/cron restart >/dev/null 2>&1

    # 保留配置升级固件后脚本还在，定时任务才能把新固件里的旧版再升上去
    if [ -f "$SYSUPGRADE_CONF" ] && ! grep -qxF "$SELF_PATH" "$SYSUPGRADE_CONF"; then
        echo "$SELF_PATH" >> "$SYSUPGRADE_CONF"
    fi
    log "已设置每天 $(printf '%02d:%02d' "$_hh" "$_mm") 自动检查并升级"
    cron_show
}

cron_off() {
    cron_remove_line
    /etc/init.d/cron restart >/dev/null 2>&1
    log "已取消定时升级"
}

# ---- 入口 -----------------------------------------------------------------

case "$APP" in
    tailscale|adguardhome) ;;
    -h|--help|help|'') usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

command -v uci >/dev/null 2>&1 || { echo "错误：这不是 OpenWrt 路由器，请勿在电脑本地执行。" >&2; exit 1; }
command -v jsonfilter >/dev/null 2>&1 || die "路由器上没有 jsonfilter"

detect_arch
WORK_DIR=""; STAGE_DIR=""

case "$ACTION" in
    status)
        WORK_DIR="/tmp/gl-app-update.status.$$"
        mkdir -p "$WORK_DIR"
        trap 'rm -rf "$WORK_DIR"' EXIT
        if [ "$APP" = "tailscale" ]; then ts_status; else agh_status; fi
        cron_show
        echo "  剩余空间：/overlay $(avail_kb /overlay)KB，/tmp $(avail_kb /tmp)KB"
        ;;
    run|force)
        acquire_lock
        prepare_dirs
        trim_log
        _f=0; [ "$ACTION" = "force" ] && _f=1
        if [ "$APP" = "tailscale" ]; then ts_install "$_f"; else agh_install "$_f"; fi
        ;;
    restore)
        acquire_lock
        if [ "$APP" = "tailscale" ]; then ts_restore; else agh_restore; fi
        ;;
    cron-on)
        cron_on "${3:-4}" "${4:-0}"
        ;;
    cron-off)
        cron_off
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
