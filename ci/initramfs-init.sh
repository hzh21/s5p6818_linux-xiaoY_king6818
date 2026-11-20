#!/bin/sh
# FriendlyELEC overlay-root initramfs for king6818 (S5P6818)
#
# 布局（与 4.14 BSP 的 data= 机制等价）：
#   lower  = SD 卡的 p2          只读出厂镜像层
#   upper  = SD 卡的 p3/root     用户改动层
#   work   = SD 卡的 p3/work     overlay workdir
#
# 任何一步失败都退回 p2 直接启动，保证不会变砖。
#
# 2026-11-20 两处重要改造：
#
# 1) 不再写死 mmcblk2。板上 DT 没有 mmc aliases，SD/eMMC 的 mmcblk 编号完全
#    由探测顺序决定（4.14 上 SD=mmcblk2、eMMC=mmcblk0）。一旦内核配置变化
#    让探测顺序变了，写死 mmcblk2p2 的脚本就会等 20 秒、报错、掉进 /bin/sh ——
#    现象是"内核起来了但没网络、也不 panic"，和 2026-11-19 那次挂死一模一样。
#    现在改成扫描所有 mmcblk*p2，用"能挂载 + 有 /sbin/init"来认定根分区，
#    同时要求同一设备的 p3 存在。
#
# 2) 进度和 dmesg 写到启动分区（p1）的 /logs/510-boot.log。
#    板上没有可用显示，串口不一定有人守，所以"挂在哪里"必须能事后读出来。
#    每次启动覆盖写，失败点带 *** FAIL *** 标记。

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

BOOTMNT=/bootmnt
LOG=/dev/null
BOOTDISK=""

mkdir -p "$BOOTMNT" /lower /upper /newroot

# 注意顺序：必须先有 devtmpfs，/dev/mmcblkXp1 这些设备节点才存在。
# 2026-11-20 之前的版本先挂 p1、后挂 devtmpfs，结果所有 -b /dev/mmcblkXp1
# 判断都失败，LOG 静默降级成 /dev/null，日志文件从来没被写出来过。
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null

say() {
    echo "[initramfs] $*"
    echo "$*" >>"$LOG" 2>/dev/null
}

dump_dmesg() {
    echo "=== dmesg @ $1 ===" >>"$LOG" 2>/dev/null
    dmesg >>"$LOG" 2>/dev/null
    sync
}

die() {
    say "*** FAIL *** $*"
    dump_dmesg "FAIL: $*"
    exec /bin/sh
}

# 启动分区只是"记事本"：哪个 mmcblk 的 p1 能挂上就用哪个。
# 先找带 /Image 的（真·启动分区，4.14 也挂着它，写这里两边都读得到），
# 再退一步接受任意 ext4 的 p1。
pick_boot() {
    _need=$1
    for d in mmcblk2 mmcblk1 mmcblk0; do
        [ -b /dev/${d}p1 ] || continue
        mount -t ext4 -o rw /dev/${d}p1 "$BOOTMNT" 2>/dev/null || continue
        if [ "$_need" = image ]; then
            if [ -f "$BOOTMNT/Image" ]; then BOOTDISK=$d; return 0; fi
        else
            if [ -d "$BOOTMNT/lost+found" ] || [ -f "$BOOTMNT/Image" ]; then BOOTDISK=$d; return 0; fi
        fi
        umount "$BOOTMNT"
    done
    return 1
}

pick_boot image || pick_boot any || BOOTDISK=""

if [ -n "$BOOTDISK" ]; then
    mkdir -p "$BOOTMNT/logs" 2>/dev/null
    if : >"$BOOTMNT/logs/510-boot.log" 2>/dev/null; then
        LOG=$BOOTMNT/logs/510-boot.log
    fi
fi

say "=== king6818 5.10 overlay init $(date '+%F %T') ==="
say "cmdline: $(cat /proc/cmdline)"
say "stage: init start; boot log device = ${BOOTDISK:-none} log = $LOG"

# 等 mmc 块设备出现（dwmmc 探测约 3s）。
# 用整数 sleep：busybox 的小数 sleep 依赖 FEATURE_FLOAT_SLEEP，不一定编译进来。
i=0
while [ $i -lt 20 ]; do
    n=$(ls /dev | grep -c '^mmcblk[0-9]p[23]$')
    [ "$n" -ge 2 ] && break
    sleep 1
    i=$((i + 1))
done
say "stage: mmc devices after ${i}s: $(ls /dev | grep '^mmcblk' | tr '\n' ' ')"

# 认定根分区：能只读挂上、且有 init；同设备的 p3 必须存在
ROOTDEV=""
DATA=""
for d in mmcblk2 mmcblk1 mmcblk0; do
    [ -b /dev/${d}p2 ] && [ -b /dev/${d}p3 ] || continue
    if mount -t ext4 -o ro /dev/${d}p2 /lower 2>/dev/null; then
        if [ -x /lower/sbin/init ]; then
            ROOTDEV=/dev/${d}p2
            DATA=/dev/${d}p3
            say "stage: root candidate ${d} accepted (has /sbin/init)"
            break
        fi
        say "note: ${d}p2 mounted but has no /sbin/init, skipping"
        umount /lower
    fi
done

if [ -z "$ROOTDEV" ]; then
    die "no usable root partition found (looked for mmcblk*p2 with /sbin/init)"
fi
say "stage: lower mounted ($ROOTDEV), data=$DATA"

if ! mount -t ext4 -o rw "$DATA" /upper; then
    say "WARN: cannot mount upper ($DATA), booting plain root"
    dump_dmesg "upper mount failed"
    exec switch_root /lower /sbin/init
fi
say "stage: upper mounted ($DATA)"

mkdir -p /upper/root /upper/work

if ! mount -t overlay overlay \
        -o lowerdir=/lower,upperdir=/upper/root,workdir=/upper/work \
        /newroot; then
    say "WARN: overlay mount failed, booting plain root"
    dump_dmesg "overlay mount failed"
    exec switch_root /lower /sbin/init
fi
say "stage: overlay root ready"

# 让数据分区在新根里继续可见（内容由 overlay 提供，这里只是挂载点）
mkdir -p /newroot/mnt/.data
# busybox 的 mount 认 "-o move"，不认 util-linux 的 "--move"
mount -o move /upper /newroot/mnt/.data

mount -o move /proc /newroot/proc
mount -o move /sys  /newroot/sys
mount -o move /dev  /newroot/dev

# 交接前的完整内核日志，出问题时这就是唯一的现场
dump_dmesg "before switch_root"
say "stage: switching root"
umount "$BOOTMNT" 2>/dev/null

exec switch_root /newroot /sbin/init
