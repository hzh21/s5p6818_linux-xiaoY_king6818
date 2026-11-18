#!/bin/sh
# FriendlyELEC overlay-root initramfs for king6818 (S5P6818)
#
# 布局（与 4.14 BSP 的 data= 机制等价）：
#   lower  = /dev/mmcblk2p2        只读出厂镜像层
#   upper  = /dev/mmcblk2p3/root   用户改动层
#   work   = /dev/mmcblk2p3/work   overlay workdir
#
# 任何一步失败都退回 p2 直接启动，保证不会变砖。

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "[initramfs] king6818 overlay init"

mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t proc     proc     /proc 2>/dev/null
mount -t sysfs    sysfs    /sys  2>/dev/null

i=0
while [ $i -lt 50 ]; do
    if [ -b /dev/mmcblk2p2 ] && [ -b /dev/mmcblk2p3 ]; then
        break
    fi
    sleep 0.2
    i=$((i + 1))
done

if [ ! -b /dev/mmcblk2p2 ] || [ ! -b /dev/mmcblk2p3 ]; then
    echo "[initramfs] FATAL: mmc partitions not found"
    exec /bin/sh
fi

mkdir -p /lower /upper /newroot

if ! mount -t ext4 -o ro /dev/mmcblk2p2 /lower; then
    echo "[initramfs] FATAL: cannot mount lower (mmcblk2p2)"
    exec /bin/sh
fi
echo "[initramfs] lower mounted (mmcblk2p2)"

if ! mount -t ext4 -o rw /dev/mmcblk2p3 /upper; then
    echo "[initramfs] WARN: cannot mount upper (mmcblk2p3), booting plain p2"
    exec switch_root /lower /sbin/init
fi
echo "[initramfs] upper mounted (mmcblk2p3)"

mkdir -p /upper/root /upper/work

if ! mount -t overlay overlay \
        -o lowerdir=/lower,upperdir=/upper/root,workdir=/upper/work \
        /newroot; then
    echo "[initramfs] WARN: overlay mount failed, booting plain p2"
    exec switch_root /lower /sbin/init
fi
echo "[initramfs] overlay root ready, switching root"

# 让数据分区在新根里继续可见（内容由 overlay 提供，这里只是挂载点）
mkdir -p /newroot/mnt/.data
mount --move /upper /newroot/mnt/.data

mount --move /proc /newroot/proc
mount --move /sys  /newroot/sys
mount --move /dev  /newroot/dev

exec switch_root /newroot /sbin/init
