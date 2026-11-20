#!/bin/sh
# 无线实验的"上台前整理"：把上一轮装进 /lib/modules 的模块收走，
# 让 5.10 下次开机不会在 udev 枚举 USB 时自动 modprobe rtl8xxxu
# （万一 probe 就是挂死点，自动加载会让 5.10 连机都起不干净）。
#
# 2026-11-20 事故：直接把 run27 的 mac80211.ko(27MB, 带 DWARF) +
# rtl8xxxu.ko(4MB) install 进 /lib/modules 后 modprobe，userspace 卡死。
# 那两个文件现在还在树里，必须先摘掉，否则下次起 5.10 会自动带上。
#
# 用法（5.10 干净起机后，或 4.14 上对同一棵树操作）：
#   sh wl-quarantine.sh            # 预演，只报告
#   sh wl-quarantine.sh --apply    # 真搬
set +e

K=5.10.252-s5p6818
Q=/root/wl-quarantine
APPLY=0
[ "$1" = --apply ] && APPLY=1

say() { echo "$*"; }

# 5.10 的根是 overlay（lower=p2 出厂层, upper=p3/root）。
# 在 5.10 里直接 /lib/modules 即可；在 4.14 里要顺着 data 分区找 upper。
ROOTS="/lib/modules/$K"
for base in /mnt/.data /mnt/data /data /mnt/sd_data; do
    [ -d "$base/root/lib/modules/$K" ] && ROOTS="$ROOTS $base/root/lib/modules/$K"
done

TARGETS="kernel/net/mac80211/mac80211.ko
kernel/drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko"

say "=== 当前内核 $(uname -r) / 目标模块树 $K ==="
mkdir -p "$Q"

for r in $ROOTS; do
    [ -d "$r" ] || continue
    say "--- 树: $r"
    for t in $TARGETS; do
        f="$r/$t"
        if [ -f "$f" ]; then
            say "  在: $f ($(stat -c %s "$f") 字节, $(stat -c %y "$f" | cut -d. -f1))"
            if [ $APPLY = 1 ]; then
                d="$Q/$r"; mkdir -p "$d/$(dirname "$t")"
                mv "$f" "$d/$t" && say "  已收走 -> $d/$t"
            fi
        else
            say "  无: $f"
        fi
    done
    # 装机时 depmod 生成的索引也要重算
    if [ $APPLY = 1 ]; then
        say "  depmod -a $K"
        depmod -a "$K" 2>&1 | head -3
    fi
done

say ""
say "=== /root/wlmod 里的待测模块 ==="
ls -l /root/wlmod 2>/dev/null || say "  (空，需要先把 mac80211.ko / rtl8xxxu.ko 传上来解压到这里)"

if [ $APPLY = 1 ]; then
    say ""
    say "=== 收尾检查：树里应已无这两个文件 ==="
    for r in $ROOTS; do
        for t in $TARGETS; do
            [ -f "$r/$t" ] && say "!! 仍在: $r/$t"
        done
    done
    say "完成。下一步：起 5.10 -> sh /root/wl-load-guarded.sh A"
fi
