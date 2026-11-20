#!/bin/sh
# 在板子（5.10）上安全加载 RTL8723BU 驱动栈，分两段隔离故障点。
#
# 背景：2026-11-20 直接 `modprobe mac80211 + rtl8xxxu` 后 userspace 整体卡死
# （ICMP 通、sshd 出 banner、PAM 卡住，所有会话建不起来），只能断电。
# 那次实验同时动了三个变量：① 27MB/12MB 未 strip 的巨模块，② 驱动 probe 这颗
# untested 芯片，③ 板载 WiFi 与 94G 移动硬盘共用一个 Genesys HUB。
# 本脚本把它们拆开：
#
#   Phase A  先把 USB 设备 unbind，再加载三个模块 —— 只测"模块本身能不能进内核"，
#            probe 根本不会跑。
#   Phase B  再 bind 回去 —— 只测"probe 这颗芯片会不会挂"，且此时已经有
#            deadman 在计时，卡死也会自己重启回 4.14。
#
# 三重保险：
#   1) deadman：起 180s 定时 reboot -f，成功则取消。userspace 卡死也照样触发。
#   2) hung_task_panic：D 状态进程 30s 触发 panic（需内核开 DETECT_HUNG_TASK）。
#   3) 每一步都先 sync 再落盘标记，panic 后能从日志看出死在哪一步。
#      U-Boot 的 next=510 是一次性的，重启即自动回 4.14。
#
# 用法： sh wl-load-guarded.sh [A|B|all]
set +e

LOG=/var/log/wl-load.log
K=$(uname -r)
DEADMAN=$(( $(date +%s) + 180 ))
# 待测模块放在 /lib/modules 之外，用 insmod 直接装：
# 这样 udev 在开机枚举 USB 时不会自动 modprobe rtl8xxxu，
# 5.10 能干净起机，probe 只在我们布置好 deadman 之后才发生。
MODDIR=/root/wlmod

say() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"
    sync
}

# ---------- 保险 ----------
arm_deadman() {
    # 优先用 systemd 的瞬时定时器：PID1 自己记账，不依赖 logind，
    # 用户会话全卡死也照样会执行。
    if systemd-run --on-active=180 --unit=wl-deadman --description="wl test deadman" \
            /sbin/reboot -f >/dev/null 2>&1; then
        say "deadman: systemd timer wl-deadman 已布置（180s）"
        return 0
    fi
    # 退化方案：脱离会话的裸 sleep
    setsid sh -c 'sleep 180; /sbin/reboot -f' </dev/null >/dev/null 2>&1 &
    echo $! >/tmp/wl-deadman.pid
    say "deadman: 裸进程 pid=$(cat /tmp/wl-deadman.pid) 已布置（180s）"
}

disarm_deadman() {
    systemctl stop wl-deadman.timer >/dev/null 2>&1
    systemctl reset-failed wl-deadman.service wl-deadman.timer >/dev/null 2>&1
    [ -f /tmp/wl-deadman.pid ] && kill "$(cat /tmp/wl-deadman.pid)" 2>/dev/null
    rm -f /tmp/wl-deadman.pid
    say "deadman: 已解除"
}

# ---------- 现场 ----------
preflight() {
    say "=== 内核 $K ==="
    say "uptime: $(cat /proc/uptime)"
    say "mem: $(free -m | tr '\n' '|')"
    say "swaps: $(cat /proc/swaps | tr '\n' '|')"
    say "usb wifi: $(lsusb 2>/dev/null | grep -i '0bda:b720')"
    say "wifi dev node: $(ls -d /sys/bus/usb/devices/*/ 2>/dev/null | while read d; do
            [ "$(cat $d/idVendor 2>/dev/null)" = 0bda ] && [ "$(cat $d/idProduct 2>/dev/null)" = b720 ] && echo "$d"
        done)"

    # USB 盘上的 swap 是最危险的组合：HUB 一出问题，swap I/O 挂住，
    # 所有进程一起进 D 状态 —— 正是上次"ICMP 通但没人能登录"的样子。
    for sw in $(awk 'NR>1{print $1}' /proc/swaps); do
        case "$sw" in
            /dev/zram*) : ;;
            *) say "关掉非 zram swap: $sw"; swapoff "$sw" 2>&1 | head -2 ;;
        esac
    done

    # zram 兜底，避免内存压力落到 USB 盘上
    if [ ! -e /dev/zram0 ]; then
        modprobe zram 2>/dev/null
        [ -e /dev/zram0 ] && {
            echo 512M >/sys/block/zram0/disksize 2>/dev/null
            mkswap /dev/zram0 >/dev/null 2>&1
            swapon -p 100 /dev/zram0 2>/dev/null && say "zram0 512M 已启用作 swap"
        }
    fi

    # 内核侧的 D 状态兜底（内核没编这个 sysctl 就跳过）
    [ -w /proc/sys/kernel/hung_task_panic ] && {
        echo 1 >/proc/sys/kernel/hung_task_panic
        echo 30 >/proc/sys/kernel/hung_task_timeout_secs
        say "hung_task_panic=1 timeout=30 已设置"
    } || say "注意: 本内核没有 hung_task_panic，只剩 deadman 兜底"

    say "模块体积: $(ls -l /lib/modules/$K/kernel/net/wireless/cfg80211.ko \
        /lib/modules/$K/kernel/net/mac80211/mac80211.ko \
        /lib/modules/$K/kernel/drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko 2>/dev/null \
        | awk '{print $5, $9}' | tr '\n' ' ')"
    sync
}

# ---------- Phase A：不 probe，只测模块进内核 ----------
phase_a() {
    say "=== Phase A: unbind 掉 0bda:b720，只加载模块 ==="
    DEVS=$(for d in /sys/bus/usb/devices/*/; do
        [ "$(cat $d/idVendor 2>/dev/null)" = 0bda ] && \
        [ "$(cat $d/idProduct 2>/dev/null)" = b720 ] && basename "$d"
    done)
    if [ -z "$DEVS" ]; then
        say "没找到 0bda:b720（可能已被之前的驱动占用或设备不在）"
    fi
    for d in $DEVS; do
        say "unbind $d"
        echo "$d" >/sys/bus/usb/drivers/usb/unbind 2>/dev/null || echo "$d" >/sys/bus/usb/drivers/usb/unbind 2>&1 | head -1
    done
    sleep 1
    echo "$DEVS" >/tmp/wl-devs

    say "A1 cfg80211"
    modprobe cfg80211 2>&1 | head -5
    [ -d /sys/module/cfg80211 ] || { say "*** cfg80211 没进去，中止 ***"; return 1; }

    say "A2 mac80211 (insmod $MODDIR/mac80211.ko)"
    insmod "$MODDIR/mac80211.ko" 2>&1 | head -5
    [ -d /sys/module/mac80211 ] || { say "*** mac80211 没进去，中止 ***"; return 1; }

    say "A3 rtl8xxxu (insmod $MODDIR/rtl8xxxu.ko，设备已 unbind，不应有 probe)"
    insmod "$MODDIR/rtl8xxxu.ko" 2>&1 | head -5
    [ -d /sys/module/rtl8xxxu ] || { say "*** rtl8xxxu 没进去，中止 ***"; return 1; }

    say "A4 模块都进去了：$(lsmod | grep -E 'cfg80211|mac80211|rtl8xxxu|libarc4' | awk '{print $1"("$2")"}' | tr '\n' ' ')"
    say "A 段结论：模块本身没问题，问题（如果有）在 probe"
}

# ---------- Phase B：bind 回去，触发 probe ----------
phase_b() {
    say "=== Phase B: bind 回设备，触发 probe（有 deadman 护着）==="
    for d in $(cat /tmp/wl-devs 2>/dev/null); do
        say "bind $d"
        echo "$d" >/sys/bus/usb/drivers/usb/bind 2>&1 | head -2
    done
    i=0
    while [ $i -lt 15 ]; do
        [ -d /sys/class/net/wlan0 ] && break
        sleep 1
        i=$((i + 1))
    done
    say "B1 等 ${i}s 后接口: $(ls /sys/class/net | tr '\n' ' ')"
    if [ -d /sys/class/net/wlan0 ]; then
        say "*** wlan0 出现了 MAC=$(cat /sys/class/net/wlan0/address) ***"
        rfkill list 2>/dev/null | head -6
        iw dev 2>/dev/null | head -10
        say "固件日志: $(dmesg | grep -iE 'rtl8xxxu|firmware' | tail -8 | tr '\n' '|')"
    else
        say "B2 没有 wlan0，dmesg: $(dmesg | tail -25 | tr '\n' '|')"
    fi
}

# ---------- main ----------
case "${1:-all}" in
    A) preflight; arm_deadman; phase_a; disarm_deadman ;;
    B) arm_deadman; phase_b; disarm_deadman ;;
    *) preflight; arm_deadman
       if phase_a; then phase_b; fi
       disarm_deadman ;;
esac

say "=== 结束，完整现场见 $LOG 与 dmesg ==="
dmesg | tail -30 >>"$LOG" 2>/dev/null
sync
