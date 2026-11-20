#!/bin/sh
# 延迟加载 RTL8723BU WiFi（5.10）
#
# 背景（2026-11-20）：
#   rtl8xxxu 由 udev 在开机早期自动 modprobe 时，wlan0 关联成功后约 1.3s
#   内核 NULL deref（串口只吐一行 "Unable to handle kernel NULL pointer
#   dereference" 就卡死，拿不到 Call trace）。但在系统跑稳之后手工
#   modprobe，probe/auth/assoc/DHCP/TX/RX 全部正常，ping 外网 0% 丢包。
#   => 驱动本身没问题，是开机期并发（udev 加载 cfg80211 与驱动注册 netdev
#      的竞态 / USB 存储与 WiFi 共用 HUB / podman 冷启动压满 CPU）触发。
#
# 策略：
#   1. /etc/modprobe.d/blacklist-rtl8xxxu.conf 让 udev 开机不碰它；
#   2. 本脚本等"系统起来了 + load 降下来 + USB 存储安静了"再 modprobe。
#
# 判定条件（任一条不满足就再等 5s，最多 12 分钟）：
#   - systemd 状态到 running / degraded（即不在 starting/initializing）
#   - load1 < 4（容器冷启动会冲到 7+）
#   - 并且已经等满 MIN_WAIT 秒
#
# 不做任何失败重试：modprobe 失败只记日志，系统照常跑（WiFi 是备用链路）。

MIN_WAIT=120
MAX_WAIT=720
LOG=/mnt/sd_boot/logs/wifi-load.log
mkdir -p /mnt/sd_boot/logs 2>/dev/null || LOG=/var/log/wifi-load.log

say() {
	printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

say "=== wifi-load-late 启动（MIN_WAIT=${MIN_WAIT}s）==="
say "kernel $(uname -r)  uptime $(cut -d' ' -f1 /proc/uptime)s  load $(cut -d' ' -f1-3 /proc/loadavg)"

start=$(date +%s)
while :; do
	now=$(date +%s)
	waited=$((now - start))
	[ "$waited" -ge "$MAX_WAIT" ] && { say "超时 ${MAX_WAIT}s，放弃"; exit 0; }

	# 【别用 systemctl is-system-running 做判据】踩过两次坑：
	#   1) degraded 时它退出码非 0，`$(cmd || echo unknown)` 会拼成
	#      "degraded unknown"，case 匹配不上；
	#   2) 本服务自己是 oneshot，activating 期间 systemd 会一直报
	#      starting —— 脚本等于在等自己，死锁（2026-11-20 实测）。
	# 改成看真正在乎的东西：eth0 拿到 IPv4（网络栈就绪）+ load 降下来。
	load1=$(cut -d' ' -f1 /proc/loadavg)
	low=$(awk -v l="$load1" 'BEGIN { print (l < 4) ? 1 : 0 }')

	if [ "$waited" -ge "$MIN_WAIT" ] && [ "$low" = 1 ]; then
		if ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
			st="eth0-up"
			break
		fi
	fi
	sleep 5
done

say "条件满足：waited=${waited}s  systemd=$st  load1=$load1"
# 再让一步：USB 存储（移动硬盘与 WiFi 共用 Genesys HUB）的突发 I/O 静下来
sleep 20

say "开始 modprobe rtl8xxxu"
if modprobe rtl8xxxu 2>&1 | tee -a "$LOG"; then
	sleep 3
	if lsmod | grep -q '^rtl8xxxu'; then
		say "加载成功：$(lsmod | grep -E '^rtl8xxxu' | awk '{print $1" refcount="$3}')"
	else
		say "modprobe 返回 0 但模块不在 lsmod 里"
	fi
else
	say "modprobe 失败（rc=$?），WiFi 不可用，系统继续"
fi

# 落一下当前 dmesg 里的无线相关行，方便在 4.14 上回溯
{
	echo "--- dmesg (wifi) ---"
	dmesg 2>/dev/null | grep -iE 'rtl8xxxu|wlan0|cfg80211|ieee80211' | tail -30
} >> "$LOG"
sync
say "=== 完成 ==="
exit 0
