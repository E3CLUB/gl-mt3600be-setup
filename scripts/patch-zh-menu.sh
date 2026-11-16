#!/bin/sh
#
# 让 GL.iNet 4.x 管理页在「简体中文」下显示完整菜单。
#
# 原厂在 /usr/share/oui/menu.d/*.json 里给部分菜单写了 "lang_hide": ["zh-cn"]，
# 前端据此在简体中文界面隐藏它们（VPN 面板/客户端/服务端、AdGuard Home、
# 动态 DNS、Tor）。本脚本只把 lang_hide 里的 "zh-cn" 去掉，其余字段一律不动。
# 不改任何压缩 JS，不安装软件包。在电脑本地运行。

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib-ssh.sh"

remote_dir="/usr/share/oui/menu.d"
remote_backup_dir="/root/gl-menu-zh-backup"

usage() {
    cat <<'EOF'
用法：
  patch-zh-menu.sh status     只读：列出当前对简体中文隐藏的菜单
  patch-zh-menu.sh apply      去掉这些菜单的 zh-cn 隐藏标记
  patch-zh-menu.sh restore    恢复首次修改前的原厂菜单定义

环境变量：
  MT3600BE_TARGET   默认 root@192.168.8.1
  MT3600BE_SSH_KEY  私钥路径；留空则用密码或 ssh-agent
EOF
}

action="${1:-status}"
case "$action" in
    -h|--help|help) usage; exit 0 ;;
    status|apply|restore) ;;
    *) usage >&2; exit 2 ;;
esac

if [ "$action" = "restore" ]; then
    rt_ssh "set -eu
        ls '$remote_backup_dir'/*.json.original >/dev/null 2>&1 || {
            echo '错误：路由器上没有备份 $remote_backup_dir，无可恢复内容。' >&2; exit 1; }
        for b in '$remote_backup_dir'/*.json.original; do
            name=\"\$(basename \"\$b\" .original)\"
            cp -p \"\$b\" '$remote_dir'/\"\$name\"
            chown root:root '$remote_dir'/\"\$name\"
            chmod 644 '$remote_dir'/\"\$name\"
            echo \"已恢复 \$name\"
        done"
    echo "已恢复原厂菜单定义。请强制刷新浏览器缓存（macOS: Command+Shift+R）。"
    exit 0
fi

command -v perl >/dev/null 2>&1 || { echo "错误：本机需要 perl。" >&2; exit 1; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gl-menu-zh.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT HUP INT TERM
mkdir "$work_dir/orig" "$work_dir/patched"

# ---- 下载菜单定义（一次 SSH，不依赖 scp/sftp）-----------------------------

if ! rt_ssh "tar -C '$remote_dir' -cf - ." > "$work_dir/menu.tar"; then
    echo "错误：无法读取路由器上的 $remote_dir。" >&2
    exit 1
fi
tar -C "$work_dir/orig" -xf "$work_dir/menu.tar"

# ---- 本地分析并生成补丁 ---------------------------------------------------
#
# 文本层面只删 lang_hide 数组里的 "zh-cn" 一项；随后用 JSON 解析复核：
# 除 lang_hide 少了 zh-cn 之外，文件内容必须与原件完全等价，否则拒绝。

perl -MJSON::PP -e '
    use strict; use warnings;
    my ($orig, $out) = @ARGV;
    my $json = JSON::PP->new->canonical(1);
    opendir(my $dh, $orig) or die "无法打开 $orig\n";
    my @hits;
    for my $name (sort readdir $dh) {
        next unless $name =~ /\A[A-Za-z0-9._-]+\.json\z/;
        open(my $fh, "<:raw", "$orig/$name") or die "无法读取 $name\n";
        local $/; my $text = <$fh>; close $fh;
        my $data = eval { $json->decode($text) };
        next unless ref $data eq "HASH";
        my $hide = $data->{lang_hide};
        next unless ref $hide eq "ARRAY" && grep { defined && $_ eq "zh-cn" } @$hide;

        my $new = $text;
        my $n = ($new =~ s{("lang_hide"\s*:\s*\[)([^\]]*)(\])}{
            my ($a, $body, $c) = ($1, $2, $3);
            $body =~ s/"zh-cn"\s*,\s*//
                or $body =~ s/\s*,\s*"zh-cn"//
                or $body =~ s/\s*"zh-cn"\s*//;
            $a . $body . $c;
        }e);
        die "$name：lang_hide 文本定位失败，拒绝修改\n" unless $n == 1;

        my $after = eval { $json->decode($new) }
            or die "$name：补丁后不是合法 JSON，拒绝修改\n";
        my @want = grep { $_ ne "zh-cn" } @$hide;
        my @got  = @{ $after->{lang_hide} || [] };
        die "$name：lang_hide 复核不一致，拒绝修改\n"
            unless "@want" eq "@got";
        my %x = %$data;  delete $x{lang_hide};
        my %y = %$after; delete $y{lang_hide};
        die "$name：补丁影响了 lang_hide 以外的字段，拒绝修改\n"
            unless $json->encode(\%x) eq $json->encode(\%y);

        open(my $oh, ">:raw", "$out/$name") or die "无法写入 $name\n";
        print $oh $new; close $oh;
        push @hits, sprintf("%s\t%s", $name, $data->{view} // "?");
    }
    print "$_\n" for @hits;
' "$work_dir/orig" "$work_dir/patched" > "$work_dir/hits.tsv"

count="$(wc -l < "$work_dir/hits.tsv" | tr -d ' ')"

if [ "$count" = "0" ]; then
    echo "没有任何菜单对简体中文隐藏：已经打过补丁，或该固件本来就不隐藏。"
    exit 0
fi

echo "当前有 $count 个菜单对简体中文隐藏："
awk -F '\t' '{ printf "  %-22s 视图 %s\n", $1, $2 }' "$work_dir/hits.tsv"

if [ "$action" = "status" ]; then
    echo "未做任何修改。执行 apply 可去掉这些隐藏标记。"
    exit 0
fi

# ---- 上传（一次 SSH：先留原件，再覆盖，最后回读哈希）----------------------

names="$(cut -f1 "$work_dir/hits.tsv" | tr '\n' ' ')"

# shellcheck disable=SC2086  # $names 是已校验过字符集的文件名列表
(cd "$work_dir/patched" && COPYFILE_DISABLE=1 tar --format ustar -cf "$work_dir/patched.tar" $names)

local_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

remote_tar="/tmp/gl-menu-zh.$$.tar"
remote_hashes="$(rt_ssh "set -eu
    cat > '$remote_tar'
    mkdir -p '$remote_backup_dir'
    for name in $names; do
        test -f '$remote_dir'/\"\$name\"
        if [ ! -e '$remote_backup_dir'/\"\$name\".original ]; then
            cp -p '$remote_dir'/\"\$name\" '$remote_backup_dir'/\"\$name\".original
        fi
    done
    tar -C '$remote_dir' -xf '$remote_tar'
    rm -f '$remote_tar'
    cd '$remote_dir'
    for name in $names; do
        chown root:root \"\$name\"
        chmod 644 \"\$name\"
        sha256sum \"\$name\"
    done" < "$work_dir/patched.tar")"

failed=0
for name in $names; do
    expected="$(local_sha256 "$work_dir/patched/$name")"
    actual="$(printf '%s\n' "$remote_hashes" | awk -v n="$name" '$2 == n { print $1 }')"
    if [ "$expected" != "$actual" ]; then
        echo "错误：$name 上传后哈希不一致（本地 $expected / 远端 ${actual:-无}）。" >&2
        failed=1
    fi
done
if [ "$failed" = "1" ]; then
    echo "原件仍在路由器 $remote_backup_dir，可执行 restore 恢复。" >&2
    exit 1
fi

echo "已去掉 $count 个菜单的 zh-cn 隐藏标记，哈希回读一致。"
echo "原件备份：$remote_backup_dir/<文件名>.original"
echo "请在浏览器中强制刷新页面缓存（macOS: Command+Shift+R），必要时重新登录管理页。"
