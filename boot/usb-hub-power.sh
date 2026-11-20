#!/bin/bash
# USB HUB / 移动硬盘供电：GPIO40 = gpiob 第 8 线（sysfs 全局编号 32 + 8 = 40）
#
# 4.14 的做法是 sysfs 导出 gpio40 后置高，并且**一直保持**；
# 5.10 早期版本改用 libgpiod 打一个 1 秒脉冲就释放，实测不行：
#   线一释放，负载开关随后就掉了。2026-11-20 那次的表现是开机 42 秒
#   dmesg 冒出 "usb 2-1: USB disconnect"，已挂载的 ext4 被打成只读，
#   podman 报 "read-only file system"。所以必须像 4.14 一样「导出并长期置高」。
#
# 5.10 的 defconfig 原本没开 CONFIG_GPIO_SYSFS（所以 /sys/class/gpio 不存在，
# 老的 usb-hub-reset 必然失败，HUB 从不上电）；这一版内核已经打开它，
# 于是可以直接走 sysfs，不再依赖 libgpiod。
#
# 安全：
#   1) 只在内核 5.10.x 生效 —— /etc/systemd/system 在两套系统间共享
#      （同一个 overlay），4.14 上跑这个会断电把已挂载的 ext4 打只读。
#   2) 已经存在 /dev/sd* 时绝不动电源，只把线补成「导出 + 高电平」。
#
# 日志：/var/log 在 5.10 上是 tmpfs，且本服务早于 local-fs 运行，写文件不可靠，
#       统一写 /dev/kmsg（之后 dmesg 里能翻到，几个入口都能远程看）。

set -u

GPIO=40                 # gpiob8 = base 32 + 8
SYS=/sys/class/gpio

log() {
	local msg="[usb-hub-power] $*"
	echo "$msg" >/dev/kmsg 2>/dev/null || true
	echo "$msg" >&2
}

KREL=$(uname -r)
case "$KREL" in
5.10.*) : ;;
*)
	log "skip: kernel $KREL, hub power only needed on 5.10"
	exit 0
	;;
esac

[ -d "$SYS" ] || { log "ERROR: $SYS missing (CONFIG_GPIO_SYSFS off?)"; exit 1; }

HAS_DISK=0
for _ in /dev/sd*; do [ -e "$_" ] && HAS_DISK=1; done

claim() {
	if [ -d "$SYS/gpio$GPIO" ]; then
		log "gpio$GPIO already exported (direction=$(cat "$SYS/gpio$GPIO/direction" 2>/dev/null))"
		return 0
	fi
	if ! echo "$GPIO" >"$SYS/export" 2>/dev/null; then
		# 典型原因：DT 里某个 fixed-regulator/vbus-supply 已占用这条线，
		# 那说明供电由内核接管了，轮不到我们。
		log "note: cannot export gpio$GPIO (claimed by kernel, e.g. DT regulator)"
		return 1
	fi
	return 0
}

set_value() { echo "$1" >"$SYS/gpio$GPIO/value" 2>/dev/null; }

if ! claim; then
	[ "$HAS_DISK" = 1 ] || log "WARN: no /dev/sd* but line is claimed elsewhere"
	exit 0
fi

if ! echo out >"$SYS/gpio$GPIO/direction" 2>/dev/null; then
	log "ERROR: cannot set gpio$GPIO direction=out"
	exit 1
fi

if [ "$HAS_DISK" = 1 ]; then
	log "disk present: just assert HIGH, no power cycle"
	set_value 1 || log "WARN: could not write value=1"
	exit 0
fi

log "power cycle start (low 2s)"
set_value 0 || log "WARN: drive low failed"
sleep 2
if ! set_value 1; then
	log "ERROR: drive high failed"
	exit 1
fi
log "power cycle done; line held HIGH by sysfs (never released)"
exit 0
